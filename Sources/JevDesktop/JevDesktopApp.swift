import AppKit
import Combine
import JevCore
import SwiftUI
import os

@main
@MainActor
struct JevDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("Desktop Voice", systemImage: model.isBusy ? "waveform" : "waveform.circle") {
            Text(model.headline)
            Button("Show voice widget") { model.showVoiceWidget() }
            Button("Settings and commands…") { model.showSettings() }
            Button("Cancel current command") { model.cancel() }.disabled(!model.isBusy)
            Divider()
            Text("Hold ⌃⌥Space to speak")
            Toggle("Wake phrase: “\(model.wake.phrase)”", isOn: Binding(get: { model.wake.isEnabled }, set: { model.wake.setEnabled($0); model.objectWillChange.send() }))
            Button("Quit Desktop Voice") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { AppModel.shared.start() }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.openMainInterface()
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private let log = Logger(subsystem: "local.jev-use", category: "status")
    @Published var headline = "Ready for a command" { didSet { log.notice("\(self.headline, privacy: .public) | \(self.detail, privacy: .public)") } }
    @Published var detail = "Hold Control–Option–Space. Release to act. Escape cancels." { didSet { log.notice("  \(self.detail, privacy: .public)") } }
    /// The word the pixel field currently spells: the latest spoken word while the user speaks, otherwise nothing.
    @Published var word: String?
    @Published var transcript = ""
    @Published var isBusy = false
    @Published var hasKey = false
    @Published var isLoadingKey = true
    @Published var accessibilityAllowed = Desktop.hasAccess
    @Published var speechAllowed = false
    @Published var targetName = "your current app"
    @Published var timing = ""

    let speech = SpeechInput()
    let wake = WakeWord()
    let systemAudio = SystemAudioMonitor()
    private let hotKey = HotKey()
    private var key: String?
    /// Optional OpenRouter key: when present, the planner model turns the sentence into steps and Jev grounds each one.
    private var plannerKey: String?
    @Published var hasPlannerKey = false
    private var task: Task<Void, Never>?
    private var keyTask: Task<Void, Never>?
    /// Guards against a runaway chain in the fallback loop; Escape still cancels earlier.
    private let maxSteps = 12
    private var generation = UUID()
    private var target: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var priorCommand: String?
    private var priorAction: String?
    private var releasedAt: Date?
    private var capturing = false
    /// A command spoken while a chain was still running; it starts when the chain finishes.
    private var pendingCommand: (String, NSRunningApplication)?
    private var awaitingClarification = false
    /// True while a command's steps are executing (not while listening).
    private var chainRunning = false
    private var subscriptions = Set<AnyCancellable>()
    private var appObserver: NSObjectProtocol?
    private var commandObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var overlay: NSPanel?
    private var shortcutReady = false

    var setupComplete: Bool { hasKey && accessibilityAllowed && speechAllowed }

    func start() {
        lastExternalApp = NSWorkspace.shared.frontmostApplication.flatMap { Desktop.isControllable($0) ? $0 : nil }
        targetName = lastExternalApp?.localizedName ?? "your current app"
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Desktop.isControllable(app) else { return }
            MainActor.assumeIsolated {
                self?.lastExternalApp = app
                self?.targetName = app.localizedName ?? "your current app"
            }
        }
        // Local command line entry: same path as the typed command box in Settings.
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.jev-use.command"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let command = notification.object as? String else { return }
            MainActor.assumeIsolated { self?.runTyped(command) }
        }
        speech.$transcript.sink { [weak self] text in
            guard let self, self.capturing else { return }
            self.transcript = text
            self.wordTask?.cancel(); self.wordTask = nil
            self.word = text.split(whereSeparator: \.isWhitespace).last.map(String.init)
        }.store(in: &subscriptions)
        speech.$status.sink { [weak self] status in
            if self?.capturing == true { self?.detail = status }
        }.store(in: &subscriptions)
        speech.onFinal = { [weak self] text in
            guard let self, self.capturing, let target = self.target else { return }
            self.capturing = false
            if self.chainRunning {
                self.pendingCommand = (text, target)
                self.detail = "Queued: \(text)"
                return
            }
            self.run(text, in: target, started: self.releasedAt ?? Date())
        }
        speech.onFailure = { [weak self] message in self?.fail(message) }
        wake.onArmed = { [weak self] in
            guard let self else { return }
            self.transcript = ""
            self.timing = ""
            self.headline = "Listening…"
            self.detail = "Say the command. It runs when you stop speaking."
            self.showOverlay()
        }
        wake.onPartial = { [weak self] text in
            guard let self else { return }
            self.transcript = text
            self.wordTask?.cancel(); self.wordTask = nil
            self.word = text.split(whereSeparator: \.isWhitespace).last.map(String.init)
        }
        wake.onDisarmed = { [weak self] in
            guard let self, !self.isBusy else { return }
            self.headline = "Ready for a command"
            self.detail = "No command followed the wake phrase."
            self.clearPixels()
        }
        wake.onCommand = { [weak self] text in self?.runTyped(text) }
        // Push-to-talk and a running command own the microphone and the screen.
        $isBusy.removeDuplicates().sink { [weak self] busy in
            if busy { self?.wake.suspend() } else { self?.wake.resume() }
        }.store(in: &subscriptions)
        hotKey.onPress = { [weak self] in self?.beginSpeech() }
        hotKey.onRelease = { [weak self] in
            guard let self, self.capturing else { return }
            self.releasedAt = Date()
            self.headline = "Finishing speech…"
            self.speech.finish()
        }
        hotKey.onCancel = { [weak self] in
            if self?.isBusy == true { self?.cancel() }
            else { self?.overlay?.orderOut(nil) }
        }
        do { try hotKey.register(); shortcutReady = true }
        catch {
            shortcutReady = false
            headline = "Shortcut unavailable"
            detail = error.localizedDescription
        }
        if shortcutReady {
            headline = "Waiting for Keychain…"
            detail = "Approve the saved-key prompt on your Mac if it appears."
        }
        showOverlay()
        keyTask = Task {
            do {
                let saved = try await Task.detached(priority: .userInitiated) { try KeyStore.read() }.value
                let planner = try await Task.detached(priority: .userInitiated) { try KeyStore.read(KeyStore.planner) }.value
                guard !Task.isCancelled else { return }
                key = saved
                hasKey = saved != nil
                plannerKey = planner
                hasPlannerKey = planner != nil
                isLoadingKey = false
                if shortcutReady {
                    headline = hasKey ? "Finish setup" : "Add your TypeSafe key"
                    detail = "Complete setup, then hold ⌃⌥Space to speak."
                }
                openMainInterface()
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingKey = false
                headline = "Keychain needs attention"
                detail = error.localizedDescription
                showSettings()
            }
        }
    }

    func openMainInterface() {
        refreshPermissions()
        if setupComplete && shortcutReady { showVoiceWidget() }
        else { showSettings() }
    }

    func saveKey(_ value: String) {
        do {
            try KeyStore.save(value)
            key = try KeyStore.read()
            hasKey = key != nil
            headline = "Key saved"
            detail = "Stored in your Mac's Keychain. Try a command to check access."
        } catch { fail(error.localizedDescription) }
    }

    func savePlannerKey(_ value: String) {
        do {
            try KeyStore.save(value, account: KeyStore.planner)
            plannerKey = try KeyStore.read(KeyStore.planner)
            hasPlannerKey = plannerKey != nil
            headline = "Planner key saved"
            detail = "\(Planner.model) will plan multi-step commands; Jev still chooses every action."
        } catch { fail(error.localizedDescription) }
    }

    func grantAccessibility() {
        Desktop.requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func grantSpeech() {
        Task {
            let granted = await speech.requestPermissions()
            speechAllowed = speech.hasPermissions
            headline = granted ? "Speech is ready" : "Speech needs access"
            detail = granted ? "Switch to an app, then hold Control–Option–Space." : speech.status
        }
    }

    func refreshPermissions() {
        accessibilityAllowed = Desktop.hasAccess
        speechAllowed = speech.hasPermissions
        if speechAllowed && !isBusy { wake.start() }
    }

    private func prepare() -> NSRunningApplication? {
        refreshPermissions()
        guard !isLoadingKey else { fail("Approve Desktop Voice's saved-key prompt in Keychain, then try again."); return nil }
        guard hasKey else { fail("Add your TypeSafe API key in Settings."); showSettings(); return nil }
        guard accessibilityAllowed else {
            fail("macOS has not recognised this app's Accessibility grant. If Desktop Voice is already enabled, remove its old entry and add the current app again.")
            showSettings()
            return nil
        }
        guard let app = Desktop.currentTarget(fallback: lastExternalApp) else { fail("Switch to the app you want to control, then try again."); return nil }
        return app
    }

    func beginSpeech() {
        let chainRunning = self.chainRunning
        if chainRunning { speech.cancel() } else { cancel(showStatus: false) }
        guard let app = prepare() else { return }
        target = app
        settingsWindow?.orderOut(nil)
        capturing = true
        isBusy = true
        // Warm the connection, and ask a Chromium or Electron app for its web content, while the user is still speaking.
        // The result is not reused: a capture without the sentence lacks the apps and addresses the sentence names.
        JevClient.warmUp()
        Task { _ = try? await Desktop.capture(application: app, command: "", includeMenus: false) }
        transcript = ""
        timing = ""
        releasedAt = nil
        headline = "Listening…"
        showOverlay()
        let current = generation
        let listening = Task {
            do { try await speech.start() }
            catch is CancellationError {
                guard generation == current else { return }
                capturing = false
                isBusy = false
                headline = "Ready to try again"
                detail = speech.status
            } catch {
                guard generation == current else { return }
                fail(error.localizedDescription)
            }
        }
        if !chainRunning { task = listening }
    }

    func runTyped(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancel(showStatus: false)
        // Coverage audit of the window in front; reads only and never calls Jev, so it needs Accessibility but not the API key.
        let debugHooks = UserDefaults.standard.bool(forKey: "DebugHooks")
        if debugHooks, text == "/probe" {
            guard Desktop.hasAccess, let app = Desktop.currentTarget(fallback: lastExternalApp) else { fail("The probe needs Accessibility access and an app in front."); return }
            headline = "Probing \(app.localizedName ?? "the app")…"
            Task { headline = await Desktop.probe(application: app) }
            return
        }
        // Test hook for the target parser and its verbs, without Jev: `/act 14` performs target [14] of the window in front.
        if debugHooks, text.hasPrefix("/act "), let wanted = Int(text.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
            guard Desktop.hasAccess, let app = Desktop.currentTarget(fallback: lastExternalApp) else { fail("/act needs Accessibility access and an app in front."); return }
            Task {
                do {
                    let snapshot = try await Desktop.capture(application: app, command: "", includeMenus: false)
                    guard let candidate = snapshot.candidates.first(where: { snapshot.meta[$0.id]?.index == wanted && snapshot.kinds[$0.id] != .input }) else { fail("No target [\(wanted)]."); return }
                    let result = try await Desktop.perform(candidate, snapshot: snapshot)
                    log.notice("act [\(wanted)] \(candidate.detail, privacy: .public) → \(result, privacy: .public)")
                    headline = result
                } catch { log.notice("act [\(wanted)] failed: \(error.localizedDescription, privacy: .public)"); fail(error.localizedDescription) }
            }
            return
        }
        guard let app = prepare() else { return }
        settingsWindow?.orderOut(nil)
        JevClient.warmUp()
        run(text, in: app, started: Date())
        spell(text)
    }

    /// Spell `text` one word at a time in the pixel field, then let the pixels drift again.
    /// The pixels spell only live speech. Steps and results show as text under them, so the pixels go back to idle.
    private func clearPixels() { if wordTask == nil { word = nil } }

    /// A typed command is spelled in the pixels word by word, the way live speech is.
    private var wordTask: Task<Void, Never>?
    private func spell(_ command: String) {
        wordTask?.cancel()
        wordTask = Task {
            for piece in command.split(whereSeparator: \.isWhitespace) {
                word = String(piece)
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard !Task.isCancelled else { return }
            }
            word = nil
            wordTask = nil
        }
    }

    private enum StepOutcome { case completed(result: String, actions: Int), stopped }

    private func run(_ command: String, in first: NSRunningApplication, started: Date) {
        task?.cancel()
        generation = UUID()
        let current = generation
        transcript = command
        timing = ""
        clearPixels()
        isBusy = true
        showOverlay()
        log.notice("Command: \(command, privacy: .public)")
        // Context from an earlier command only helps when it answers a "which one" question; otherwise it misleads.
        if !awaitingClarification { priorCommand = nil; priorAction = nil }
        awaitingClarification = false
        chainRunning = true
        task = Task {
            defer {
                chainRunning = false
                if let (next, app) = pendingCommand, generation == current {
                    pendingCommand = nil
                    run(next, in: app, started: Date())
                }
            }
            var modelSeconds = 0.0
            var actions = 0
            var lastResult = "Done"
            do {
                if let plannerKey, UserDefaults.standard.bool(forKey: "PlannerEnabled") {
                headline = "Planning…"
                detail = "Working out the steps."
                let running = NSWorkspace.shared.runningApplications.filter(Desktop.isControllable).compactMap(\.localizedName)
                let beganPlan = Date()
                // The first screen capture does not depend on the plan; run both at once.
                async let warm = try? Desktop.capture(application: first, command: command)
                let planned = try await Planner.plan(utterance: command, frontApp: first.localizedName ?? "Unknown", runningApps: running, apiKey: plannerKey)
                let steps = planned.steps
                let planSeconds = Date().timeIntervalSince(beganPlan)
                try Task.checkCancellation()
                guard generation == current else { return }
                let usage = planned.usage.map { "prompt \($0.prompt), completion \($0.completion), reasoning \($0.reasoning)" } ?? "usage unknown"
                log.notice("Plan (\(String(format: "%.2f", planSeconds), privacy: .public)s, \(planned.model, privacy: .public), \(usage, privacy: .public)): \(steps.map(\.summary).joined(separator: " → "), privacy: .public)")
                var app = first
                var cached = await warm
                for (index, step) in steps.enumerated() {
                    let outcome = try await executePlanned(step, goal: command, app: app, cached: cached,
                                                           label: steps.count > 1 ? "Step \(index + 1) of \(steps.count): " : "",
                                                           generation: current, modelSeconds: &modelSeconds)
                    cached = nil
                    guard generation == current else { return }
                    switch outcome {
                    case .completed(let result, let count): lastResult = result; actions += count
                    case .stopped: timing = String(format: "%.2fs total · %.2fs plan · %.2fs decision", Date().timeIntervalSince(started), planSeconds, modelSeconds); isBusy = false; return
                    }
                    app = Desktop.currentTarget(fallback: lastExternalApp) ?? app
                }
                headline = lastResult
                detail = steps.count > 1 ? "Done: \(steps.count) steps. Hold ⌃⌥Space to speak again." : "Hold ⌃⌥Space to speak again. Escape closes."
                timing = String(format: "%.2fs total · %.2fs plan · %.2fs decision · %d action%@", Date().timeIntervalSince(started), planSeconds, modelSeconds, actions, actions == 1 ? "" : "s")
                } else {
                    // Default: one Jev request per cycle, jev-ultrafast style. Code owns sequencing; Jev picks operation and target.
                    let outcome = try await runCycles(command, app: first, generation: current, modelSeconds: &modelSeconds)
                    guard generation == current else { return }
                    if case .completed(let result, let count) = outcome {
                        actions = count
                        headline = result
                        detail = count > 1 ? "Done in \(count) actions. Hold ⌃⌥Space to speak again." : "Hold ⌃⌥Space to speak again. Escape closes."
                    }
                    timing = String(format: "%.2fs total · %.2fs decision · %d action%@", Date().timeIntervalSince(started), modelSeconds, actions, actions == 1 ? "" : "s")
                }
                clearPixels()
                isBusy = false
            } catch is CancellationError {
                // The cancellation handler already updated the UI.
            } catch {
                guard generation == current else { return }
                fail(error.localizedDescription)
            }
        }
    }

    /// Execute one planned step: deterministic kinds run in code; on-screen kinds are grounded by one narrow Jev question.
    private func executePlanned(_ step: PlanStep, goal: String, app first: NSRunningApplication, cached: DesktopSnapshot?, label: String,
                                generation current: UUID, modelSeconds: inout Double) async throws -> StepOutcome {
        func name(_ app: NSRunningApplication) -> String { app.localizedName ?? "the app" }
        var app = first
        headline = "\(label)\(step.summary)"
        detail = "Executing…"
        clearPixels()
        let keys: [String: CGKeyCode] = ["return": 36, "enter": 36, "space": 49, "escape": 53, "left": 123, "right": 124, "up": 126, "down": 125, "tab": 48]
        switch step.kind {
        case .pressKey:
            guard let code = keys[(step.target ?? "").lowercased()] else { throw DesktopError(message: "Unknown key '\(step.target ?? "")'.") }
            let result = try await Desktop.press(key: code, times: max(1, step.amount ?? 1), in: app)
            log.notice("\(label, privacy: .public)result: \(result, privacy: .public)")
            return .completed(result: "\(step.summary)", actions: 1)
        case .skip:
            let presses = max(1, Int((Double(step.amount ?? 5) / 5).rounded()))
            _ = try await Desktop.press(key: (step.target ?? "forward").lowercased().hasPrefix("b") ? 123 : 124, times: presses, in: app)
            return .completed(result: step.summary, actions: 1)
        case .scroll:
            let result = try await Desktop.scroll(down: !(step.target ?? "down").lowercased().hasPrefix("u"), times: step.amount ?? 1, in: app)
            return .completed(result: result, actions: 1)
        case .openURL:
            let literal = (step.target ?? "").trimmingCharacters(in: .whitespaces)
            let url = URL(string: literal.contains("://") ? literal : "https://\(literal)")
            guard let url, let host = url.host, !host.isEmpty else { throw DesktopError(message: "'\(literal)' is not a web address.") }
            // Keep the site in the browser already in front; any other app means the default browser.
            let browser = Desktop.isBrowser(app) ? app.bundleURL : nil
            let result = try await Desktop.open(website: url, browser: browser)
            log.notice("\(label, privacy: .public)result: \(result, privacy: .public)")
            return .completed(result: result, actions: 1)
        default: break
        }
        let wanted: Set<CandidateKind>
        switch step.kind {
        case .openApp: wanted = [.app]
        case .quitApp: wanted = [.quit]
        case .openFolder: wanted = [.folder]
        case .click: wanted = [.control]
        case .typeText: wanted = [.input]
        case .focusInput: wanted = [.focus]
        case .menu: wanted = [.menu]
        default: wanted = [.control]
        }
        let command = step.kind == .openApp || step.kind == .quitApp ? "\(step.summary)" : goal
        var attempts = 0
        var snapshot = step.kind == .menu ? nil : cached
        while true {
            try Task.checkCancellation()
            guard generation == current, let key else { return .stopped }
            if snapshot == nil {
                headline = "\(label)Reading \(name(app))…"
                snapshot = try await Desktop.capture(application: app, command: command, dictation: step.kind == .typeText ? step.text : nil, includeMenus: step.kind == .menu)
            }
            guard let current_ = snapshot else { return .stopped }
            let candidates = current_.candidates(of: wanted)
            // Exact name matches need no model.
            if [.openApp, .quitApp, .openFolder].contains(step.kind), let target = step.target?.lowercased(),
               let direct = candidates.first(where: { $0.label.lowercased() == "\(step.kind == .quitApp ? "quit" : "open") \(target)\(step.kind == .openFolder ? " folder" : "")" }) {
                let result = try await Desktop.perform(direct, snapshot: current_)
                log.notice("\(label, privacy: .public)direct: \(result, privacy: .public)")
                return .completed(result: result, actions: 1)
            }
            if candidates.isEmpty {
                attempts += 1
                if attempts <= 2 {
                    log.notice("\(label, privacy: .public)no \(String(describing: wanted), privacy: .public) candidates yet, looking again (\(attempts))")
                    try await Task.sleep(nanoseconds: 700_000_000)
                    snapshot = nil
                    app = Desktop.currentTarget(fallback: lastExternalApp) ?? app
                    continue
                }
                headline = "\(label)Nothing to \(step.summary.lowercased()) here"
                detail = "No matching \(step.kind.rawValue.replacingOccurrences(of: "_", with: " ")) target in \(name(app))."
                clearPixels(); isBusy = false
                return .stopped
            }
            headline = "\(label)Choosing…"
            let context = JevClient.GroundingContext(step: step, goal: goal, application: name(app), window: current_.windowTitle)
            let began = Date()
            let decision = try await JevClient.ground(context: context, candidates: candidates, apiKey: key)
            modelSeconds += Date().timeIntervalSince(began)
            try Task.checkCancellation()
            guard generation == current else { return .stopped }
            let chosen = decision.groundedCandidate(from: candidates)
            let probability = decision.groundingProbability
            log.notice("\(label, privacy: .public)ground \(step.kind.rawValue, privacy: .public) over \(candidates.count): \(chosen?.label ?? "none", privacy: .public) \(Int(probability * 100))% done=\(decision.answers["already_done"]?.noul ?? -1)")
            if decision.alreadyDone && [.openApp, .openFolder].contains(step.kind) {
                return .completed(result: "\(step.summary) (already there)", actions: 0)
            }
            guard let chosen else {
                attempts += 1
                if attempts <= 2 {
                    try await Task.sleep(nanoseconds: 700_000_000)
                    snapshot = nil
                    app = Desktop.currentTarget(fallback: lastExternalApp) ?? app
                    continue
                }
                headline = "\(label)Could not find \(step.target ?? step.summary)"
                detail = "Not on screen in \(name(app))."
                clearPixels(); isBusy = false
                return .stopped
            }
            let destructive = step.kind == .quitApp || step.kind == .menu
            if probability < (destructive ? 0.6 : 0.35) {
                let top = (decision.answers["target"]?.probabilities ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                    .compactMap { entry in candidates.first { $0.id == entry.key }?.label }
                headline = "Which one: \(top.joined(separator: " · "))?"
                detail = "Not sure enough for ‘\(step.summary)’. Say which."
                priorCommand = goal
                priorAction = "Asked the user which one they meant for '\(step.summary)'. Closest: \(top.joined(separator: "; "))."
                awaitingClarification = true
                clearPixels(); isBusy = false
                return .stopped
            }
            headline = "\(label)\(chosen.label)"
            clearPixels()
            do {
                let result = try await Desktop.perform(chosen, snapshot: current_)
                log.notice("\(label, privacy: .public)result: \(result, privacy: .public)")
                return .completed(result: result, actions: 1)
            } catch let error as DesktopError where error.stale && attempts < 2 {
                attempts += 1
                log.notice("\(label, privacy: .public)'\(chosen.label, privacy: .public)' changed before use, looking again")
                try await Task.sleep(nanoseconds: 500_000_000)
                snapshot = nil
                app = Desktop.currentTarget(fallback: lastExternalApp) ?? app
            }
        }
    }

    /// jev-ultrafast style loop: every cycle sends the current element table, the goal, the dictation and recent actions,
    /// and asks Jev for one operation plus speculative targets in a single request. Code executes and checks freshness.
    private func runCycles(_ goal: String, app first: NSRunningApplication, generation current: UUID, modelSeconds: inout Double) async throws -> StepOutcome {
        func name(_ app: NSRunningApplication) -> String { app.localizedName ?? "the app" }
        var app = first
        let input = CommandInput(goal)
        // The text to type is chosen by Jev as a first and a last word of the sentence (select, do not generate). The regex
        // splitter only understood "type this: X" and typed "teal into the colour field" for "Type teal into the colour field".
        let dictation: String? = nil
        var recent: [JevClient.RecentAction] = []
        var noChange = 0
        var lastResult = "Done"
        var ineffective = Set<String>()
        var lastPick = ""
        var samePick = 0
        let noEffect = "no visible effect"
        // A stated count is arithmetic: Jev says which step it belongs to, code repeats that step exactly.
        var count = input.count
        var lastOffered = Set<String>()
        var lastClicked = Set<String>()
        var unreadable = 0
        var navigated = false
        var windowChanged = false
        let previous = awaitingClarification ? priorAction : nil
        let words = Set(goal.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        // A chain: the steps that worked in this window, kept as descriptions of their targets. When Jev judges that the goal
        // wants them in every window, code repeats them in the other windows without asking Jev again.
        var chain: [ChainStep] = []
        var chainWindow: AXUIElement?
        var everyWindow = 0.0
        func finish(sure: Bool = true) async throws -> StepOutcome {
            // Repeating multiplies a result by the number of windows, so a doubtful finish is not repeated.
            if everyWindow >= 0.6, !sure {
                lastResult += " · not repeated in the other windows: not sure enough that it worked here"
                headline = lastResult
                return .completed(result: lastResult, actions: recent.count)
            }
            // A step that changed nothing in this window (the quick check and the next full read agree) is not repeated.
            chain = chain.filter(\.effective)
            if everyWindow >= 0.6, !chain.isEmpty {
                lastResult = try await replay(chain, in: app, except: chainWindow, generation: current)
                headline = lastResult
            }
            return .completed(result: lastResult, actions: recent.count)
        }
        for cycle in 1...14 {
            try Task.checkCancellation()
            guard generation == current, let key else { return .stopped }
            headline = cycle == 1 ? "Reading \(name(app))…" : "Looking again…"
            // The command's app may have quit (it was asked to, or the user closed it); continue with the app now in front.
            if app.isTerminated { app = Desktop.currentTarget(fallback: lastExternalApp) ?? app }
            var snapshot = try await Desktop.capture(application: app, command: goal, dictation: dictation)
            // Sites such as YouTube draw their controls after the load event. Right after this command navigated, a browser page
            // with almost no page controls is a skeleton, and one that still offers exactly the old controls has not drawn the new
            // page; a person waits for it to draw, so look again (at most about 3 s).
            func pageControls(_ snapshot: DesktopSnapshot) -> Int { snapshot.candidates(of: [.control, .focus]).filter { snapshot.meta[$0.id]?.place == "page" }.count }
            func offeredIDs(_ snapshot: DesktopSnapshot) -> Set<String> { Set(snapshot.candidates(of: [.control, .focus]).map(\.id)) }
            // A web-content window that just changed (a new note, a new view) builds its tree in steps: one capture saw the title
            // field but not yet the editor, another saw no inputs at all. Read it again until two captures offer the same things.
            if windowChanged, snapshot.usesWebContent {
                for _ in 0..<5 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let next = try await Desktop.capture(application: app, command: goal, dictation: dictation)
                    let same = offeredIDs(next) == offeredIDs(snapshot)
                    snapshot = next
                    if same { break }
                }
            }
            windowChanged = false
            for _ in 0..<8 where navigated && Desktop.isBrowser(app) && (pageControls(snapshot) < 5 || offeredIDs(snapshot) == lastOffered) {
                headline = "Waiting for the page…"
                try await Task.sleep(nanoseconds: 400_000_000)
                snapshot = try await Desktop.capture(application: app, command: goal, dictation: dictation)
            }
            navigated = false
            try Task.checkCancellation()
            guard generation == current else { return .stopped }
            // The quick check after an action sees only the title, the focus and the first 400 controls. The full capture is the
            // authority: when the offered controls differ from the last cycle's, the last action did change the screen.
            let offered = offeredIDs(snapshot)
            if let last = recent.last, last.result.hasSuffix(noEffect), offered != lastOffered {
                recent[recent.count - 1] = JevClient.RecentAction(action: last.action, result: last.result.replacingOccurrences(of: noEffect, with: "the window's content changed"), screenChanged: false)
                noChange = 0
                ineffective.subtract(lastClicked)
                if !chain.isEmpty { chain[chain.count - 1].effective = true }
            }
            lastOffered = offered

            // Element table: on-screen controls and inputs, numbered in screen order, with current values.
            var elements: [JevClient.Element] = []
            var heads: [String: [String: String]] = [:]
            var operations: [String: String] = [:]
            func option(_ candidate: Candidate) -> String { candidate.detail }
            // Toolbar controls (tabs, address bar) only compete when the sentence is about them; page content wins otherwise.
            let toolbarWords: Set<String> = ["tab", "tabs", "address", "bookmark", "bookmarks", "back", "forward", "reload", "toolbar", "extension"]
            let aboutToolbar = !words.isDisjoint(with: toolbarWords)
            let allClicks = snapshot.candidates(of: [.control]).filter { !ineffective.contains($0.id) }
            let pageClicks = allClicks.filter { snapshot.meta[$0.id]?.place == "page" }
            // Page content first; a window that also has native controls beside its page (a sidebar, a list) keeps them.
            let beside = allClicks.filter { snapshot.meta[$0.id]?.place == nil }
            let clicks = (aboutToolbar || pageClicks.isEmpty) ? allClicks : pageClicks + beside
            let inputs = snapshot.candidates(of: [.focus])
            // One list feeds the element table and the click head; with the inputs it stays under TypeSafe's 255-option limit.
            func trimmed(_ list: [Candidate], limit: Int = 250) -> [Candidate] {
                guard list.count > limit else { return list }
                let relevant = list.filter { candidate in words.contains { candidate.label.lowercased().contains($0) } }
                let rest = list.filter { !relevant.contains($0) }
                return Array((relevant + rest).prefix(limit))
            }
            let offeredClicks = trimmed(clicks, limit: max(50, 250 - inputs.count))
            for candidate in offeredClicks + inputs {
                guard let meta = snapshot.meta[candidate.id] else { continue }
                let ops = snapshot.kinds[candidate.id] == .focus ? ["TYPE_TEXT", "CLICK"] : ["CLICK"]
                elements.append(JevClient.Element(index: meta.index, role: meta.role, label: candidate.label, value: meta.value, place: meta.place, operations: ops))
            }
            if !clicks.isEmpty {
                heads["click_target"] = Dictionary(uniqueKeysWithValues: (offeredClicks + inputs).map { ($0.id, option($0)) })
                operations["CLICK"] = "Click or press the control chosen in click_target."
            }
            let tokens = goal.split(separator: " ").map(String.init)
            if !inputs.isEmpty {
                heads["type_target"] = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, option($0)) })
                // The wanted input may not be on screen yet (a narrow page keeps its search box behind a button). Jev can say so.
                heads["type_target"]?["none"] = "None of the offered inputs is the one the goal means: for example the goal means the search box or a field of the site in the page, the page does not show it yet, and only the app's own address bar is offered. The right input still has to be opened or revealed by a click or a menu item."
                operations["TYPE_TEXT"] = dictation.map { "Enter the dictated text '\($0)' into the input chosen in type_target, at its cursor; does not submit." }
                    ?? "Enter into the input chosen in type_target the text that runs from the word chosen in type_from to the word chosen in type_to; does not submit. When the input the goal means is not among the offered inputs (a narrow page hides its search box behind a Search button), CLICK the control that reveals it instead of typing into a different input."
                // One option per word, shown with its neighbours so a repeated word can be told apart.
                var words: [String: String] = [:]
                for (index, token) in tokens.enumerated() {
                    let before = index > 0 ? tokens[index - 1] + " " : "", after = index + 1 < tokens.count ? " " + tokens[index + 1] : ""
                    words["w\(index)"] = "word \(index + 1) of \(tokens.count): …\(before)[\(token)]\(after)…"
                }
                heads["type_from"] = words
                heads["type_to"] = words
            }
            let apps = snapshot.candidates(of: [.app])
            if !apps.isEmpty { heads["app_target"] = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.detail) }); operations["OPEN_APP"] = "Open or switch to the application chosen in app_target." }
            let sites = snapshot.candidates(of: [.website])
            if !sites.isEmpty { heads["url_target"] = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0.detail) }); operations["OPEN_URL"] = "Open the website named in the goal, using the browser chosen in url_target." }
            let folders = snapshot.candidates(of: [.folder])
            if !folders.isEmpty { heads["folder_target"] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.detail) }); operations["OPEN_FOLDER"] = "Open the folder chosen in folder_target." }
            let menus = snapshot.candidates(of: [.menu]).filter { candidate in words.contains { candidate.label.lowercased().contains($0) } || ["close", "quit", "new", "save", "undo", "find", "reload"].contains { candidate.label.lowercased().contains($0) } }
            if !menus.isEmpty { heads["menu_target"] = Dictionary(uniqueKeysWithValues: trimmed(menus, limit: 120).map { ($0.id, $0.detail) }); operations["MENU"] = "Choose the app menu item chosen in menu_target (close window, new tab, save, quit and other app commands). A menu item acts on the current window or the app, never on several windows at once." }
            let quits = snapshot.candidates(of: [.quit])
            if !quits.isEmpty { heads["quit_target"] = Dictionary(uniqueKeysWithValues: quits.map { ($0.id, $0.detail) }); operations["QUIT_APP"] = "Quit the running application chosen in quit_target." }
            operations["PRESS_RETURN"] = "Press Return: submits the focused input or search box."
            operations["PRESS_ESCAPE"] = "Press Escape: closes a menu, dialog or full-screen view."
            operations["SCROLL_DOWN"] = "Scroll down one screen in the current window."
            operations["SCROLL_UP"] = "Scroll up one screen in the current window."
            operations["SKIP_FORWARD"] = "Skip a playing video or track forward 5 seconds (Right arrow)."
            operations["SKIP_BACK"] = "Skip a playing video or track back 5 seconds (Left arrow)."
            operations["GO_BACK"] = "Go back to the previous page or folder."
            operations["NEXT_TAB"] = "Switch to the next tab."
            let arrangements = snapshot.candidates(of: [.window])
            if !arrangements.isEmpty {
                heads["arrange_target"] = Dictionary(uniqueKeysWithValues: arrangements.map { ($0.id, $0.detail) })
                operations["ARRANGE_WINDOWS"] = "Move and resize windows as chosen in arrange_target. The only action that places several or all of this app's windows at once (tile, spread out, side by side, cascade, none stacked); a menu item moves one window only. Also puts the current window on one half of the screen."
            }
            operations["WAIT"] = "Wait briefly because the needed control is absent or results are still loading."
            operations["DONE"] = "Every part of the goal is visibly satisfied."
            operations["BLOCKED"] = "No offered operation can make progress on the goal."

            let available = JevClient.Available(apps: apps.map(\.label), folders: folders.map(\.label), sites: sites.map(\.label), menus: menus.map(\.label))
            let windowCount = Desktop.windows(of: app).count
            let state = JevClient.CycleState(goal: goal, dictation: dictation, application: name(app), window: snapshot.windowTitle,
                                             elements: elements, available: available, recentActions: Array(recent.suffix(10)), previous: previous, count: count,
                                             otherWindows: windowCount > 1 ? windowCount - 1 : nil)
            headline = cycle == 1 ? "Choosing…" : "Choosing again…"
            detail = "\(elements.count) controls in \(name(app))."
            let began = Date()
            log.notice("cycle \(cycle) offers: \(heads.map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "), privacy: .public)")
            let decision = try await JevClient.cycle(state: state, operations: operations, heads: heads, apiKey: key)
            modelSeconds += Date().timeIntervalSince(began)
            try Task.checkCancellation()
            guard generation == current, var op = decision.choice("operation") else { throw DecisionError.invalidResponse }
            // Dictated text pulls Jev toward typing at once. When Jev itself judges that the sentence first creates something new
            // (a new note) and that has not happened, take its better one of MENU and CLICK, the operations that create things.
            // `finishes` was judged for typing, so it is not used after a substitution.
            var substituted = false
            var inputMissing = false
            if op.id == "TYPE_TEXT", decision.choice("type_target")?.id == "none",
               let next = (decision.answers["operation"]?.probabilities ?? [:]).filter({ ["MENU", "CLICK"].contains($0.key) }).max(by: { $0.value < $1.value }) {
                substituted = true
                inputMissing = true
                log.notice("cycle \(cycle): the wanted input is not offered; \(next.key, privacy: .public) \(Int(next.value * 100))% instead of TYPE_TEXT \(Int(op.probability * 100))%")
                op = (next.key, next.value, op.confidence)
            }
            if op.id == "TYPE_TEXT", let create = decision.answers["create_first"]?.noul, create >= 0.5,
               let next = (decision.answers["operation"]?.probabilities ?? [:]).filter({ ["MENU", "CLICK"].contains($0.key) }).max(by: { $0.value < $1.value }) {
                substituted = true
                log.notice("cycle \(cycle): create first (\(Int(create * 100))%); \(next.key, privacy: .public) \(Int(next.value * 100))% instead of TYPE_TEXT \(Int(op.probability * 100))%")
                op = (next.key, next.value, op.confidence)
            }
            if decision.answers["every_window"] != nil { everyWindow = decision.noul("every_window") }
            let headName: String? = ["CLICK": "click_target", "TYPE_TEXT": "type_target", "OPEN_APP": "app_target", "OPEN_URL": "url_target",
                                     "OPEN_FOLDER": "folder_target", "MENU": "menu_target", "QUIT_APP": "quit_target", "ARRANGE_WINDOWS": "arrange_target"][op.id]
            var target = headName.flatMap { decision.choice($0) }
            if inputMissing, op.id == "CLICK", let best = (decision.answers["click_target"]?.probabilities ?? [:])
                .filter({ entry in !inputs.contains { $0.id == entry.key } }).max(by: { $0.value < $1.value }) {
                target = (best.key, best.value, target?.confidence ?? best.value)
            }
            let targetCandidate = target.flatMap { t in snapshot.candidates.first { $0.id == t.id } }
            log.notice("cycle \(cycle): \(op.id, privacy: .public) \(Int(op.probability * 100))% conf \(String(format: "%.2f", op.confidence), privacy: .public)\(targetCandidate.map { " → \($0.label) \(Int((target?.probability ?? 0) * 100))% conf \(String(format: "%.2f", target?.confidence ?? 0))" } ?? "", privacy: .public) · \(elements.count) elements · finishes \(Int(decision.noul("finishes") * 100))%\(decision.answers["create_first"] == nil ? "" : " create_first \(Int(decision.noul("create_first") * 100))%")\(count == nil ? "" : " counted \(Int(decision.noul("counted") * 100))%", privacy: .public)")

            // A web app whose content could not be read is not evidence that the goal is done or impossible; look again first.
            if ["DONE", "BLOCKED"].contains(op.id), snapshot.usesWebContent, !snapshot.webContentReady, snapshot.window != nil, unreadable < 2 {
                unreadable += 1
                log.notice("cycle \(cycle): ignored \(op.id, privacy: .public) on an unreadable screen")
                try await Task.sleep(nanoseconds: 400_000_000)
                continue
            }
            switch op.id {
            case "DONE":
                if recent.isEmpty { headline = "Already done"; detail = "Nothing to do for: \(goal)" }
                return try await finish(sure: op.probability >= 0.6)
            case "BLOCKED":
                headline = recent.isEmpty ? "Can't do that here" : lastResult
                detail = recent.isEmpty ? "Nothing on screen in \(name(app)) can do: \(goal)" : "Stopped after \(recent.count) actions: nothing on screen can continue."
                clearPixels(); isBusy = false
                return .stopped
            case "WAIT":
                try await Task.sleep(nanoseconds: 400_000_000)
                recent.append(JevClient.RecentAction(action: "WAIT", result: "waited 0.4s", screenChanged: false))
                continue
            default: break
            }
            if headName != nil && targetCandidate == nil {
                recent.append(JevClient.RecentAction(action: op.id, result: "no target offered", screenChanged: false))
                noChange += 1
                if noChange >= 3 { headline = "Can't find it"; detail = "No target for \(op.id.lowercased()) in \(name(app))."; clearPixels(); isBusy = false; return .stopped }
                continue
            }
            // Return sends and submits, and it has no target to gate. In about 13 logged Returns the correct ones had confidence 0.51 or
            // more and two wrong ones (0.47 in a chat app, 0.35 on a playing video) were below; one wrong Return at 0.73 came from acting
            // on the user's app, which is fixed separately. An unsure Return is not pressed; that costs one cycle and does no harm.
            if op.id == "PRESS_RETURN", op.confidence < 0.5 {
                recent.append(JevClient.RecentAction(action: "PRESS_RETURN", result: "NOT performed: not sure enough that the goal asks for Return here", screenChanged: false))
                noChange += 1
                if noChange >= 3 { headline = lastResult; detail = "Stopped: not sure what to do next."; clearPixels(); isBusy = false; return .stopped }
                continue
            }
            // Confidence gates: destructive picks need a clear winner; anything else only a floor.
            let destructive = op.id == "QUIT_APP" || (["MENU", "CLICK"].contains(op.id) && ["quit", "close", "delete", "remove", "trash", "empty", "discard", "clear"].contains { targetCandidate?.label.lowercased().contains($0) == true })
            let gate = destructive ? 0.6 : 0.2
            if let target, target.confidence < gate {
                let top = (decision.answers[headName!]?.probabilities ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                    .compactMap { entry in snapshot.candidates.first { $0.id == entry.key }?.label }
                headline = "Which one: \(top.joined(separator: " · "))?"
                detail = "Not sure enough. Say which."
                priorCommand = goal
                priorAction = "Asked which one for '\(goal)'. Closest: \(top.joined(separator: "; "))."
                awaitingClarification = true
                clearPixels(); isBusy = false
                return .stopped
            }

            let pick = "\(op.id)|\(targetCandidate?.id ?? "")"
            // Arranging is idempotent and was read back as done. Jev cannot see window positions, so it may ask for the same
            // arrangement again; asking again for what verifiably just happened means the goal is met, not that it failed.
            if op.id == "ARRANGE_WINDOWS", pick == lastPick, lastResult.hasPrefix("Arranged") || lastResult.contains("moved to its new place") {
                return try await finish()
            }
            samePick = pick == lastPick ? samePick + 1 : 0
            lastPick = pick
            if samePick >= 2 && !["SCROLL_DOWN", "SCROLL_UP", "SKIP_FORWARD", "SKIP_BACK"].contains(op.id) {
                headline = lastResult
                detail = "Stopped: \(op.id.lowercased()) \(targetCandidate?.label ?? "") was chosen three times without finishing."
                clearPixels(); isBusy = false
                return .stopped
            }
            let before = Desktop.fingerprint(of: app)
            let appBefore = app.processIdentifier
            let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let titleBefore = snapshot.windowTitle
            let label = targetCandidate?.label ?? op.id.replacingOccurrences(of: "_", with: " ").capitalized
            headline = label
            clearPixels()
            var result: String
            var typed: String?
            var changeWait = 0.25
            let repetitions = decision.noul("counted") >= 0.6 ? count ?? 1 : 1
            do {
                if repetitions > 1, ["CLICK", "MENU", "NEXT_TAB", "GO_BACK", "PRESS_RETURN", "PRESS_ESCAPE"].contains(op.id) {
                    let action = targetCandidate.flatMap { snapshot.actions[$0.id] } ?? .key(["NEXT_TAB": 48, "GO_BACK": 33, "PRESS_RETURN": 36][op.id] ?? 53, op.id == "NEXT_TAB" ? .maskControl : op.id == "GO_BACK" ? .maskCommand : [])
                    var performed = 0
                    do {
                        for _ in 0..<repetitions {
                            _ = try await Desktop.perform(action, label: label, snapshot: snapshot)
                            performed += 1
                        }
                    } catch let error as DesktopError where error.stale && performed > 0 {}
                    result = "\(label): performed \(performed) of the \(repetitions) times the goal asks"
                    count = performed < repetitions ? repetitions - performed : nil
                } else {
                    switch op.id {
                    case "CLICK", "OPEN_APP", "OPEN_FOLDER", "MENU", "QUIT_APP", "OPEN_URL", "ARRANGE_WINDOWS":
                        result = try await Desktop.perform(targetCandidate!, snapshot: snapshot)
                        if ["OPEN_APP", "OPEN_URL", "OPEN_FOLDER"].contains(op.id) { changeWait = 1.0 }
                    case "TYPE_TEXT":
                        guard case .focus(let element, _) = snapshot.actions[targetCandidate!.id] ?? .scroll(0) else { throw DecisionError.invalidResponse }
                        let from = decision.choice("type_from").flatMap { Int($0.id.dropFirst()) }, to = decision.choice("type_to").flatMap { Int($0.id.dropFirst()) }
                        let chosen = from.flatMap { first in to.map { last in first <= last ? tokens[first...last].joined(separator: " ") : tokens[first] } }
                        let text = (dictation ?? chosen ?? Self.searchWords(from: goal)).trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
                        log.notice("cycle \(cycle): text to type, words \(from.map { $0 + 1 } ?? 0)–\(to.map { $0 + 1 } ?? 0): '\(text, privacy: .public)'")
                        guard !text.isEmpty else { throw DesktopError(message: "Nothing to type: say the text after 'type' or name what to search.") }
                        result = try await Desktop.perform(.type(text, element), label: targetCandidate!.label, snapshot: snapshot)
                        result += " ('\(text)')"
                        typed = text
                    case "PRESS_RETURN": result = try await Desktop.press(key: 36, times: 1, in: app); changeWait = 0.6
                    case "PRESS_ESCAPE": result = try await Desktop.press(key: 53, times: 1, in: app)
                    case "SCROLL_DOWN": result = try await Desktop.scroll(down: true, times: repetitions, in: app)
                    case "SCROLL_UP": result = try await Desktop.scroll(down: false, times: repetitions, in: app)
                    case "SKIP_FORWARD": result = try await Desktop.press(key: 124, times: repetitions, in: app)
                    case "SKIP_BACK": result = try await Desktop.press(key: 123, times: repetitions, in: app)
                    case "GO_BACK": result = try await Desktop.perform(.key(33, .maskCommand), label: "Go back", snapshot: snapshot)
                    case "NEXT_TAB": result = try await Desktop.perform(.key(48, .maskControl), label: "Next tab", snapshot: snapshot)
                    default: throw DecisionError.invalidResponse
                    }
                    if repetitions > 1, ["SCROLL_DOWN", "SCROLL_UP", "SKIP_FORWARD", "SKIP_BACK"].contains(op.id) { count = nil }
                }
            } catch let error as DesktopError where error.stale {
                recent.append(JevClient.RecentAction(action: "\(op.id) \(label)", result: "NOT performed: the control changed before it could be used", screenChanged: false))
                continue
            }
            guard generation == current else { return .stopped }
            // The command moves to another app only when its own action opened one. It never follows the app the user looks at
            // meanwhile; `perform` brings the command's app back to the front before it acts.
            func running(_ url: URL) -> NSRunningApplication? {
                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && Desktop.isControllable($0) }
            }
            switch targetCandidate.flatMap({ snapshot.actions[$0.id] }) {
            case .application(let url), .website(_, browser: let url): app = running(url) ?? app
            case .folder: app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first ?? app
            default: break
            }
            // Opening an app, folder or site already waited for its window inside `perform`.
            let opened = ["OPEN_URL", "OPEN_APP", "OPEN_FOLDER"].contains(op.id)
            let changed = opened ? true : try await Desktop.waitForChange(in: app, from: before, upTo: changeWait)
            // A click that itself brought another app forward (a link, a file) moves the command there. An app that was already in
            // front before the action is the user's doing and is not followed.
            if !opened, let front = NSWorkspace.shared.frontmostApplication, Desktop.isControllable(front),
               front.processIdentifier != app.processIdentifier, front.processIdentifier != frontBefore { app = front }
            // Then let the screen hold still so the next capture sees the new state, not the transition. A web page that navigated
            // keeps rendering after its title settles, and the quick check cannot see past 400 controls, so count its controls instead.
            if changed, !opened {
                if snapshot.usesWebContent, op.id == "PRESS_RETURN" || (op.id != "TYPE_TEXT" && Desktop.describe(app).title != titleBefore) {
                    try await Desktop.waitForPageToSettle(app, timeout: 2)
                } else {
                    try await Desktop.waitForQuiet(in: app, quiet: 0.15, upTo: 0.5)
                }
            }
            let after = Desktop.describe(app)
            windowChanged = after.title != titleBefore
            navigated = op.id == "OPEN_URL" || (after.title != titleBefore && ["PRESS_RETURN", "CLICK", "GO_BACK"].contains(op.id))
            // Opening a site that is already showing (Google home to Google home) legitimately offers the same controls again.
            if op.id == "OPEN_URL" { lastOffered = [] }
            let scrolled = result.contains("the content moved")
            let arranged = op.id == "ARRANGE_WINDOWS" && changed
            let effect = after.title != titleBefore ? "window is now '\(after.title)'" : scrolled ? "new content is on screen"
                : arranged ? "the window moved to its new place" : (changed ? "focus is now \(after.focused)" : noEffect)
            lastClicked = []
            if op.id == "CLICK", after.title == titleBefore, after.focused.contains(label) || !changed, let id = targetCandidate?.id { ineffective.insert(id); lastClicked = [id] }
            result += " → \(effect)"
            log.notice("cycle \(cycle) result: \(result, privacy: .public)")
            recent.append(JevClient.RecentAction(action: "\(op.id) \(label)", result: result, screenChanged: after.title != titleBefore))
            lastResult = result
            priorCommand = goal
            priorAction = "\(op.id) \(label)"
            // Record the step for the chain. Steps about the whole set of windows (open, close, arrange, a counted repeat) or
            // about another app are not part of what each window needs, and a step in a new app starts a new chain.
            if app.processIdentifier != appBefore { chain = []; chainWindow = nil }
            let sameWindows = app.processIdentifier != appBefore || Desktop.windows(of: app).count == windowCount
            let perWindow = !["ARRANGE_WINDOWS", "OPEN_APP", "OPEN_FOLDER", "QUIT_APP"].contains(op.id) && repetitions == 1 && sameWindows
            if perWindow, app.processIdentifier == appBefore || op.id == "OPEN_URL" {
                let meta = targetCandidate.flatMap { snapshot.meta[$0.id] }
                let alike = snapshot.candidates(of: [.control, .focus]).filter { snapshot.meta[$0.id]?.role == meta?.role && snapshot.meta[$0.id]?.place == meta?.place }
                chain.append(ChainStep(operation: op.id, label: label, role: meta?.role, place: meta?.place,
                                       ordinal: targetCandidate.flatMap { target in alike.firstIndex { $0.id == target.id } } ?? 0,
                                       text: typed, action: targetCandidate.flatMap { snapshot.actions[$0.id] }, effective: changed))
                chainWindow = Desktop.windows(of: app).first
            }
            // Jev judged, in the same request, that this operation completes the goal; when the action visibly worked, a further
            // cycle only to hear DONE is time a person would not spend.
            let worked = after.title != titleBefore || result.hasPrefix("Typed into") || result.hasPrefix("Opened") || result.contains("the content moved") || result.hasPrefix("Arranged") || arranged
            if decision.noul("finishes") >= 0.8, worked, count == nil, !substituted {
                log.notice("cycle \(cycle): finished without a DONE cycle")
                return try await finish()
            }
            noChange = changed ? 0 : noChange + 1
            if noChange >= 3 {
                headline = lastResult
                detail = "Stopped: three actions changed nothing."
                clearPixels(); isBusy = false
                return .stopped
            }
        }
        headline = lastResult
        detail = "Stopped after 14 actions."
        return .completed(result: lastResult, actions: recent.count)
    }

    /// One recorded step: the operation and a description of its target that can be found again in another window.
    private struct ChainStep {
        let operation: String, label: String, role: String?, place: String?, ordinal: Int, text: String?, action: DesktopAction?
        var effective: Bool
    }

    /// Repeat a recorded chain in every other window of the app, without Jev. It goes step by step across the windows, so the
    /// pages of all windows load at the same time. A target is found by its name, or else by its kind, place and order; a target
    /// that is not there yet is waited for (at most about 5 s), and a window where it never appears is reported, not guessed.
    private func replay(_ chain: [ChainStep], in app: NSRunningApplication, except recorded: AXUIElement?, generation current: UUID) async throws -> String {
        let others = Desktop.windows(of: app).filter { window in recorded.map { !CFEqual($0, window) } ?? true }
        guard !others.isEmpty else { return "Done in this window; there are no other windows" }
        var failed = Set<Int>()
        let began = Date()
        for step in chain {
            let stepBegan = Date()
            defer { log.notice("replay: \(step.operation, privacy: .public) \(step.label, privacy: .public) across \(others.count - failed.count) windows took \(String(format: "%.1f", Date().timeIntervalSince(stepBegan)), privacy: .public) s") }
            for (index, window) in others.enumerated() where !failed.contains(index) {
                try Task.checkCancellation()
                guard generation == current else { return "Cancelled" }
                headline = "\(step.label) · window \(index + 2) of \(others.count + 1)"
                try await Desktop.raise(window, of: app)
                do {
                    switch (step.operation, step.action) {
                    case ("OPEN_URL", .website(let url, let browser)?):
                        _ = try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
                        try await Task.sleep(nanoseconds: 150_000_000)
                    case ("PRESS_RETURN", _): _ = try await Desktop.press(key: 36, times: 1, in: app)
                    case ("PRESS_ESCAPE", _): _ = try await Desktop.press(key: 53, times: 1, in: app)
                    case ("SKIP_FORWARD", _): _ = try await Desktop.press(key: 124, times: 1, in: app)
                    case ("SKIP_BACK", _): _ = try await Desktop.press(key: 123, times: 1, in: app)
                    case ("SCROLL_DOWN", _): _ = try await Desktop.scroll(down: true, times: 1, in: app)
                    case ("SCROLL_UP", _): _ = try await Desktop.scroll(down: false, times: 1, in: app)
                    case ("GO_BACK", _), ("NEXT_TAB", _), ("MENU", _):
                        let snapshot = try await Desktop.capture(application: app, command: "", includeMenus: false)
                        let action = step.action ?? .key(step.operation == "NEXT_TAB" ? 48 : 33, step.operation == "NEXT_TAB" ? .maskControl : .maskCommand)
                        _ = try await Desktop.perform(action, label: step.label, snapshot: snapshot)
                    default:
                        var found: (Candidate, DesktopSnapshot)?
                        for attempt in 0..<12 where found == nil {
                            if attempt > 0 { try await Task.sleep(nanoseconds: 400_000_000) }
                            let snapshot = try await Desktop.capture(application: app, command: "", includeMenus: false)
                            let pool = snapshot.candidates(of: step.operation == "TYPE_TEXT" ? [.focus] : [.control, .focus])
                            let alike = pool.filter { snapshot.meta[$0.id]?.role == step.role && snapshot.meta[$0.id]?.place == step.place }
                            // The same name first. Without it (a result list whose titles differ), the same kind, place and order,
                            // but only on a screen that is not the one the step already left behind in this window.
                            // A repeated name carries "(2 of 5)"; the count can differ between windows, the name and its turn do not.
                            func parts(_ label: String) -> (name: String, turn: Int) {
                                guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards), let of = label.range(of: " of ", options: .backwards),
                                      open.upperBound <= of.lowerBound, let turn = Int(label[open.upperBound..<of.lowerBound]) else { return (label, 1) }
                                return (String(label[..<open.lowerBound]), turn)
                            }
                            let wanted = parts(step.label)
                            let named = pool.filter { parts($0.label).name == wanted.name }
                            if let same = pool.first(where: { $0.label == step.label }) { found = (same, snapshot) }
                            else if let same = named.first(where: { parts($0.label).turn == wanted.turn }) ?? (named.count == 1 ? named.first : nil) { found = (same, snapshot) }
                            else if attempt >= 3, step.ordinal < alike.count { found = (alike[step.ordinal], snapshot) }
                        }
                        guard let (target, snapshot) = found else { throw DesktopError(message: "'\(step.label)' did not appear") }
                        if step.operation == "TYPE_TEXT", let text = step.text, case .focus(let element, _)? = snapshot.actions[target.id] {
                            _ = try await Desktop.perform(.type(text, element), label: target.label, snapshot: snapshot)
                        } else {
                            _ = try await Desktop.perform(target, snapshot: snapshot)
                        }
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    failed.insert(index)
                    log.notice("replay: window \(index + 2), step \(step.operation, privacy: .public) \(step.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let result = "Repeated \(chain.count) steps in \(others.count - failed.count) of \(others.count) other windows"
        log.notice("replay: \(result, privacy: .public) in \(String(format: "%.1f", Date().timeIntervalSince(began)), privacy: .public) s")
        return result
    }

    /// Without explicit dictation, the words to type are the goal minus its command verbs and site names.
    private static func searchWords(from goal: String) -> String {
        let stop: Set<String> = ["go", "to", "on", "open", "search", "for", "look", "up", "type", "in", "into", "the", "and", "then", "click", "first", "video", "play", "press", "enter", "return", "a", "an", "please", "can", "you", "it", "this", "that", "result", "results"]
        return goal.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
            .filter { word in !stop.contains(word.lowercased()) && !word.lowercased().contains(".") }
            .joined(separator: " ")
    }

    /// Fallback loop: run one command through capture → Jev → execute until Jev reports it complete.
    private func execute(_ command: String, dictation: String?, goal: String?, app first: NSRunningApplication, label: String,
                         generation current: UUID, modelSeconds: inout Double) async throws -> StepOutcome {
        func name(_ app: NSRunningApplication) -> String { app.localizedName ?? "the app" }
        var app = first
        var steps: [String] = []
        var lastStep: String?
        var repeats = 0
        var retries = 0
        var lastResult = "Done"
        let budget = goal == nil ? maxSteps : 4
        chain: while true {
            try Task.checkCancellation()
            guard generation == current, let key else { return .stopped }
            let number = steps.count + 1
            headline = "\(label)Reading \(name(app))…"
            detail = goal == nil ? "Finding the current controls." : command
            let snapshot = try await Desktop.capture(application: app, command: command, dictation: dictation)
            try Task.checkCancellation()
            guard generation == current else { return .stopped }
            headline = "\(label)Choosing an action…"
            detail = "\(snapshot.candidates.count) available actions in \(name(app))."
            let context = CommandContext(command: command, application: name(app), window: snapshot.windowTitle, completedSteps: steps,
                                         overallGoal: goal, previousCommand: priorCommand, previousAction: priorAction)
            let beganModel = Date()
            let decision = try await JevClient.decide(context: context, candidates: snapshot.candidates, apiKey: key)
            modelSeconds += Date().timeIntervalSince(beganModel)
            try Task.checkCancellation()
            guard generation == current, let answer = decision.answers["action"], answer.type == "choice" else { throw DecisionError.invalidResponse }
            let ranked: [(String, Double)] = (answer.probabilities ?? [:]).sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) }
            let top: [String] = ranked.map { entry in
                let title = snapshot.candidates.first { $0.id == entry.0 }?.label ?? entry.0
                return "\(title) \(Int(entry.1 * 100))%"
            }
            let more = decision.answers["more"]?.noul ?? -1
            let again = decision.answers["repeat"]?.noul ?? -1
            log.notice("\(label, privacy: .public)action \(number): chose \(answer.choice ?? "?", privacy: .public) [\(top.joined(separator: ", "), privacy: .public)] more=\(more) repeat=\(again)")
            switch answer.choice {
            case "cancel": headline = "Cancelled"; detail = "No action taken."
            case "clarify":
                let options = ranked.compactMap { entry in snapshot.candidates.first { $0.id == entry.0 }?.label }
                headline = options.isEmpty ? "Which one?" : "Which one: \(options.joined(separator: " · "))?"
                detail = options.isEmpty ? "Say the app, tab or control name to choose a target." : "Say which, for example ‘the first one’."
                priorCommand = command
                priorAction = "Asked the user which one they meant. Closest actions were: \(options.joined(separator: "; "))."
                awaitingClarification = true
            case "done":
                if steps.isEmpty { headline = "Already done"; detail = "\(command) needed no action." }
                return .completed(result: lastResult, actions: steps.count)
            case "unavailable":
                if retries < 2 {
                    // Pages and apps keep changing for a moment after a step; look again before giving up.
                    retries += 1
                    log.notice("\(label, privacy: .public)nothing matched yet, looking again (\(retries))")
                    try await Task.sleep(nanoseconds: 700_000_000)
                    continue chain
                }
                headline = steps.isEmpty ? "\(label)That action is not available" : lastResult
                detail = steps.isEmpty ? (snapshot.folderAccessError ?? "Name the folder, app, control or website you want.")
                    : "Stopped after \(steps.count) steps: the next step is not available here."
            default:
                let candidate = try decision.selectedCandidate(from: snapshot.candidates)
                // Destructive picks need a clear winner; a 43 % "Quit Slack" once quit the wrong app.
                let destructive = ["quit", "close", "delete", "remove", "trash", "empty", "discard", "clear"].contains { candidate.label.lowercased().contains($0) }
                if destructive, (ranked.first?.1 ?? 0) < 0.6 {
                    let options = ranked.compactMap { entry in snapshot.candidates.first { $0.id == entry.0 }?.label }
                    headline = "Which one: \(options.joined(separator: " · "))?"
                    detail = "Not sure enough to \(candidate.label.lowercased()). Say which."
                    priorCommand = command
                    priorAction = "Asked the user which one they meant. Closest actions were: \(options.joined(separator: "; "))."
                    awaitingClarification = true
                    log.notice("\(label, privacy: .public)held back destructive '\(candidate.label, privacy: .public)' at \(Int((ranked.first?.1 ?? 0) * 100))%")
                    break chain
                }
                let signature = candidate.detail + "|" + snapshot.windowTitle
                // Repeating a step is normal ("skip forward 30 seconds" is six arrow presses); stop only after eight identical rounds.
                repeats = signature == lastStep ? repeats + 1 : 0
                if repeats >= 8 {
                    headline = lastResult
                    detail = "Stopped: the same step kept repeating."
                    break chain
                }
                headline = "\(label)\(candidate.label)"
                detail = "Executing in \(name(app))…"
                clearPixels()
                let result: String
                do {
                    result = try await Desktop.perform(candidate, snapshot: snapshot)
                } catch let error as DesktopError where error.stale && retries < 2 {
                    retries += 1
                    log.notice("\(label, privacy: .public)'\(candidate.label, privacy: .public)' changed before use, looking again (\(retries))")
                    steps.append("Tried '\(candidate.label)' but that control changed before it could be used; choose from the current controls")
                    try await Task.sleep(nanoseconds: 500_000_000)
                    app = Desktop.currentTarget(fallback: lastExternalApp) ?? app
                    continue chain
                }
                guard generation == current else { return .stopped }
                retries = 0
                log.notice("\(label, privacy: .public)result: \(result, privacy: .public)")
                steps.append(candidate.label)
                lastStep = signature
                lastResult = result
                priorCommand = command
                priorAction = candidate.detail
                if decision.needsMoreSteps && steps.count < budget {
                    app = Desktop.currentTarget(fallback: lastExternalApp) ?? app
                    continue chain
                }
                headline = result
                return .completed(result: result, actions: steps.count)
            }
            break chain
        }
        clearPixels()
        isBusy = false
        return .stopped
    }

    func cancel(showStatus: Bool = true) {
        generation = UUID()
        task?.cancel()
        task = nil
        chainRunning = false
        pendingCommand = nil
        capturing = false
        speech.cancel()
        isBusy = false
        if showStatus {
            headline = "Cancelled"
            detail = "Pending work stopped. Actions already sent cannot be recalled."
            clearPixels()
            showOverlay()
        }
    }

    private func fail(_ message: String) {
        capturing = false
        isBusy = false
        headline = "Command stopped"
        detail = message
        clearPixels()
        showOverlay()
    }

    func showSettings() {
        refreshPermissions()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Desktop Voice"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.center()
            settingsWindow = window
        }
        overlay?.orderOut(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showVoiceWidget() {
        refreshPermissions()
        settingsWindow?.orderOut(nil)
        if !isBusy {
            headline = setupComplete ? "Ready when you are" : "Finish setup to use voice"
            detail = setupComplete ? "Hold ⌃⌥Space to speak. Release to act." : "Open Settings from the Desktop Voice menu bar icon."
            transcript = ""
            timing = ""
            wordTask?.cancel(); wordTask = nil
            word = nil
        }
        showOverlay()
    }

    func dismissWidget() {
        if isBusy { cancel(showStatus: false) }
        systemAudio.stop()
        overlay?.orderOut(nil)
    }

    private func showOverlay() {
        if overlay == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 244, height: 172),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: VoiceWidget(model: self, speech: speech))
            if !panel.setFrameUsingName("DesktopVoiceWidget", force: true), let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 122, y: screen.visibleFrame.minY + 36))
            }
            panel.setFrameAutosaveName("DesktopVoiceWidget")
            overlay = panel
        }
        systemAudio.start()
        overlay?.orderFrontRegardless()
    }

    func shutdown() {
        cancel(showStatus: false)
        keyTask?.cancel()
        systemAudio.stop()
        wake.suspend()
        hotKey.unregister()
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        if let commandObserver { DistributedNotificationCenter.default().removeObserver(commandObserver) }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var plannerKey = ""
    @State private var command = ""
    @State private var wakePhrase = UserDefaults.standard.string(forKey: WakeWord.phraseKey) ?? ""
    @State private var wakeStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Desktop Voice").font(.title2.bold())
                    Text("Say it. Your Mac acts.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Connect TypeSafe").font(.headline)
                HStack {
                    SecureField(model.hasKey ? "Key saved — enter a replacement" : "TypeSafe API key", text: $key)
                        .textFieldStyle(.roundedBorder).disabled(model.isLoadingKey)
                    Button("Save key") { model.saveKey(key); if model.hasKey { key = "" } }.disabled(key.isEmpty || model.isLoadingKey)
                }
                Text("The key stays in Keychain. Commands, app controls and available folder names are sent to TypeSafe.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    SecureField(model.hasPlannerKey ? "OpenRouter key saved — enter a replacement" : "OpenRouter API key (optional: plans multi-step commands)", text: $plannerKey)
                        .textFieldStyle(.roundedBorder).disabled(model.isLoadingKey)
                    Button("Save key") { model.savePlannerKey(plannerKey); if model.hasPlannerKey { plannerKey = "" } }.disabled(plannerKey.isEmpty || model.isLoadingKey)
                }
                Text("With an OpenRouter key, \(Planner.model) turns each spoken command into ordered steps and Jev chooses every on-screen action. Without it, Jev alone handles single commands. Only the spoken text and app names are sent to OpenRouter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("2. Allow access").font(.headline)
                HStack {
                    Button(model.accessibilityAllowed ? "Accessibility enabled" : "Enable Accessibility") { model.grantAccessibility() }
                    Button(model.speechAllowed ? "Speech enabled" : "Enable microphone & speech") { model.grantSpeech() }
                    Button { model.refreshPermissions() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh access status")
                }
                if !model.accessibilityAllowed {
                    HStack(alignment: .top) {
                        Text("Already enabled? Remove the old app entry in Accessibility, then add this copy.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Show app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    }
                }
                Text("Apple uses your Mac's speech language and may process audio online.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("3. Hold ⌃⌥Space and speak").font(.headline)
                Text("Release to act. Escape stops pending work.")
                Text("Try “Open Desktop”, “Open Brave, go to google.com and type in hello”, or “Open Codex and type this: hello”.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done — use voice widget") { model.showVoiceWidget() }.disabled(!model.setupComplete)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Hands-free wake phrase").font(.headline)
                HStack {
                    Toggle("Listen for", isOn: Binding(get: { model.wake.isEnabled }, set: { model.wake.setEnabled($0); model.objectWillChange.send() }))
                    TextField(WakeWord.defaultPhrase, text: $wakePhrase).textFieldStyle(.roundedBorder)
                        .onSubmit { model.wake.setPhrase(wakePhrase) }
                    Button("Set") { model.wake.setPhrase(wakePhrase) }
                }
                Text("Say the phrase, then the command; it runs when you stop speaking. The microphone stays open while this is on, and the listening runs on this Mac only. \(wakeStatus)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onReceive(model.wake.$status) { wakeStatus = $0 }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Or type a command").font(.headline)
                Text("Target: \(model.targetName)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Open Finder", text: $command).textFieldStyle(.roundedBorder)
                        .onSubmit { model.runTyped(command) }
                    Button("Run") { model.runTyped(command) }.disabled(model.isBusy || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.headline).font(.subheadline.weight(.semibold))
                Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.timing.isEmpty { Text(model.timing).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .padding(28)
        .frame(width: 540)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
}

private struct VoiceWidget: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var field = PixelField(count: 720, bounds: CGSize(width: 216, height: 78))

    private var message: String {
        if speech.isListening { return model.transcript.isEmpty ? "Listening…" : model.transcript }
        return model.headline == "Command stopped" ? model.detail : model.headline
    }

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if reduceMotion {
                    Text(model.word ?? "")
                        .font(.system(size: 34, weight: .heavy)).foregroundStyle(.white)
                        .minimumScaleFactor(0.3).lineLimit(1)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                        Canvas { context, size in
                            let music = model.systemAudio.levels
                            if model.word == nil && !speech.isListening && music.isPlaying {
                                field.equalise(music.bands, at: timeline.date.timeIntervalSinceReferenceDate)
                            } else {
                                field.spell(model.word)
                            }
                            field.step(to: timeline.date.timeIntervalSinceReferenceDate, level: speech.isListening ? speech.audioLevel : 0)
                            field.draw(in: &context)
                        }
                    }
                }
            }
            .frame(width: 216, height: 78)
            .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .lineLimit(model.headline == "Command stopped" || model.headline.hasPrefix("Which one") ? 3 : 2)
                .multilineTextAlignment(.center).help(message)
            if !speech.isListening && !model.transcript.isEmpty {
                Text(model.transcript).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2).multilineTextAlignment(.center).help(model.transcript)
            }
            Text("Hold ⌃⌥Space to speak")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .frame(width: 244, height: 172)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                Button { model.showSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 24, height: 24)
                }.accessibilityLabel("Settings and commands").help("Settings and commands")
                Button { model.dismissWidget() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
                }.accessibilityLabel("Close widget and cancel pending work").help("Close widget and cancel pending work")
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
            .padding(8)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .onHover { isHovering = $0 }
        .preferredColorScheme(.dark)
    }
}

/// White pixels that drift while idle and assemble into the current word's letter shapes.
@MainActor
private final class PixelField {
    private struct Pixel {
        var x: Double, y: Double
        var tx: Double?, ty: Double?
        var ta: Double = 1
        let seed: Double
    }
    private struct Target { let x: Double, y: Double, alpha: Double }
    private var pixels: [Pixel]
    private let bounds: CGSize
    private var word: String?
    private var equalising = false
    private var peaks: [Double] = []
    private var peakTime: Double?
    private var lastTime: Double?

    init(count: Int, bounds: CGSize) {
        self.bounds = bounds
        pixels = (0..<count).map { _ in
            Pixel(x: Double.random(in: 0...bounds.width), y: Double.random(in: 0...bounds.height), seed: Double.random(in: 0...1))
        }
    }

    func spell(_ newWord: String?) {
        guard newWord != word || equalising else { return }
        word = newWord
        equalising = false
        var targets: [CGPoint] = []
        if let newWord, !newWord.isEmpty {
            var step = 3.0
            repeat {
                targets = Self.rasterise(newWord, in: bounds, step: step)
                step += 1
            } while targets.count > pixels.count && step < 8
        }
        assign(targets.map { Target(x: $0.x, y: $0.y, alpha: 1) })
    }

    /// Bars of bricks rising from a baseline, peak-hold marks above and a faded reflection below.
    /// Every pixel owns a fixed brick slot, so bricks only fade in and out instead of flying between bars.
    private static let barRows = 16, reflectionRows = 5
    private var slotsPerBar: Int { Self.barRows + 1 + Self.reflectionRows }

    func equalise(_ bands: [Float], at time: Double) {
        equalising = true
        word = nil
        let pitch = bounds.width / Double(bands.count)
        let baseline = bounds.height * 0.66
        let brick = (baseline - 2) / Double(Self.barRows)
        if peaks.count != bands.count { peaks = bands.map(Double.init) }
        let dt = min(0.1, max(0, time - (peakTime ?? time)))
        peakTime = time
        var levels: [Int] = []
        var peakRows: [Int] = []
        for (index, band) in bands.enumerated() {
            let level = Double(band)
            // Peak marks hold, then fall slowly, like the detached segments in a 2000s player.
            peaks[index] = level >= peaks[index] ? level : max(level, peaks[index] - dt * 0.4)
            levels.append(Int(level * Double(Self.barRows) + 0.5))
            peakRows.append(Int(peaks[index] * Double(Self.barRows) + 0.5))
        }
        for index in pixels.indices {
            let bar = index % bands.count
            let slot = index / bands.count
            guard slot < slotsPerBar else { pixels[index].tx = nil; pixels[index].ty = nil; pixels[index].ta = 0; continue }
            let x = pitch * (Double(bar) + 0.5)
            pixels[index].tx = x
            if slot < Self.barRows {
                pixels[index].ty = baseline - brick * (Double(slot) + 0.5)
                pixels[index].ta = slot < max(levels[bar], 1) ? 1 : 0
            } else if slot == Self.barRows {
                let row = peakRows[bar]
                pixels[index].ty = baseline - brick * (Double(row) + 0.5)
                pixels[index].ta = row > levels[bar] + 1 ? 0.9 : 0
            } else {
                let row = slot - Self.barRows - 1
                pixels[index].ty = baseline + brick * (Double(row) + 0.5)
                pixels[index].ta = row < levels[bar] ? 0.3 * (1 - Double(row) / Double(Self.reflectionRows)) : 0
            }
        }
    }

    private func assign(_ unsorted: [Target]) {
        var targets = unsorted
        // Pair pixels with targets left to right so the shapes sweep together instead of crossing.
        targets.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        let order = pixels.indices.sorted { pixels[$0].x == pixels[$1].x ? pixels[$0].y < pixels[$1].y : pixels[$0].x < pixels[$1].x }
        for (rank, index) in order.enumerated() {
            if rank < targets.count {
                pixels[index].tx = targets[rank].x
                pixels[index].ty = targets[rank].y
                pixels[index].ta = targets[rank].alpha
            } else {
                pixels[index].tx = nil
                pixels[index].ty = nil
                pixels[index].ta = 1
            }
        }
    }

    func step(to time: Double, level: Double) {
        let dt = min(0.05, max(0, time - (lastTime ?? time)))
        lastTime = time
        let approach = 1 - exp(-dt * 11)
        let jitter = level * 1.4
        for index in pixels.indices {
            var pixel = pixels[index]
            if let tx = pixel.tx, let ty = pixel.ty {
                pixel.x += (tx - pixel.x) * approach + sin(time * 21 + pixel.seed * 40) * jitter
                pixel.y += (ty - pixel.y) * approach + cos(time * 17 + pixel.seed * 30) * jitter
            } else {
                let speed = 7 + pixel.seed * 8 + level * 40
                let angle = pixel.seed * .pi * 2 + sin(time * (0.25 + pixel.seed * 0.5) + pixel.seed * 12) * 1.6
                pixel.x += cos(angle) * speed * dt
                pixel.y += sin(angle) * speed * dt
                if pixel.x < -4 { pixel.x += bounds.width + 8 } else if pixel.x > bounds.width + 4 { pixel.x -= bounds.width + 8 }
                if pixel.y < -4 { pixel.y += bounds.height + 8 } else if pixel.y > bounds.height + 4 { pixel.y -= bounds.height + 8 }
            }
            pixels[index] = pixel
        }
    }

    func draw(in context: inout GraphicsContext) {
        for pixel in pixels {
            let assembled = pixel.tx != nil
            let opacity = assembled ? pixel.ta : 0.3 + 0.25 * (0.5 + 0.5 * sin(pixel.seed * 50 + pixel.x * 0.05))
            if equalising {
                // Green bricks, brighter towards the top of each bar. Spare pixels stay hidden in this mode.
                guard assembled, opacity > 0 else { continue }
                let height = max(0, min(1, 1 - pixel.y / (bounds.height * 0.66)))
                let brickWidth = bounds.width / Double(SystemAudioMonitor.bandCount) - 2
                context.fill(Path(CGRect(x: pixel.x - brickWidth / 2, y: pixel.y - 1.1, width: brickWidth, height: 2.2)),
                             with: .color(Color(hue: 0.36 - 0.06 * height, saturation: 0.85, brightness: 0.55 + 0.45 * height).opacity(opacity)))
            } else {
                context.fill(Path(CGRect(x: pixel.x - 1.3, y: pixel.y - 1.3, width: 2.6, height: 2.6)), with: .color(.white.opacity(opacity)))
            }
        }
    }

    private static func rasterise(_ word: String, in bounds: CGSize, step: Double) -> [CGPoint] {
        let width = Int(bounds.width), height = Int(bounds.height)
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(origin: .zero, size: bounds))
        var pointSize = 44.0
        var text = NSAttributedString(string: word)
        repeat {
            text = NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: pointSize, weight: .heavy), .foregroundColor: NSColor.white])
            pointSize -= 2
        } while text.size().width > bounds.width - 6 && pointSize > 10
        let textSize = text.size()
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2))
        NSGraphicsContext.current = previous
        guard let data = bitmap.data else { return [] }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        var points: [CGPoint] = []
        var y = step / 2
        while y < bounds.height {
            var x = step / 2
            while x < bounds.width {
                // Bitmap rows run top to bottom, matching the canvas.
                if buffer[Int(y) * width + Int(x)] > 110 { points.append(CGPoint(x: x, y: y)) }
                x += step
            }
            y += step
        }
        return points
    }
}
