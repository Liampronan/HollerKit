import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct BugReportSheet: View {
    private let configuration: HollerKitConfiguration?
    private let breadcrumbs: BreadcrumbStore
    private let outboxStore: OutboxStore
    private let invocationAttachments: [HollerKitAttachment]
    @ObservedObject private var questState = HollerKit.quests
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var images: [BugReportImage] = []
    @State private var selectedImage: BugReportImage?
    @StateObject private var speechCapture = SpeechCaptureController()
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @State private var submissionOutcome: OutboxSubmissionOutcome?

    init(
        configuration: HollerKitConfiguration?,
        breadcrumbs: BreadcrumbStore,
        outboxStore: OutboxStore? = nil,
        invocationAttachments: [HollerKitAttachment] = []
    ) {
        self.configuration = configuration
        self.breadcrumbs = breadcrumbs
        self.outboxStore = outboxStore ?? OutboxStore(rootDirectoryURL: configuration?.outboxDirectoryURL)
        self.invocationAttachments = invocationAttachments
    }

    public var body: some View {
        NavigationStack {
            Form {
                if configuration?.quests != nil || !questState.quests.isEmpty {
                    Section {
                        Button {
                            speechCapture.cancelCapture()
                            dismiss()
                            Task { @MainActor in
                                HollerKit.presentQuests()
                            }
                        } label: {
                            HStack {
                                Label("Quests (\(questState.pendingCount))", systemImage: "flag.checkered")
                                    .fontWeight(.medium)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("HollerKitOpenQuestsRow")
                    }
                }

                if !isAudioOnly {
                    Section {
                        TextEditor(text: $comment)
                            .frame(minHeight: 140)
                    }
                }

                if !isAudioOnly && !images.isEmpty {
                    Section("Images") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(images) { image in
                                    Button {
                                        selectedImage = image
                                    } label: {
                                        ImageAttachmentThumbnail(image: image)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if configuration?.audio.isEnabled == true {
                    Section("Audio") {
                        Button(speechCapture.isCapturing ? "Stop Dictation" : "Dictate Bug") {
                            Task {
                                await toggleSpeechCapture()
                            }
                        }
                        .disabled(isSubmitting || speechCapture.isStopping)

                        if let transcript = speechCapture.transcript {
                            Text(transcript.text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if !speechCapture.partialTranscript.isEmpty {
                            Text(speechCapture.partialTranscript)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage = speechCapture.errorMessage {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("HollerKitSpeechErrorText")

                                Button {
                                    Task {
                                        await retrySpeechCapture()
                                    }
                                } label: {
                                    Label("Retry Dictation", systemImage: "arrow.clockwise")
                                        .font(.footnote.weight(.semibold))
                                }
                                .disabled(isSubmitting || speechCapture.isCapturing || speechCapture.isStopping)
                                .accessibilityIdentifier("HollerKitSpeechRetryButton")
                            }
                        }
                    }
                }

                if let submissionOutcome {
                    Section("Status") {
                        switch submissionOutcome {
                        case .sent(let response):
                            Label("Submitted (\(response.feedback.id.prefix(8)))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .queued(_, let reason):
                            if Self.isAuthenticationFailureReason(reason) {
                                Label("Saved to outbox — sign in to finish sending", systemImage: "person.badge.key.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Label("Saved to outbox — will send when online", systemImage: "tray.and.arrow.up.fill")
                                    .foregroundStyle(.orange)
                            }
                            if let reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let submissionError {
                    Section {
                        Text(submissionError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Report a Bug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if submissionOutcome != nil {
                        Button("Done") {
                            dismiss()
                        }
                    } else {
                        Button(isSubmitting ? "Submitting..." : "Submit") {
                            Task {
                                await submit()
                            }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .sheet(item: $selectedImage) { image in
            #if canImport(UIKit)
            NavigationStack {
                AnnotationEditorScreen(image: image) { renderedImage in
                    replaceImage(id: image.id, with: renderedImage)
                }
            }
            #else
            Text("Annotation is unavailable on this platform.")
            #endif
        }
        .onAppear {
            guard images.isEmpty else { return }
            guard !isAudioOnly else { return }
            #if canImport(UIKit)
            let configuredImages = configuration?.initialImages() ?? []
            images = (invocationAttachments + configuredImages).compactMap(BugReportImage.init(attachment:))
            #endif
        }
        .onChange(of: speechCapture.transcript) { _, _ in
            guard !isAudioOnly else { return }
            comment = speechCapture.consumeTranscriptForCommentMerge(into: comment)
        }
        .onDisappear {
            speechCapture.cancelCapture()
        }
        .accessibilityIdentifier("HollerKitBugReportSheet")
    }

    #if canImport(UIKit)
    private func replaceImage(id: UUID, with renderedImage: UIImage) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].image = renderedImage
    }
    #endif

    private var canSubmit: Bool {
        guard let configuration,
              configuration.isEnabled(),
              !isSubmitting,
              !speechCapture.isStopping,
              submissionOutcome == nil else {
            return false
        }
        if isAudioOnly {
            return speechCapture.transcript != nil
        }

        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !images.isEmpty
            || speechCapture.transcript != nil
    }

    private var isAudioOnly: Bool {
        guard let configuration else { return false }
        if case .audioOnly = configuration.inputMode { return true }
        return false
    }

    private static func isAuthenticationFailureReason(_ reason: String?) -> Bool {
        guard let lower = reason?.lowercased() else { return false }
        return lower.contains("authentication token")
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("401")
            || lower.contains("403")
    }

    /// Submits the bug report or queues it in the local outbox.
    @MainActor
    private func submit() async {
        guard let configuration else {
            submissionError = "HollerKit has not been configured."
            return
        }
        guard configuration.isEnabled() else {
            HollerKit.reconcileEnablement()
            dismiss()
            return
        }

        isSubmitting = true
        submissionError = nil
        defer { isSubmitting = false }

        do {
            await speechCapture.finalizeIfCapturing()
            if !isAudioOnly {
                comment = speechCapture.consumeTranscriptForCommentMerge(into: comment)
            }
            let payload = HollerKitReportPayload(
                inputMode: configuration.inputMode,
                comment: isAudioOnly ? nil : normalizedComment,
                transcript: speechCapture.transcript,
                metadata: MetadataCollector.collect(extra: configuration.metadata()),
                breadcrumbs: configuration.captureBreadcrumbs ? breadcrumbs.snapshot() : [],
                images: isAudioOnly ? [] : imageAttachments()
            )
            let (request, attachments) = payload.toFeedbackSubmission()
            let client = APIClient(configuration: configuration)
            submissionOutcome = try await outboxStore.submit(
                request: request,
                attachments: attachments,
                using: client
            )
        } catch {
            submissionError = error.localizedDescription
        }
    }

    private var normalizedComment: String? {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func imageAttachments() -> [HollerKitAttachment] {
        #if canImport(UIKit)
        return images.enumerated().compactMap { index, image in
            guard let data = image.image.pngData() else { return nil }
            return HollerKitAttachment(
                filename: image.submissionFilename(index: index),
                mimeType: "image/png",
                data: data
            )
        }
        #else
        return []
        #endif
    }

    /// Toggles voice dictation for the bug report.
    @MainActor
    private func toggleSpeechCapture() async {
        guard let configuration else { return }
        await speechCapture.toggle(configuration: configuration.audio)
    }

    /// Retries voice dictation after an error.
    @MainActor
    private func retrySpeechCapture() async {
        guard let configuration else { return }
        await speechCapture.retry(configuration: configuration.audio)
    }
}

struct BugReportImage: Identifiable, Hashable {
    let id = UUID()
    var title: String

    #if canImport(UIKit)
    var image: UIImage

    init(title: String, image: UIImage) {
        self.title = title
        self.image = image
    }

    init?(attachment: HollerKitAttachment) {
        guard let image = UIImage(data: attachment.data) else { return nil }
        self.title = attachment.filename
        self.image = image
    }
    #endif

    static func == (lhs: BugReportImage, rhs: BugReportImage) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func submissionFilename(index: Int) -> String {
        let base = (title as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? "image-\(index + 1)" : base
        return "\(safeBase).png"
    }
}

/// Coordinates live voice dictation for bug report and quest result sheets.
@MainActor
final class SpeechCaptureController: ObservableObject {
    static let maxCommentCharacters = 20_000

    @Published var isCapturing = false
    @Published var isStopping = false
    @Published var transcript: HollerKitTranscript?
    @Published var errorMessage: String?
    @Published var partialTranscript = ""

    let capture = SpeechNoteCapture()
    private var autoStopTask: Task<Void, Never>?
    private var activeStopTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var consumedTranscriptForCommentMerge: HollerKitTranscript?

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
        autoStopTask?.cancel()
        autoStopTask = nil
        activeStopTask?.cancel()
        activeStopTask = nil
        capture.cancel()
        partialTranscript = ""
        isStopping = false
        isCapturing = false
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
            bindPartialTranscript()
            scheduleAutoStop(after: configuration.maxDuration)
        } catch is CancellationError {
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
        isStopping = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeStopTask = nil }
            do {
                let completedTranscript = try await self.capture.stopAsync()
                self.transcript = completedTranscript
                self.partialTranscript = ""
                self.isStopping = false
                self.isCapturing = false
            } catch is CancellationError {
                self.partialTranscript = ""
                self.isStopping = false
                self.isCapturing = false
            } catch {
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

    /// Polls partial transcription updates and mid-capture errors while recording is active.
    private func bindPartialTranscript() {
        Task { @MainActor [weak self] in
            while let self, self.capture.isCapturing || self.capture.lastError != nil {
                if let failure = self.capture.lastError, !self.capture.isCapturing {
                    self.autoStopTask?.cancel()
                    self.autoStopTask = nil
                    if !self.capture.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.partialTranscript = self.capture.transcriptText
                    } else {
                        self.partialTranscript = ""
                    }
                    self.isStopping = false
                    self.isCapturing = false
                    self.recordErrorMessage(failure)
                    break
                }
                self.partialTranscript = self.capture.transcriptText
                try? await Task.sleep(for: .milliseconds(250))
            }
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

struct ImageAttachmentThumbnail: View {
    var image: BugReportImage

    var body: some View {
        #if canImport(UIKit)
        VStack(alignment: .leading, spacing: 8) {
            Image(uiImage: image.image)
                .resizable()
                .scaledToFit()
                .frame(width: 136, height: 104)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }

            Text(image.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 136, alignment: .leading)
        }
        .accessibilityLabel("Attached image \(image.title)")
        #else
        EmptyView()
        #endif
    }
}
