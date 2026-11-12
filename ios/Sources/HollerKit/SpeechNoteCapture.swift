import Foundation
import Observation

#if canImport(AVFoundation) && canImport(Speech) && os(iOS)
import AVFoundation
import Speech
#endif

/// Errors thrown during live microphone speech note capture.
public enum SpeechNoteCaptureError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case authorizationDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case audioSessionFailed(String)
    case recognitionFailed(String)
    case noTranscript

    /// A human-readable description of the speech note capture error.
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

/// Thread-safe accumulator for live speech recognition callbacks across audio/XPC queues.
final class LiveRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String = ""
    private var confidence: Double?
    private var isFinal: Bool = false
    private var errorDescription: String?
    private var localeIdentifier: String
    private var engine: HollerKitTranscript.Engine
    private var startedAt: Date

    /// Creates a new recognition state container for a single capture session.
    init(
        localeIdentifier: String = Locale.current.identifier,
        engine: HollerKitTranscript.Engine = .appleNetwork,
        startedAt: Date = Date()
    ) {
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.startedAt = startedAt
    }

    /// Updates the session metadata associated with this recognition state.
    func configureSessionMetadata(
        localeIdentifier: String,
        engine: HollerKitTranscript.Engine,
        startedAt: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.startedAt = startedAt
    }

    /// Returns the session metadata captured when this recognition session started.
    func sessionMetadata() -> (localeIdentifier: String, engine: HollerKitTranscript.Engine, startedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        return (localeIdentifier, engine, startedAt)
    }

    /// Records a partial or final transcription result.
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

    /// Records the first recognition error encountered during the session.
    func recordError(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if self.errorDescription == nil {
            self.errorDescription = SpeechNoteCaptureError.describeError(error)
        }
    }

    /// Returns a point-in-time snapshot of the recognition state.
    func snapshot() -> (text: String, confidence: Double?, isFinal: Bool, errorDescription: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (text, confidence, isFinal, errorDescription)
    }
}

/// Captures live microphone audio and transcribes it using Apple's Speech framework.
@Observable
@MainActor
public final class SpeechNoteCapture {
    public private(set) var isCapturing = false
    public private(set) var isStopping = false
    public private(set) var transcriptText = ""
    public private(set) var lastError: String?

    #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
    @ObservationIgnored
    private var audioEngine: AVAudioEngine?
    @ObservationIgnored
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored
    private var recognitionTask: SFSpeechRecognitionTask?
    #endif
    @ObservationIgnored
    private var liveState = LiveRecognitionState()
    @ObservationIgnored
    private var options = SpeechTranscriberOptions()
    @ObservationIgnored
    private var resolvedLocaleIdentifier: String = Locale.current.identifier
    @ObservationIgnored
    private var startedAt: Date?
    @ObservationIgnored
    private var confidence: Double?
    @ObservationIgnored
    private var resolvedEngine: HollerKitTranscript.Engine = .appleNetwork
    @ObservationIgnored
    private var startGeneration: UInt64 = 0

    @ObservationIgnored
    var speechAuthorizationProvider: (() async -> SpeechTranscriberAuthorizationStatus)?
    @ObservationIgnored
    var microphonePermissionProvider: (() async -> Bool)?
    @ObservationIgnored
    var onStateChange: (@MainActor () -> Void)?

    /// Creates a new live speech note capture coordinator.
    public init() {}

    /// Returns `true` when `candidateLocale` shares the same primary language code as `requestedLocale`.
    nonisolated static func matchesRequestedLanguage(_ candidateLocale: Locale, requestedLocale: Locale) -> Bool {
        let requestedLanguage = primaryLanguageCode(for: requestedLocale)
        let candidateLanguage = primaryLanguageCode(for: candidateLocale)
        guard let requestedLanguage, !requestedLanguage.isEmpty,
              let candidateLanguage, !candidateLanguage.isEmpty else {
            return candidateLocale.identifier.caseInsensitiveCompare(requestedLocale.identifier) == .orderedSame
        }
        return requestedLanguage == candidateLanguage
    }

    /// Extracts the normalized lowercase ISO language code from `locale`.
    private nonisolated static func primaryLanguageCode(for locale: Locale) -> String? {
        if let code = locale.language.languageCode?.identifier.lowercased(), !code.isEmpty {
            return code
        }
        return locale.identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { String($0).lowercased() }
    }

    /// Starts live microphone capture and speech recognition with the provided options.
    public func start(options: SpeechTranscriberOptions = SpeechTranscriberOptions()) async throws {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        let hadActiveSession = isCapturing || isStopping || audioEngine != nil || recognitionTask != nil
        cleanupCaptureState(deactivateSession: hadActiveSession)
        let currentGeneration = startGeneration
        lastError = nil

        let speechStatus: SpeechTranscriberAuthorizationStatus
        if let speechAuthorizationProvider {
            speechStatus = await speechAuthorizationProvider()
        } else {
            speechStatus = await SpeechTranscriber.requestAuthorization()
        }
        guard !Task.isCancelled, startGeneration == currentGeneration else {
            throw CancellationError()
        }
        guard speechStatus == .authorized else { throw SpeechNoteCaptureError.authorizationDenied }

        let audioSession = AVAudioSession.sharedInstance()
        let microphoneAllowed: Bool
        if let microphonePermissionProvider {
            microphoneAllowed = await microphonePermissionProvider()
        } else {
            microphoneAllowed = await requestMicrophonePermission(audioSession: audioSession)
        }
        guard !Task.isCancelled, startGeneration == currentGeneration else {
            throw CancellationError()
        }
        guard microphoneAllowed else { throw SpeechNoteCaptureError.authorizationDenied }

        let locale = Locale(identifier: options.localeIdentifier)
        let recognizer = try Self.selectRecognizer(
            for: locale,
            requireOnDeviceRecognition: options.requireOnDeviceRecognition
        )

        do {
            try Self.configureAudioSession(audioSession)
        } catch {
            throw SpeechNoteCaptureError.audioSessionFailed(SpeechNoteCaptureError.describeError(error))
        }

        let sessionLocaleIdentifier = recognizer.locale.identifier
        let sessionEngine: HollerKitTranscript.Engine = options.requireOnDeviceRecognition ? .appleOnDevice : .appleNetwork
        let sessionStartedAt = Date()
        let state = LiveRecognitionState(
            localeIdentifier: sessionLocaleIdentifier,
            engine: sessionEngine,
            startedAt: sessionStartedAt
        )
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
            self.resolvedLocaleIdentifier = sessionLocaleIdentifier
            self.resolvedEngine = sessionEngine
            self.transcriptText = ""
            self.confidence = nil
            self.startedAt = sessionStartedAt
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
                        guard let self, self.liveState === state, self.isCapturing else { return }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.transcriptText = text
                            self.confidence = confidence
                            self.onStateChange?()
                        }
                    }
                }
                if let error {
                    state.recordError(error)
                    Task { @MainActor [weak self] in
                        self?.handleRecognitionCallbackError(for: state)
                    }
                }
            }

            engine.prepare()
            try engine.start()
            isCapturing = true
        } catch {
            cleanupCaptureState(deactivateSession: true)
            throw SpeechNoteCaptureError.recognitionFailed(SpeechNoteCaptureError.describeError(error))
        }
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }

    /// Stops audio input, waits for speech recognition to produce a final result or error, and returns the transcript.
    public func stopAsync(timeout: TimeInterval = 5.0) async throws -> HollerKitTranscript {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        let stateAtStop = liveState
        stopAudioInput()

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while liveState === stateAtStop && !Task.isCancelled {
            let current = stateAtStop.snapshot()
            if current.isFinal || current.errorDescription != nil {
                break
            }
            if Date() >= deadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return try finalizeStop(expectedState: stateAtStop, requireFinalResult: true)
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }

    /// Synchronously stops capture and returns any transcript received so far.
    public func stop() throws -> HollerKitTranscript {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        let stateAtStop = liveState
        stopAudioInput()
        return try finalizeStop(expectedState: stateAtStop, requireFinalResult: false)
        #else
        throw SpeechNoteCaptureError.unavailable
        #endif
    }

    /// Cancels any pending or active speech capture session and deactivates the audio session if needed.
    public func cancel() {
        #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
        let hadActiveSession = isCapturing || isStopping || audioEngine != nil || recognitionTask != nil
        cleanupCaptureState(deactivateSession: hadActiveSession)
        #else
        startGeneration &+= 1
        isStopping = false
        isCapturing = false
        #endif
    }

    /// Internal test hook to prime a simulated recognition session for deterministic `stopAsync()` testing.
    func startForTesting(
        state: LiveRecognitionState,
        options: SpeechTranscriberOptions = SpeechTranscriberOptions()
    ) {
        startGeneration &+= 1
        let sessionEngine: HollerKitTranscript.Engine = options.requireOnDeviceRecognition ? .appleOnDevice : .appleNetwork
        let sessionStartedAt = Date()
        state.configureSessionMetadata(
            localeIdentifier: options.localeIdentifier,
            engine: sessionEngine,
            startedAt: sessionStartedAt
        )
        self.liveState = state
        self.options = options
        self.resolvedLocaleIdentifier = options.localeIdentifier
        self.resolvedEngine = sessionEngine
        self.transcriptText = ""
        self.confidence = nil
        self.lastError = nil
        self.startedAt = sessionStartedAt
        self.isStopping = false
        self.isCapturing = true
    }

    /// Internal test hook to simulate a live partial transcript update and notify observers.
    func updatePartialTranscriptForTesting(_ text: String) {
        self.isCapturing = true
        self.transcriptText = text
        self.onStateChange?()
    }

    #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
    /// Handles an unexpected recognition failure during active capture by stopping audio while preserving any partial text.
    func handleRecognitionCallbackError(for state: LiveRecognitionState) {
        guard self.liveState === state, self.isCapturing, !self.isStopping else { return }
        let snapshot = state.snapshot()
        guard let errorDescription = snapshot.errorDescription else { return }
        let preservedText = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? self.transcriptText
            : snapshot.text
        let preservedConfidence = snapshot.confidence ?? self.confidence
        self.cleanupCaptureState(deactivateSession: true)
        if !preservedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.transcriptText = preservedText
            self.confidence = preservedConfidence
        }
        self.lastError = SpeechNoteCaptureError.recognitionFailed(errorDescription).errorDescription
        self.onStateChange?()
    }

    /// Selects an available `SFSpeechRecognizer` for `locale`, falling back to the default recognizer only if its language matches.
    static func selectRecognizer(
        for locale: Locale,
        requireOnDeviceRecognition: Bool
    ) throws -> SFSpeechRecognizer {
        var candidates: [SFSpeechRecognizer] = []
        if let requested = SFSpeechRecognizer(locale: locale),
           matchesRequestedLanguage(requested.locale, requestedLocale: locale) {
            candidates.append(requested)
        }
        if let fallback = SFSpeechRecognizer(),
           matchesRequestedLanguage(fallback.locale, requestedLocale: locale),
           !candidates.contains(where: { $0.locale.identifier == fallback.locale.identifier }) {
            candidates.append(fallback)
        }

        let available = candidates.filter(\.isAvailable)
        guard !available.isEmpty else {
            throw SpeechNoteCaptureError.recognizerUnavailable
        }

        if requireOnDeviceRecognition {
            guard let onDevice = available.first(where: \.supportsOnDeviceRecognition) else {
                throw SpeechNoteCaptureError.onDeviceRecognitionUnavailable
            }
            return onDevice
        }
        return available[0]
    }

    /// Configures and activates the shared `AVAudioSession` for speech capture with safe category fallbacks.
    private static func configureAudioSession(_ audioSession: AVAudioSession) throws {
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        } catch {
            do {
                #if compiler(>=6.2)
                let bluetoothOption: AVAudioSession.CategoryOptions = .allowBluetoothHFP
                #else
                let bluetoothOption: AVAudioSession.CategoryOptions = .allowBluetooth
                #endif
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, bluetoothOption, .duckOthers]
                )
            } catch {
                try audioSession.setCategory(.record, mode: .default)
            }
        }
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Stops the audio engine and signals the end of audio buffers while keeping capture in the stopping state.
    private func stopAudioInput() {
        isStopping = true
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
    }

    /// Cancels the recognition task, deactivates the audio session, and constructs the final `HollerKitTranscript`.
    private func finalizeStop(
        expectedState: LiveRecognitionState,
        requireFinalResult: Bool = false
    ) throws -> HollerKitTranscript {
        let snapshot = expectedState.snapshot()
        let metadata = expectedState.sessionMetadata()
        let isCurrentSession = (liveState === expectedState)
        if isCurrentSession {
            recognitionTask?.cancel()
            recognitionRequest = nil
            recognitionTask = nil
            audioEngine = nil
            isStopping = false
            isCapturing = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        let fallbackText = isCurrentSession ? transcriptText : ""
        let rawText = !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? snapshot.text
            : fallbackText
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedConfidence = snapshot.confidence ?? (isCurrentSession ? confidence : nil)
        let duration = Date().timeIntervalSince(metadata.startedAt)
        if isCurrentSession {
            startedAt = nil
            if !text.isEmpty {
                transcriptText = text
                confidence = resolvedConfidence
            }
        }

        if requireFinalResult && !snapshot.isFinal {
            if let errorDescription = snapshot.errorDescription {
                throw SpeechNoteCaptureError.recognitionFailed(errorDescription)
            }
            throw SpeechNoteCaptureError.recognitionFailed(
                "Speech recognition did not finish before the stop timeout expired."
            )
        }

        if !text.isEmpty {
            return HollerKitTranscript(
                text: text,
                locale: metadata.localeIdentifier,
                engine: metadata.engine,
                confidence: resolvedConfidence,
                durationSeconds: duration
            )
        }

        if let errorDescription = snapshot.errorDescription {
            throw SpeechNoteCaptureError.recognitionFailed(errorDescription)
        }
        throw SpeechNoteCaptureError.noTranscript
    }

    /// Requests microphone recording permission from the user.
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

    /// Stops any active audio engine or recognition task and resets capture state.
    private func cleanupCaptureState(deactivateSession: Bool) {
        startGeneration &+= 1
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        isStopping = false
        isCapturing = false
        transcriptText = ""
        confidence = nil
        startedAt = nil
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    #endif
}
