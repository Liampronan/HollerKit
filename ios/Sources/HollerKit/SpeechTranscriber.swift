import Foundation

#if canImport(Speech)
import Speech
#endif

public enum SpeechTranscriberAuthorizationStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unavailable
}

public enum SpeechTranscriberError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case authorizationDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech transcription is unavailable on this platform."
        case .authorizationDenied:
            return "Speech recognition permission is required."
        case .recognizerUnavailable:
            return "Speech recognition is unavailable for the current locale."
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is unavailable for the current locale."
        case .transcriptionFailed(let detail):
            return "Speech transcription failed: \(detail)"
        }
    }
}

public struct SpeechTranscriberOptions: Sendable, Equatable {
    public var localeIdentifier: String
    public var requireOnDeviceRecognition: Bool
    public var reportPartialResults: Bool

    public init(
        locale: Locale = .current,
        requireOnDeviceRecognition: Bool = false,
        reportPartialResults: Bool = false
    ) {
        self.localeIdentifier = locale.identifier
        self.requireOnDeviceRecognition = requireOnDeviceRecognition
        self.reportPartialResults = reportPartialResults
    }
}

public actor SpeechTranscriber {
    private let options: SpeechTranscriberOptions

    public init(options: SpeechTranscriberOptions = SpeechTranscriberOptions()) {
        self.options = options
    }

    public static func requestAuthorization() async -> SpeechTranscriberAuthorizationStatus {
        #if canImport(Speech)
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: SpeechTranscriberAuthorizationStatus(status))
            }
        }
        #else
        .unavailable
        #endif
    }

    public func transcribeAudioFile(at url: URL) async throws -> HollerKitTranscript {
        #if canImport(Speech)
        let authorizationStatus = await Self.requestAuthorization()
        guard authorizationStatus == .authorized else {
            throw SpeechTranscriberError.authorizationDenied
        }

        let locale = Locale(identifier: options.localeIdentifier)
        var candidates: [SFSpeechRecognizer] = []
        if let requested = SFSpeechRecognizer(locale: locale) {
            candidates.append(requested)
        }
        if let fallback = SFSpeechRecognizer(),
           !candidates.contains(where: { $0.locale.identifier == fallback.locale.identifier }) {
            candidates.append(fallback)
        }
        let available = candidates.filter(\.isAvailable)
        guard !available.isEmpty else {
            throw SpeechTranscriberError.recognizerUnavailable
        }

        let recognizer: SFSpeechRecognizer
        if options.requireOnDeviceRecognition {
            guard let onDevice = available.first(where: \.supportsOnDeviceRecognition) else {
                throw SpeechTranscriberError.onDeviceRecognitionUnavailable
            }
            recognizer = onDevice
        } else {
            recognizer = available[0]
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = options.reportPartialResults
        request.requiresOnDeviceRecognition = options.requireOnDeviceRecognition
        let options = self.options
        let resolvedLocaleIdentifier = recognizer.locale.identifier

        return try await withCheckedThrowingContinuation { continuation in
            let state = RecognitionState()
            state.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    state.resumeOnce {
                        continuation.resume(throwing: SpeechTranscriberError.transcriptionFailed(
                            SpeechNoteCaptureError.describeError(error)
                        ))
                    }
                    return
                }

                guard let result, result.isFinal else { return }
                state.resumeOnce {
                    continuation.resume(returning: Self.transcript(
                        from: result,
                        localeIdentifier: resolvedLocaleIdentifier,
                        requireOnDeviceRecognition: options.requireOnDeviceRecognition
                    ))
                }
            }
        }
        #else
        throw SpeechTranscriberError.unavailable
        #endif
    }

    #if canImport(Speech)
    private static func transcript(
        from result: SFSpeechRecognitionResult,
        localeIdentifier: String,
        requireOnDeviceRecognition: Bool
    ) -> HollerKitTranscript {
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let confidenceValues = segments.map(\.confidence).filter { $0 > 0 }
        let confidence = confidenceValues.isEmpty
            ? nil
            : Double(confidenceValues.reduce(0, +) / Float(confidenceValues.count))
        let duration = segments.last.map { Double($0.timestamp + $0.duration) }

        return HollerKitTranscript(
            text: transcription.formattedString,
            locale: localeIdentifier,
            engine: requireOnDeviceRecognition ? .appleOnDevice : .appleNetwork,
            confidence: confidence,
            durationSeconds: duration
        )
    }
    #endif
}

#if canImport(Speech)
private extension SpeechTranscriberAuthorizationStatus {
    init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .unavailable
        }
    }
}

private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    var task: SFSpeechRecognitionTask?

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        task?.cancel()
        body()
    }
}
#endif
