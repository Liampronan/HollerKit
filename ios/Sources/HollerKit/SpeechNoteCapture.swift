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
        case .noTranscript:
            return "No transcript was captured."
        }
    }
}

@MainActor
public final class SpeechNoteCapture: ObservableObject {
    @Published public private(set) var isCapturing = false
    @Published public private(set) var transcriptText = ""

    #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    #endif
    private var options = SpeechTranscriberOptions()
    private var startedAt: Date?
    private var confidence: Double?

    public init() {}

    public func start(options: SpeechTranscriberOptions = SpeechTranscriberOptions()) async throws {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        let speechStatus = await SpeechTranscriber.requestAuthorization()
        guard speechStatus == .authorized else { throw SpeechNoteCaptureError.authorizationDenied }

        let audioSession = AVAudioSession.sharedInstance()
        let microphoneAllowed = await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard microphoneAllowed else { throw SpeechNoteCaptureError.authorizationDenied }

        let locale = Locale(identifier: options.localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechNoteCaptureError.recognizerUnavailable
        }

        if options.requireOnDeviceRecognition, !recognizer.supportsOnDeviceRecognition {
            throw SpeechNoteCaptureError.onDeviceRecognitionUnavailable
        }

        try audioSession.setCategory(.record, mode: .spokenAudio)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = options.requireOnDeviceRecognition

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        self.options = options
        transcriptText = ""
        confidence = nil
        startedAt = Date()
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let confidenceValues = result.bestTranscription.segments.map(\.confidence).filter { $0 > 0 }
            let confidence = confidenceValues.isEmpty
                ? nil
                : Double(confidenceValues.reduce(0, +) / Float(confidenceValues.count))

            Task { @MainActor [weak self] in
                self?.transcriptText = text
                self?.confidence = confidence
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }

    public func stop() throws -> HollerKitTranscript {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isCapturing = false

        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechNoteCaptureError.noTranscript }

        let duration = startedAt.map { Date().timeIntervalSince($0) }
        startedAt = nil
        return HollerKitTranscript(
            text: text,
            locale: options.localeIdentifier,
            engine: options.requireOnDeviceRecognition ? .appleOnDevice : .appleNetwork,
            confidence: confidence,
            durationSeconds: duration
        )
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }
}
