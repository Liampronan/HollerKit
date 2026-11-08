import Foundation

#if canImport(AVFoundation) && canImport(Speech) && os(iOS)
import AVFoundation
import Speech
#endif

public enum SpeechNoteCaptureError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case authorizationDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case audioSessionFailed(String)
    case recognitionFailed(String)
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech capture is unavailable on this platform."
        case .authorizationDenied:
            return "Speech recognition and microphone permissions are required."
        case .recognizerUnavailable:
            return "Speech recognition is unavailable for the current locale."
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is unavailable for the current locale."
        case .audioSessionFailed(let detail):
            return "Audio session setup failed: \(detail)"
        case .recognitionFailed(let detail):
            return "Speech recognition failed: \(detail)"
        case .noTranscript:
            return "No speech was detected. Please try speaking again."
        }
    }

    /// Formats any `Error` with its underlying `NSError` domain, code, failure reason, and underlying error
    /// so generic `"The operation couldn't be completed."` system errors remain actionable in QA reports.
    public static func describeError(_ error: Error) -> String {
        if let captureError = error as? SpeechNoteCaptureError,
           let description = captureError.errorDescription {
            return description
        }
        if let transcriberError = error as? SpeechTranscriberError,
           let description = transcriberError.errorDescription {
            return description
        }

        let nsError = error as NSError
        var parts: [String] = []
        let localized = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty {
            parts.append(localized)
        }
        if let reason = nsError.localizedFailureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty,
           !localized.contains(reason) {
            parts.append(reason)
        }

        let domainTag = "\(nsError.domain) code \(nsError.code)"
        if !localized.contains(nsError.domain) || !localized.contains(String(nsError.code)) {
            parts.append("[\(domainTag)]")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            let underlyingDesc = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !underlyingDesc.isEmpty, underlyingDesc != localized {
                parts.append("(underlying: \(underlyingDesc) [\(underlying.domain) code \(underlying.code)])")
            } else {
                parts.append("(underlying: \(underlying.domain) code \(underlying.code))")
            }
        }

        return parts.isEmpty ? "[\(domainTag)]" : parts.joined(separator: " ")
    }
}

final class LiveRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String = ""
    private var confidence: Double?
    private var isFinal: Bool = false
    private var errorDescription: String?

    func recordResult(text: String, confidence: Double?, isFinal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            self.text = text
            self.confidence = confidence
        }
        if isFinal {
            self.isFinal = true
        }
    }

    func recordError(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if self.errorDescription == nil {
            self.errorDescription = SpeechNoteCaptureError.describeError(error)
        }
    }

    func snapshot() -> (text: String, confidence: Double?, isFinal: Bool, errorDescription: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (text, confidence, isFinal, errorDescription)
    }
}

@MainActor
public final class SpeechNoteCapture: ObservableObject {
    @Published public private(set) var isCapturing = false
    @Published public private(set) var transcriptText = ""

    #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    #endif
    private var liveState = LiveRecognitionState()
    private var options = SpeechTranscriberOptions()
    private var startedAt: Date?
    private var confidence: Double?
    private var resolvedEngine: HollerKitTranscript.Engine = .appleNetwork

    public init() {}

    public func start(options: SpeechTranscriberOptions = SpeechTranscriberOptions()) async throws {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        cleanupCaptureState()

        let speechStatus = await SpeechTranscriber.requestAuthorization()
        guard speechStatus == .authorized else { throw SpeechNoteCaptureError.authorizationDenied }

        let audioSession = AVAudioSession.sharedInstance()
        let microphoneAllowed = await requestMicrophonePermission(audioSession: audioSession)
        guard microphoneAllowed else { throw SpeechNoteCaptureError.authorizationDenied }

        let locale = Locale(identifier: options.localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw SpeechNoteCaptureError.recognizerUnavailable
        }

        if options.requireOnDeviceRecognition, !recognizer.supportsOnDeviceRecognition {
            throw SpeechNoteCaptureError.onDeviceRecognitionUnavailable
        }

        do {
            try Self.configureAudioSession(audioSession)
        } catch {
            throw SpeechNoteCaptureError.audioSessionFailed(SpeechNoteCaptureError.describeError(error))
        }

        let state = LiveRecognitionState()
        self.liveState = state

        do {
            let engine = AVAudioEngine()
            self.audioEngine = engine

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = options.requireOnDeviceRecognition

            let inputNode = engine.inputNode
            inputNode.removeTap(onBus: 0)
            let outputFormat = inputNode.outputFormat(forBus: 0)
            let tapFormat: AVAudioFormat? = (outputFormat.sampleRate > 0 && outputFormat.channelCount > 0)
                ? outputFormat
                : nil
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
                request.append(buffer)
            }

            self.options = options
            self.resolvedEngine = options.requireOnDeviceRecognition ? .appleOnDevice : .appleNetwork
            self.transcriptText = ""
            self.confidence = nil
            self.startedAt = Date()
            self.recognitionRequest = request
            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                    let confidenceValues = result.bestTranscription.segments.map(\.confidence).filter { $0 > 0 }
                    let confidence = confidenceValues.isEmpty
                        ? nil
                        : Double(confidenceValues.reduce(0, +) / Float(confidenceValues.count))
                    state.recordResult(text: text, confidence: confidence, isFinal: result.isFinal)

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.transcriptText = text
                            self.confidence = confidence
                        }
                    }
                }
                if let error {
                    state.recordError(error)
                }
            }

            engine.prepare()
            try engine.start()
            isCapturing = true
        } catch {
            cleanupCaptureState()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechNoteCaptureError.recognitionFailed(SpeechNoteCaptureError.describeError(error))
        }
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }

    public func stopAsync() async throws -> HollerKitTranscript {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        stopAudioInput()

        // Allow a brief flush window after endAudio() so SFSpeechRecognizer can deliver final buffers.
        for _ in 0..<16 {
            let current = liveState.snapshot()
            let hasTranscript = !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if current.isFinal || (hasTranscript && current.errorDescription != nil) {
                break
            }
            if !hasTranscript && current.errorDescription != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return try finalizeStop()
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }

    public func stop() throws -> HollerKitTranscript {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        stopAudioInput()
        return try finalizeStop()
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }

    #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
    private static func configureAudioSession(_ audioSession: AVAudioSession) throws {
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        } catch {
            do {
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]
                )
            } catch {
                try audioSession.setCategory(.record, mode: .default)
            }
        }
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func stopAudioInput() {
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        isCapturing = false
    }

    private func finalizeStop() throws -> HollerKitTranscript {
        let snapshot = liveState.snapshot()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        isCapturing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let rawText = !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? snapshot.text
            : transcriptText
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedConfidence = snapshot.confidence ?? confidence
        let duration = startedAt.map { Date().timeIntervalSince($0) }
        startedAt = nil

        if !text.isEmpty {
            transcriptText = text
            confidence = resolvedConfidence
            return HollerKitTranscript(
                text: text,
                locale: options.localeIdentifier,
                engine: resolvedEngine,
                confidence: resolvedConfidence,
                durationSeconds: duration
            )
        }

        if let errorDescription = snapshot.errorDescription {
            throw SpeechNoteCaptureError.recognitionFailed(errorDescription)
        }
        throw SpeechNoteCaptureError.noTranscript
    }

    private func requestMicrophonePermission(audioSession: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            } else {
                audioSession.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
    }

    private func cleanupCaptureState() {
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        isCapturing = false
        startedAt = nil
    }
    #endif
}
