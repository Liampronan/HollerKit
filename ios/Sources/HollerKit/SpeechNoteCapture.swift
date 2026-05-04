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
        let microphoneAllowed = await requestMicrophonePermission(audioSession: audioSession)
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

        do {
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
        } catch {
            cleanupCaptureState()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = startedAt.map { Date().timeIntervalSince($0) }
        startedAt = nil
        guard !text.isEmpty else { throw SpeechNoteCaptureError.noTranscript }

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

    #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
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
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isCapturing = false
        startedAt = nil
    }
    #endif
}
