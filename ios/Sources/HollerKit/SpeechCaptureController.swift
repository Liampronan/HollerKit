import Foundation
import Observation

/// Coordinates live voice dictation for bug report and quest result sheets.
@Observable
@MainActor
final class SpeechCaptureController {
    static let maxCommentCharacters = 20_000

    var isCapturing = false
    var isStopping = false
    var transcript: HollerKitTranscript?
    var errorMessage: String?
    var partialTranscript = ""

    let capture = SpeechNoteCapture()
    @ObservationIgnored
    private var autoStopTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeStopTask: Task<Void, Never>?
    @ObservationIgnored
    private var startGeneration: UInt64 = 0
    @ObservationIgnored
    private var stopGeneration: UInt64 = 0
    @ObservationIgnored
    private var consumedTranscriptForCommentMerge: HollerKitTranscript?

    init() {
        capture.onStateChange = { [weak self] in
            self?.handleCaptureStateChange()
        }
    }

    /// Merges `transcriptText` into `existingComment` while respecting the 20,000 UTF-16 unit server limit.
    static func mergeTranscript(_ transcriptText: String, into existingComment: String) -> String {
        let trimmedTranscript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return existingComment }
        let trimmedExisting = existingComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else {
            return trimmedTranscript.utf16.count <= maxCommentCharacters ? trimmedTranscript : existingComment
        }
        if trimmedExisting.hasSuffix(trimmedTranscript) {
            return existingComment
        }
        let combined = "\(trimmedExisting)\n\(trimmedTranscript)"
        guard combined.utf16.count <= maxCommentCharacters else {
            return existingComment
        }
        return combined
    }

    /// Merges the latest completed transcript into `existingComment` at most once so subsequent user edits are preserved.
    func consumeTranscriptForCommentMerge(into existingComment: String) -> String {
        guard let current = transcript, current != consumedTranscriptForCommentMerge else {
            return existingComment
        }
        consumedTranscriptForCommentMerge = current
        return Self.mergeTranscript(current.text, into: existingComment)
    }

    /// Toggles between starting and stopping live dictation.
    func toggle(configuration: HollerKitAudioConfiguration) async {
        guard !isStopping else { return }
        errorMessage = nil

        if isCapturing {
            await stop(configuration: configuration)
        } else {
            await start(configuration: configuration)
        }
    }

    /// Cancels any active session and starts a fresh dictation attempt.
    func retry(configuration: HollerKitAudioConfiguration) async {
        guard !isStopping else { return }
        cancelCapture()
        errorMessage = nil
        await start(configuration: configuration)
    }

    /// Finalizes an in-progress dictation session or awaits an in-flight stop prior to form submission.
    func finalizeIfCapturing() async {
        await performStop()
    }

    /// Cancels any pending or active dictation session immediately.
    func cancelCapture() {
        startGeneration &+= 1
        stopGeneration &+= 1
        autoStopTask?.cancel()
        autoStopTask = nil
        activeStopTask?.cancel()
        activeStopTask = nil
        capture.cancel()
        partialTranscript = ""
        isStopping = false
        isCapturing = false
    }

    /// Cancels any active session and clears all captured transcript and error state.
    func reset() {
        cancelCapture()
        transcript = nil
        consumedTranscriptForCommentMerge = nil
        errorMessage = nil
    }

    /// Starts a new dictation session with the given audio configuration.
    private func start(configuration: HollerKitAudioConfiguration) async {
        startGeneration &+= 1
        let generation = startGeneration
        do {
            transcript = nil
            consumedTranscriptForCommentMerge = nil
            partialTranscript = ""
            try await capture.start(options: SpeechTranscriberOptions(
                requireOnDeviceRecognition: configuration.requiresOnDeviceTranscription
            ))
            guard !Task.isCancelled, startGeneration == generation else {
                capture.cancel()
                return
            }
            isStopping = false
            isCapturing = true
            handleCaptureStateChange()
            scheduleAutoStop(after: configuration.maxDuration)
        } catch is CancellationError {
            guard startGeneration == generation else { return }
            isStopping = false
            isCapturing = false
        } catch {
            guard startGeneration == generation else { return }
            isStopping = false
            isCapturing = false
            recordError(error)
        }
    }

    /// Stops the active dictation session and stores the resulting transcript.
    private func stop(configuration: HollerKitAudioConfiguration) async {
        await performStop()
    }

    /// Stops the active dictation session or awaits an already-running stop operation.
    private func performStop() async {
        if let existingStopTask = activeStopTask {
            await existingStopTask.value
            return
        }
        guard isCapturing || isStopping || capture.isCapturing || capture.isStopping else { return }

        autoStopTask?.cancel()
        autoStopTask = nil
        errorMessage = nil
        isStopping = true

        stopGeneration &+= 1
        let capturedStartGeneration = startGeneration
        let capturedStopGeneration = stopGeneration

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.stopGeneration == capturedStopGeneration {
                    self.activeStopTask = nil
                }
            }
            do {
                let completedTranscript = try await self.capture.stopAsync()
                guard !Task.isCancelled,
                      self.startGeneration == capturedStartGeneration,
                      self.stopGeneration == capturedStopGeneration else {
                    return
                }
                self.transcript = completedTranscript
                self.partialTranscript = ""
                self.isStopping = false
                self.isCapturing = false
            } catch is CancellationError {
                guard self.startGeneration == capturedStartGeneration,
                      self.stopGeneration == capturedStopGeneration else {
                    return
                }
                self.partialTranscript = ""
                self.isStopping = false
                self.isCapturing = false
            } catch {
                guard !Task.isCancelled,
                      self.startGeneration == capturedStartGeneration,
                      self.stopGeneration == capturedStopGeneration else {
                    return
                }
                if !self.capture.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.partialTranscript = self.capture.transcriptText
                } else {
                    self.partialTranscript = ""
                }
                self.isStopping = false
                self.isCapturing = false
                self.recordError(error)
            }
        }
        activeStopTask = task
        await task.value
    }

    /// Schedules an automatic stop after `maxDuration` seconds.
    private func scheduleAutoStop(after maxDuration: TimeInterval) {
        autoStopTask?.cancel()
        guard maxDuration > 0 else { return }

        autoStopTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(maxDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.isCapturing, !self.isStopping else { return }
            await self.performStop()
        }
    }

    /// Synchronizes partial transcription updates and mid-capture errors reactively from `capture`.
    private func handleCaptureStateChange() {
        guard isCapturing || isStopping else { return }
        if let failure = capture.lastError, !capture.isCapturing {
            autoStopTask?.cancel()
            autoStopTask = nil
            if !capture.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                partialTranscript = capture.transcriptText
            } else {
                partialTranscript = ""
            }
            isStopping = false
            isCapturing = false
            recordErrorMessage(failure)
            return
        }
        if capture.isCapturing {
            partialTranscript = capture.transcriptText
        }
    }

    /// Formats `error`, assigns `errorMessage`, and records a diagnostic breadcrumb.
    private func recordError(_ error: Error) {
        recordErrorMessage(SpeechNoteCaptureError.describeError(error))
    }

    /// Assigns `described` to `errorMessage` and records a diagnostic breadcrumb.
    private func recordErrorMessage(_ described: String) {
        errorMessage = described
        HollerKit.breadcrumb(
            "Speech capture failed: \(described)",
            category: "speech_error",
            metadata: ["error": described]
        )
    }
}
