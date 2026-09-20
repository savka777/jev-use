import AVFoundation
import AppKit
import Combine
import Foundation
import Speech
import os

/// Hands-free entry: listens for a wake phrase, then hands the sentence after it to the same path as a typed command.
/// Recognition is forced on-device, so the open microphone never streams to Apple. Nothing is kept unless the phrase is heard.
@MainActor
final class WakeWord: ObservableObject {
    static let enabledKey = "WakeWordEnabled"
    static let phraseKey = "WakePhrase"
    static let defaultPhrase = "hey computer"

    @Published var isListening = false
    @Published var isArmed = false
    @Published var status = "Off" { didSet { if status != oldValue { log.notice("\(self.status, privacy: .public)") } } }
    var onArmed: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onCommand: ((String) -> Void)?
    var onDisarmed: (() -> Void)?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    /// Comma-separated alternatives are allowed: "hey computer, okay computer".
    var phrase: String {
        let saved = UserDefaults.standard.string(forKey: Self.phraseKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? Self.defaultPhrase : saved
    }

    private let log = Logger(subsystem: "local.jev-use", category: "wake")
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioGate: OSAllocatedUnfairLock<Bool>?
    private var tapInstalled = false
    private var generation = UUID()
    private var suspended = false
    private var pattern: NSRegularExpression?
    private var armedLocation: Int?
    /// The command as last seen with the wake phrase still in the transcript; Apple sometimes restarts the transcript after a pause.
    private var lockedCommand = ""
    private var command = ""
    private var timer: Task<Void, Never>?
    private var recycle: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?

    /// Seconds of quiet after the last recognised word before the command runs.
    private let endSilence = 1.4
    /// Seconds to wait for a command after the wake phrase alone.
    private let armedTimeout = 6.0
    /// An idle transcript keeps growing with room noise, so the recognition is renewed when nothing is armed.
    private let recycleSeconds = 60.0

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop(); status = "Off" }
    }

    func setPhrase(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.phraseKey)
        if isEnabled { stop(); start() }
    }

    /// The push-to-talk path and a running command own the microphone and the screen; the wake listener steps aside for both.
    func suspend() {
        suspended = true
        stop()
    }

    func resume() {
        suspended = false
        start()
    }

    func start() {
        guard isEnabled, !suspended, !isListening else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            status = "Needs microphone and speech access."
            return
        }
        guard let recognizer, recognizer.isAvailable else { status = "Apple speech recognition is unavailable."; return }
        guard recognizer.supportsOnDeviceRecognition else {
            status = "On-device recognition is unavailable for \(recognizer.locale.identifier). The wake word stays off rather than stream the microphone to Apple."
            return
        }
        guard AVCaptureDevice.default(for: .audio) != nil else { status = "No microphone is available."; return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            status = "The microphone has no usable audio format."
            return
        }

        let alternatives = phrase.split(separator: ",").map { alternative in
            alternative.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s\\p{P}]+")
        }.filter { !$0.isEmpty }
        pattern = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}])", options: [.caseInsensitive])

        generation = UUID()
        let current = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = phrase.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.request = request
        let gate = OSAllocatedUnfairLock(initialState: true)
        audioGate = gate
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            gate.withLock { acceptingAudio in
                if acceptingAudio { request.append(buffer) }
            }
        }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                if let result { self.hear(result.bestTranscription.formattedString) }
                guard self.generation == current else { return }
                if error != nil || result?.isFinal == true {
                    // Silence and the end of a recognition both land here. A spoken command still runs; otherwise listen again.
                    if self.isArmed && !self.command.isEmpty { self.deliver() } else { self.restart(after: 0.5) }
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            status = error.localizedDescription
            return
        }
        if configObserver == nil {
            // A new input device invalidates the tap's format.
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart(after: 0.5) }
            }
        }
        isListening = true
        status = "Listening on this Mac for “\(phrase)”."
        recycle = Task { [weak self, recycleSeconds] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(recycleSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled, self.generation == current else { return }
                if !self.isArmed { self.restart(after: 0); return }
            }
        }
    }

    func stop() {
        generation = UUID()
        timer?.cancel(); timer = nil
        recycle?.cancel(); recycle = nil
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let request = self.request
        audioGate?.withLock { acceptingAudio in
            if acceptingAudio {
                acceptingAudio = false
                request?.endAudio()
            }
        }
        audioGate = nil
        task?.cancel()
        task = nil
        self.request = nil
        isListening = false
        if isArmed {
            isArmed = false
            onDisarmed?()
        }
        armedLocation = nil
        lockedCommand = ""
        command = ""
    }

    private func restart(after seconds: Double) {
        stop()
        let current = generation
        Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard let self, self.generation == current else { return }
            self.start()
        }
    }

    private func hear(_ text: String) {
        let whole = NSRange(text.startIndex..., in: text)
        if let match = pattern?.matches(in: text, range: whole).last, let end = Range(match.range, in: text)?.upperBound {
            if armedLocation != match.range.location {
                // Partial results revise earlier words, so a moved phrase is the same wake, not a second one.
                if !isArmed {
                    isArmed = true
                    NSSound(named: "Tink")?.play()
                    log.notice("armed")
                    onArmed?()
                }
                armedLocation = match.range.location
            }
            lockedCommand = Self.clean(String(text[end...]))
            command = lockedCommand
        } else if isArmed {
            command = Self.clean(lockedCommand.isEmpty ? text : lockedCommand + " " + text)
        } else {
            return
        }
        onPartial?(command)
        let wait = command.isEmpty ? armedTimeout : endSilence
        let current = generation
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == current, self.isArmed else { return }
            if self.command.isEmpty { self.log.notice("armed, no command"); self.restart(after: 0) } else { self.deliver() }
        }
    }

    private func deliver() {
        let text = command
        log.notice("command: \(text, privacy: .public)")
        isArmed = false
        stop()
        onCommand?(text)
        // A command that could not start leaves the app idle, so nothing else would bring the listener back.
        if !suspended { start() }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?-–—")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
