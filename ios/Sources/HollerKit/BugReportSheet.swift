import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Progress stages displayed while a bug report or quest run is being submitted.
enum SubmissionProgressStage: Equatable, Sendable {
    case preparing
    case uploadingAttachments(count: Int)
    case sending

    /// Human-readable headline for the current submission stage.
    var title: String {
        switch self {
        case .preparing:
            return "Preparing feedback..."
        case .uploadingAttachments(let count):
            return count == 1 ? "Uploading 1 attachment..." : "Uploading \(count) attachments..."
        case .sending:
            return "Sending to server..."
        }
    }
}

/// Provides tactile feedback for report and quest submission outcomes on iOS.
@MainActor
enum SubmissionHaptics {
    /// Fires a notification haptic matching the submission outcome.
    static func notify(for outcome: OutboxSubmissionOutcome) {
        #if canImport(UIKit) && os(iOS)
        let generator = UINotificationFeedbackGenerator()
        switch outcome {
        case .sent:
            generator.notificationOccurred(.success)
        case .queued:
            generator.notificationOccurred(.warning)
        }
        #endif
    }

    /// Fires an error notification haptic when submission fails.
    static func notifyError() {
        #if canImport(UIKit) && os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

/// Holds the mutable form state and submission lifecycle for a bug report presentation.
@MainActor
final class BugReportDraft: ObservableObject {
    let id = UUID()
    @Published var comment = ""
    @Published var images: [BugReportImage] = []
    @Published var selectedImage: BugReportImage?
    @Published var isSubmitting = false
    @Published var submissionStage: SubmissionProgressStage?
    @Published var submissionError: String?
    @Published var submissionOutcome: OutboxSubmissionOutcome?

    let speechCapture = SpeechCaptureController()
    var autoDismissDelaySeconds: TimeInterval = 1.2

    private var didLoadInitialImages = false
    private var autoDismissTask: Task<Void, Never>?

    /// Creates a new bug report draft optionally preloaded with initial images.
    init(
        configuration: HollerKitConfiguration? = nil,
        invocationAttachments: [HollerKitAttachment] = []
    ) {
        if configuration != nil || !invocationAttachments.isEmpty {
            loadInitialImagesIfNeeded(
                configuration: configuration,
                invocationAttachments: invocationAttachments
            )
        }
    }

    /// Loads initial attachments once for the current draft when not in audio-only mode.
    func loadInitialImagesIfNeeded(
        configuration: HollerKitConfiguration?,
        invocationAttachments: [HollerKitAttachment]
    ) {
        guard !didLoadInitialImages else { return }
        didLoadInitialImages = true
        guard !Self.isAudioOnly(configuration: configuration) else { return }
        #if canImport(UIKit)
        let configuredImages = configuration?.initialImages() ?? []
        images = (invocationAttachments + configuredImages).compactMap(BugReportImage.init(attachment:))
        #endif
    }

    /// Returns `true` when the draft has content and is ready to submit.
    func canSubmit(configuration: HollerKitConfiguration?) -> Bool {
        guard let configuration,
              configuration.isEnabled(),
              !isSubmitting,
              !speechCapture.isStopping,
              submissionOutcome == nil else {
            return false
        }
        if Self.isAudioOnly(configuration: configuration) {
            return speechCapture.transcript != nil
        }

        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !images.isEmpty
            || speechCapture.transcript != nil
    }

    /// Clears all draft inputs after a report has been submitted or queued so stale text never remains in the editor.
    func clearInputsAfterSubmission() {
        speechCapture.reset()
        comment = ""
        images = []
        selectedImage = nil
    }

    /// Resets the draft to a clean state so the tester can file another report immediately.
    func resetForAnotherReport(
        configuration: HollerKitConfiguration?,
        invocationAttachments: [HollerKitAttachment] = []
    ) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        speechCapture.reset()
        comment = ""
        images = []
        selectedImage = nil
        isSubmitting = false
        submissionStage = nil
        submissionError = nil
        submissionOutcome = nil
        didLoadInitialImages = false
        loadInitialImagesIfNeeded(
            configuration: configuration,
            invocationAttachments: invocationAttachments
        )
    }

    /// Cancels any active voice dictation and pending auto-dismiss task.
    func cancelCapture() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        speechCapture.cancelCapture()
    }

    #if canImport(UIKit)
    /// Replaces an annotated attachment image in the draft.
    func replaceImage(id: UUID, with renderedImage: UIImage) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].image = renderedImage
    }
    #endif

    /// Submits the current draft or queues it in the local outbox, clearing inputs upon completion.
    func submit(
        configuration: HollerKitConfiguration?,
        breadcrumbs: BreadcrumbStore,
        outboxStore: OutboxStore,
        onDisabled: (() -> Void)? = nil,
        onAutoDismiss: (() -> Void)? = nil
    ) async {
        guard !isSubmitting else { return }
        guard let configuration else {
            submissionError = "HollerKit has not been configured."
            return
        }
        guard configuration.isEnabled() else {
            HollerKit.reconcileEnablement()
            onDisabled?()
            return
        }

        autoDismissTask?.cancel()
        autoDismissTask = nil
        submissionOutcome = nil
        submissionError = nil
        isSubmitting = true
        submissionStage = .preparing
        defer {
            isSubmitting = false
            submissionStage = nil
        }

        do {
            await speechCapture.finalizeIfCapturing()
            let audioOnly = Self.isAudioOnly(configuration: configuration)
            if !audioOnly {
                comment = speechCapture.consumeTranscriptForCommentMerge(into: comment)
            }

            let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedComment = trimmedComment.isEmpty ? nil : trimmedComment
            let attachmentsToUpload = audioOnly ? [] : imageAttachments()
            let transcriptToSubmit = speechCapture.transcript

            if !attachmentsToUpload.isEmpty {
                submissionStage = .uploadingAttachments(count: attachmentsToUpload.count)
                await Task.yield()
            } else {
                submissionStage = .sending
            }

            let payload = HollerKitReportPayload(
                inputMode: configuration.inputMode,
                comment: audioOnly ? nil : normalizedComment,
                transcript: transcriptToSubmit,
                metadata: MetadataCollector.collect(extra: configuration.metadata()),
                breadcrumbs: configuration.captureBreadcrumbs ? breadcrumbs.snapshot() : [],
                images: attachmentsToUpload
            )
            let (request, attachments) = payload.toFeedbackSubmission()
            submissionStage = .sending
            let client = APIClient(configuration: configuration)
            let outcome = try await outboxStore.submit(
                request: request,
                attachments: attachments,
                using: client
            )

            clearInputsAfterSubmission()
            submissionOutcome = outcome
            SubmissionHaptics.notify(for: outcome)

            if case .sent = outcome, autoDismissDelaySeconds > 0, let onAutoDismiss {
                let delayNanoseconds = UInt64(autoDismissDelaySeconds * 1_000_000_000)
                autoDismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    guard !Task.isCancelled, let self, self.submissionOutcome != nil else { return }
                    onAutoDismiss()
                }
            }
        } catch {
            submissionError = error.localizedDescription
            SubmissionHaptics.notifyError()
        }
    }

    /// Returns whether `configuration` is set to `.audioOnly`.
    static func isAudioOnly(configuration: HollerKitConfiguration?) -> Bool {
        guard let configuration else { return false }
        if case .audioOnly = configuration.inputMode { return true }
        return false
    }

    /// Converts draft `BugReportImage` items into PNG `HollerKitAttachment` payloads.
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
}

public struct BugReportSheet: View {
    private let configuration: HollerKitConfiguration?
    private let breadcrumbs: BreadcrumbStore
    private let outboxStore: OutboxStore
    private let invocationAttachments: [HollerKitAttachment]
    private let presentationId: UUID
    @ObservedObject private var questState = HollerKit.quests
    @ObservedObject private var draft: BugReportDraft
    @ObservedObject private var speechCapture: SpeechCaptureController
    @Environment(\.dismiss) private var dismiss

    init(
        configuration: HollerKitConfiguration?,
        breadcrumbs: BreadcrumbStore,
        outboxStore: OutboxStore? = nil,
        invocationAttachments: [HollerKitAttachment] = [],
        draft: BugReportDraft? = nil,
        presentationId: UUID = UUID()
    ) {
        self.configuration = configuration
        self.breadcrumbs = breadcrumbs
        self.outboxStore = outboxStore ?? OutboxStore(rootDirectoryURL: configuration?.outboxDirectoryURL)
        self.invocationAttachments = invocationAttachments
        self.presentationId = presentationId
        let resolvedDraft = draft ?? BugReportDraft(
            configuration: configuration,
            invocationAttachments: invocationAttachments
        )
        self.draft = resolvedDraft
        self.speechCapture = resolvedDraft.speechCapture
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    if configuration?.quests != nil || !questState.quests.isEmpty {
                        Section {
                            Button {
                                draft.cancelCapture()
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
                            .disabled(draft.isSubmitting)
                            .accessibilityIdentifier("HollerKitOpenQuestsRow")
                        }
                    }

                    if !isAudioOnly {
                        Section("What happened?") {
                            ZStack(alignment: .topLeading) {
                                if draft.comment.isEmpty {
                                    Text("Describe what went wrong or what felt off...")
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $draft.comment)
                                    .frame(minHeight: 140)
                                    .disabled(draft.isSubmitting)
                                    .accessibilityIdentifier("HollerKitBugReportCommentEditor")
                            }
                        }
                    }

                    if !isAudioOnly && !draft.images.isEmpty {
                        Section("Attachments (\(draft.images.count))") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(draft.images) { image in
                                        Button {
                                            draft.selectedImage = image
                                        } label: {
                                            ImageAttachmentThumbnail(image: image)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(draft.isSubmitting)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    if configuration?.audio.isEnabled == true {
                        Section("Voice Note") {
                            Button {
                                Task {
                                    await toggleSpeechCapture()
                                }
                            } label: {
                                Label(
                                    speechCapture.isCapturing ? "Stop Dictation" : "Dictate Bug",
                                    systemImage: speechCapture.isCapturing ? "stop.circle.fill" : "mic.fill"
                                )
                            }
                            .disabled(draft.isSubmitting || speechCapture.isStopping)

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
                                    .disabled(draft.isSubmitting || speechCapture.isCapturing || speechCapture.isStopping)
                                    .accessibilityIdentifier("HollerKitSpeechRetryButton")
                                }
                            }
                        }
                    }

                    if let submissionError = draft.submissionError {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("HollerKitSubmissionErrorText")

                                Button {
                                    Task {
                                        await submit()
                                    }
                                } label: {
                                    Label("Retry Submission", systemImage: "arrow.clockwise")
                                        .font(.footnote.weight(.semibold))
                                }
                                .disabled(draft.isSubmitting || speechCapture.isStopping)
                                .accessibilityIdentifier("HollerKitRetrySubmitButton")
                            }
                        }
                    }
                }
                .disabled(draft.isSubmitting || draft.submissionOutcome != nil)

                if draft.isSubmitting || draft.submissionOutcome != nil {
                    SubmissionFeedbackOverlayView(
                        isSubmitting: draft.isSubmitting,
                        stage: draft.submissionStage,
                        outcome: draft.submissionOutcome,
                        sentTitle: "Report Sent",
                        onDone: {
                            finishAndDismiss()
                        },
                        onSendAnother: {
                            draft.resetForAnotherReport(
                                configuration: configuration,
                                invocationAttachments: []
                            )
                        }
                    )
                }
            }
            .navigationTitle("Report a Bug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if draft.submissionOutcome != nil {
                        Button("Done") {
                            finishAndDismiss()
                        }
                        .accessibilityIdentifier("HollerKitToolbarDoneButton")
                    } else {
                        Button(draft.isSubmitting ? "Submitting..." : "Submit") {
                            Task {
                                await submit()
                            }
                        }
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("HollerKitBugReportSubmitButton")
                    }
                }
            }
        }
        .sheet(item: $draft.selectedImage) { image in
            #if canImport(UIKit)
            NavigationStack {
                AnnotationEditorScreen(image: image) { renderedImage in
                    draft.replaceImage(id: image.id, with: renderedImage)
                }
            }
            #else
            Text("Annotation is unavailable on this platform.")
            #endif
        }
        .onAppear {
            if draft.submissionOutcome != nil {
                draft.resetForAnotherReport(
                    configuration: configuration,
                    invocationAttachments: invocationAttachments
                )
            } else {
                draft.loadInitialImagesIfNeeded(
                    configuration: configuration,
                    invocationAttachments: invocationAttachments
                )
            }
        }
        .onChange(of: presentationId) { _, _ in
            draft.resetForAnotherReport(
                configuration: configuration,
                invocationAttachments: invocationAttachments
            )
        }
        .onChange(of: speechCapture.transcript) { _, _ in
            guard !isAudioOnly else { return }
            draft.comment = speechCapture.consumeTranscriptForCommentMerge(into: draft.comment)
        }
        .onDisappear {
            draft.cancelCapture()
            if draft.submissionOutcome != nil {
                draft.resetForAnotherReport(
                    configuration: configuration,
                    invocationAttachments: []
                )
            }
        }
        .accessibilityIdentifier("HollerKitBugReportSheet")
    }

    private var canSubmit: Bool {
        draft.canSubmit(configuration: configuration)
    }

    private var isAudioOnly: Bool {
        BugReportDraft.isAudioOnly(configuration: configuration)
    }

    /// Resets the draft and dismisses the bug report sheet.
    @MainActor
    private func finishAndDismiss() {
        draft.resetForAnotherReport(
            configuration: configuration,
            invocationAttachments: []
        )
        dismiss()
    }

    /// Submits the bug report or queues it in the local outbox.
    @MainActor
    private func submit() async {
        await draft.submit(
            configuration: configuration,
            breadcrumbs: breadcrumbs,
            outboxStore: outboxStore,
            onDisabled: {
                dismiss()
            },
            onAutoDismiss: {
                finishAndDismiss()
            }
        )
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

/// Full-sheet progress and post-submission confirmation overlay shared by bug reports and quest runs.
struct SubmissionFeedbackOverlayView: View {
    var isSubmitting: Bool
    var stage: SubmissionProgressStage?
    var outcome: OutboxSubmissionOutcome?
    var sentTitle: String
    var onDone: () -> Void
    var onSendAnother: (() -> Void)?

    @State private var animateBadge = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.bottom, 4)

                    Text((stage ?? .sending).title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("HollerKitSubmissionProgressText")

                    Text("Please wait a moment while your feedback is processed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let outcome {
                    switch outcome {
                    case .sent(let response):
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.green)
                            .scaleEffect(animateBadge ? 1.0 : 0.72)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: animateBadge)

                        Text(sentTitle)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("HollerKitSubmissionSentTitle")

                        Text("Submitted (\(response.feedback.id.prefix(8)))")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("HollerKitSubmissionReceiptText")

                    case .queued(_, let reason):
                        let isAuthFailure = Self.isAuthenticationFailureReason(reason)
                        Image(systemName: isAuthFailure ? "person.badge.key.fill" : "tray.and.arrow.up.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.orange)
                            .scaleEffect(animateBadge ? 1.0 : 0.72)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: animateBadge)

                        Text(
                            isAuthFailure
                                ? "Saved to outbox — sign in to finish sending"
                                : "Saved to outbox — will send when online"
                        )
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("HollerKitSubmissionQueuedTitle")

                        Text(
                            isAuthFailure
                                ? "Your feedback is stored on this device and will send automatically once you sign in."
                                : "Your feedback is stored on this device and will send automatically when your connection returns."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                        if let reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    HStack(spacing: 12) {
                        if let onSendAnother {
                            Button("Send Another") {
                                onSendAnother()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .accessibilityIdentifier("HollerKitSendAnotherReportButton")
                        }

                        Button("Done") {
                            onDone()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .accessibilityIdentifier("HollerKitSubmissionDoneButton")
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(24)
            .onAppear {
                animateBadge = true
            }
            .onChange(of: outcome) { _, newValue in
                animateBadge = (newValue != nil)
            }
        }
        .transition(.opacity)
        .accessibilityIdentifier("HollerKitSubmissionConfirmationOverlay")
    }

    /// Returns `true` when `reason` indicates a missing or rejected authentication token.
    static func isAuthenticationFailureReason(_ reason: String?) -> Bool {
        guard let lower = reason?.lowercased() else { return false }
        return lower.contains("authentication token")
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("401")
            || lower.contains("403")
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
