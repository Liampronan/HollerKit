import SwiftUI
import UniformTypeIdentifiers

#if canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#endif

@MainActor
public struct BugReportSheet: View {
    private let configuration: HollerKitConfiguration?
    private let breadcrumbs: BreadcrumbStore
    private let outboxStore: OutboxStore
    private let invocationAttachments: [HollerKitAttachment]
    private let presentationId: UUID
    private let externalDraft: BugReportDraft?
    private let questState = HollerKit.quests
    @State private var draft: BugReportDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    private var speechCapture: SpeechCaptureController {
        draft.speechCapture
    }

    var pasteAttachmentRow: ClipboardPasteAttachmentRow {
        ClipboardPasteAttachmentRow(
            hasClipboardImage: draft.hasClipboardImage,
            isSubmitting: draft.isSubmitting,
            isLoadingAttachments: draft.isLoadingAttachments,
            canAddMoreImages: draft.canAddMoreImages,
            onPaste: {
                Task { @MainActor in
                    #if canImport(UIKit)
                    _ = await draft.pasteFromClipboard()
                    #endif
                    refreshClipboardImageAvailability()
                }
            }
        )
    }

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
        self.externalDraft = draft
        let resolvedDraft = draft ?? BugReportDraft(
            configuration: configuration,
            invocationAttachments: invocationAttachments
        )
        self._draft = State(initialValue: resolvedDraft)
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    if configuration?.quests != nil || !questState.quests.isEmpty {
                        Section {
                            Button {
                                draft.cancelCapture()
                                HollerKit.requestQuestsAfterBugReportDismiss()
                                dismiss()
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

                    if !isAudioOnly {
                        Section("Attachments (\(draft.images.count))") {
                            if !draft.images.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(draft.images) { image in
                                            ImageAttachmentThumbnail(
                                                image: image,
                                                isDisabled: draft.isSubmitting,
                                                onTap: image.isVideo ? nil : {
                                                    draft.selectedImage = image
                                                },
                                                onRemove: {
                                                    draft.removeImage(id: image.id)
                                                }
                                            )
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }

                            #if canImport(PhotosUI) && canImport(UIKit)
                            PhotosPicker(
                                selection: $selectedPhotoItems,
                                maxSelectionCount: max(1, draft.remainingImageSlots),
                                matching: draft.pickerFilter
                            ) {
                                HStack(spacing: 8) {
                                    Label(
                                        draft.isLoadingAttachments
                                            ? "Adding Attachment..."
                                            : (draft.canAddMoreVideos ? "Add Photo or Video" : "Add Photo"),
                                        systemImage: "photo.badge.plus"
                                    )
                                    if draft.isLoadingAttachments {
                                        Spacer()
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                            }
                            .disabled(draft.isSubmitting || draft.isLoadingAttachments || !draft.canAddMoreImages)
                            .accessibilityIdentifier("HollerKitAddPhotoButton")
                            #endif

                            #if canImport(UIKit)
                            pasteAttachmentRow
                            #endif

                            if let statusMessage = draft.attachmentStatusMessage {
                                Text(statusMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("HollerKitAttachmentStatusText")
                            }
                        }
                    }

                    if effectiveAudioConfiguration.isEnabled {
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
                                .disabled(!canSubmit)
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
                        flow: .bugReport,
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        draft.cancelCapture()
                        finishAndDismiss()
                    }
                    .disabled(draft.isSubmitting)
                    .accessibilityIdentifier("HollerKitToolbarCloseButton")
                }
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
            refreshClipboardImageAvailability()
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
            if let externalDraft {
                draft = externalDraft
            }
            draft.resetForAnotherReport(
                configuration: configuration,
                invocationAttachments: invocationAttachments
            )
            refreshClipboardImageAvailability()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshClipboardImageAvailability()
            }
        }
        #if canImport(PhotosUI) && canImport(UIKit)
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            selectedPhotoItems = []
            Task { @MainActor in
                await loadSelectedPhotoItems(newItems)
            }
        }
        #endif
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshClipboardImageAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshClipboardImageAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshClipboardImageAvailability()
        }
        #endif
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

    private var effectiveAudioConfiguration: HollerKitAudioConfiguration {
        configuration?.effectiveAudioConfiguration ?? .off
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
        guard effectiveAudioConfiguration.isEnabled else { return }
        await speechCapture.toggle(configuration: effectiveAudioConfiguration)
    }

    /// Retries voice dictation after an error.
    @MainActor
    private func retrySpeechCapture() async {
        guard effectiveAudioConfiguration.isEnabled else { return }
        await speechCapture.retry(configuration: effectiveAudioConfiguration)
    }

    /// Updates `draft.hasClipboardImage` from the system pasteboard without reading clipboard item payloads until tapped.
    @MainActor
    func refreshClipboardImageAvailability() {
        _ = draft.refreshClipboardImageAvailability()
    }

    #if canImport(PhotosUI) && canImport(UIKit)
    /// Loads and attaches photos and videos selected from the system `PhotosPicker`.
    @MainActor
    private func loadSelectedPhotoItems(_ items: [PhotosPickerItem]) async {
        let generation = draft.photoLoadGeneration
        draft.isLoadingAttachments = true
        defer {
            if draft.photoLoadGeneration == generation {
                draft.isLoadingAttachments = false
            }
        }

        var failedCount = 0
        for item in items {
            guard draft.photoLoadGeneration == generation,
                  !draft.isSubmitting,
                  draft.submissionOutcome == nil else {
                return
            }
            guard draft.canAddMoreImages else {
                draft.attachmentStatusMessage = "You can attach up to \(BugReportDraft.maxAttachments) attachments per report."
                break
            }

            let isMovieItem = item.supportedContentTypes.contains { type in
                type.conforms(to: .movie) || type.conforms(to: .video)
            }

            do {
                if isMovieItem {
                    guard draft.canAddMoreVideos else {
                        draft.attachmentStatusMessage = "You can attach up to \(BugReportDraft.maxVideoAttachments) videos per report."
                        failedCount += 1
                        continue
                    }
                    if let pickedMovie = try await item.loadTransferable(type: PickedMovieTransferable.self) {
                        defer {
                            try? FileManager.default.removeItem(at: pickedMovie.fileURL)
                        }
                        guard draft.photoLoadGeneration == generation,
                              !draft.isSubmitting,
                              draft.submissionOutcome == nil else {
                            return
                        }
                        let added = await draft.addVideo(from: pickedMovie.fileURL)
                        guard draft.photoLoadGeneration == generation,
                              !draft.isSubmitting,
                              draft.submissionOutcome == nil else {
                            return
                        }
                        if !added {
                            failedCount += 1
                        }
                    } else {
                        failedCount += 1
                    }
                } else if let data = try await item.loadTransferable(type: Data.self) {
                    guard draft.photoLoadGeneration == generation,
                          !draft.isSubmitting,
                          draft.submissionOutcome == nil else {
                        return
                    }
                    let added = await draft.addImageDataOffMainActor(data)
                    guard draft.photoLoadGeneration == generation,
                          !draft.isSubmitting,
                          draft.submissionOutcome == nil else {
                        return
                    }
                    if !added {
                        failedCount += 1
                    }
                } else {
                    failedCount += 1
                }
            } catch {
                failedCount += 1
            }
        }

        if draft.photoLoadGeneration == generation && failedCount > 0 && draft.attachmentStatusMessage == nil {
            draft.attachmentStatusMessage = failedCount == 1
                ? "Could not load the selected attachment."
                : "Could not load \(failedCount) selected attachments."
        }
    }
    #endif
}
