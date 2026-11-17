import SwiftUI

#if canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#endif

@MainActor
public struct QuestResultSheet: View {
    private let questState: HollerKitQuestState
    @State private var draft: QuestResultDraft
    @State private var capturedSession: ActiveQuestSession?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeAnnotationTarget: ActiveAnnotationTarget?
    #if canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    private static let selectableResults: [QuestResult] = [.pass, .fail, .unsure]
    /// High-contrast green fill used for checked icons so white checkmarks maintain >= 4.5:1 contrast in light and dark modes.
    private static let checkedStepColor = Color(red: 0.08, green: 0.50, blue: 0.24)

    /// Returns the active quest session or the last captured/submitted session snapshot so the sheet never flashes an empty state during confirmation or dismissal.
    var displayedSession: ActiveQuestSession? {
        questState.activeQuest ?? draft.submittedSessionSnapshot ?? capturedSession
    }

    /// Returns the images to display in the form, preserving the pre-submit snapshot while the confirmation overlay is visible so the form layout does not jump.
    var displayedImages: [BugReportImage] {
        draft.submissionOutcome != nil ? draft.submittedImagesSnapshot : draft.images
    }

    /// Returns the comment text displayed in the form, preserving the pre-submit snapshot while the confirmation overlay is visible.
    var displayedComment: String {
        draft.submissionOutcome != nil ? draft.submittedCommentSnapshot : draft.comment
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

    public init(questState: HollerKitQuestState = HollerKit.quests) {
        let defaultDraft = QuestResultDraft()
        self.questState = questState
        self._draft = State(initialValue: defaultDraft)
        self._capturedSession = State(initialValue: questState.activeQuest)
    }

    init(
        questState: HollerKitQuestState = HollerKit.quests,
        draft: QuestResultDraft
    ) {
        self.questState = questState
        self._draft = State(initialValue: draft)
        self._capturedSession = State(initialValue: questState.activeQuest)
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let session = displayedSession {
                    Section("Quest") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.quest.definition.title)
                                .font(.headline)
                            Text("Area: \(session.quest.definition.area) • v\(session.quest.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Outcome") {
                        ForEach(Self.selectableResults, id: \.self) { option in
                            Button {
                                draft.selectedResult = option
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: iconName(for: option))
                                        .symbolRenderingMode(.monochrome)
                                        .foregroundStyle(color(for: option))
                                        .frame(width: 20, height: 20, alignment: .center)
                                    Text(option.displayTitle)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if draft.selectedResult == option {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.white, color(for: option))
                                            .frame(width: 20, height: 20, alignment: .center)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(draft.isSubmitting)
                            .accessibilityValue(draft.selectedResult == option ? "selected" : "unselected")
                            .accessibilityIdentifier("HollerKitQuestResultOption_\(option.rawValue)")
                        }
                    }

                    if !session.quest.definition.steps.isEmpty {
                        let checkedCount = session.stepsChecked.filter { $0 }.count
                        let totalSteps = session.quest.definition.steps.count
                        Section {
                            ForEach(Array(session.quest.definition.steps.enumerated()), id: \.offset) { index, step in
                                let isChecked = session.stepsChecked.indices.contains(index) && session.stepsChecked[index]
                                Button {
                                    questState.toggleStep(at: index)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Group {
                                            if isChecked {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(Color.white, Self.checkedStepColor)
                                            } else {
                                                Image(systemName: "circle")
                                                    .symbolRenderingMode(.monochrome)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(width: 20, height: 18, alignment: .center)

                                        Text(step)
                                            .font(.subheadline)
                                            .foregroundStyle(isChecked ? .secondary : .primary)
                                            .strikethrough(isChecked)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(draft.isSubmitting)
                                .accessibilityValue(isChecked ? "checked" : "unchecked")
                                .accessibilityIdentifier("HollerKitQuestResultStep_\(index)")
                            }
                        } header: {
                            HStack {
                                Text("Steps (\(checkedCount)/\(totalSteps))")
                                    .accessibilityIdentifier("HollerKitQuestResultStepsHeader")
                                Spacer()
                                if checkedCount < totalSteps {
                                    Button("Check All") {
                                        questState.checkAllSteps()
                                    }
                                    .font(.caption.weight(.semibold))
                                    .textCase(nil)
                                    .disabled(draft.isSubmitting)
                                    .accessibilityIdentifier("HollerKitQuestResultCheckAllStepsButton")
                                }
                            }
                        } footer: {
                            if checkedCount == 0 {
                                Text("Tap completed steps to check them off before submitting.")
                                    .accessibilityIdentifier("HollerKitQuestUncheckedStepsHint")
                            }
                        }
                    }

                    Section("Note (Optional)") {
                        ZStack(alignment: .topLeading) {
                            if displayedComment.isEmpty {
                                Text("Add an optional note about this quest run...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(
                                text: Binding(
                                    get: { displayedComment },
                                    set: { newValue in
                                        if draft.submissionOutcome == nil {
                                            draft.comment = newValue
                                        }
                                    }
                                )
                            )
                            .frame(minHeight: 100)
                            .disabled(draft.isSubmitting)
                            .accessibilityIdentifier("HollerKitQuestResultCommentEditor")
                        }

                        if let audioConfig = HollerKit.currentConfiguration?.effectiveAudioConfiguration, audioConfig.isEnabled {
                            Button {
                                Task {
                                    await draft.speechCapture.toggle(configuration: audioConfig)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: draft.speechCapture.isCapturing ? "stop.circle.fill" : "mic.fill")
                                        .symbolRenderingMode(.monochrome)
                                    Text(draft.speechCapture.isCapturing ? "Stop Dictation" : "Dictate Note")
                                }
                            }
                            .disabled(draft.isSubmitting || draft.speechCapture.isStopping)

                            if let transcript = draft.speechCapture.transcript {
                                Text(transcript.text)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if !draft.speechCapture.partialTranscript.isEmpty {
                                Text(draft.speechCapture.partialTranscript)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            if let errorMessage = draft.speechCapture.errorMessage {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(errorMessage)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .accessibilityIdentifier("HollerKitSpeechErrorText")

                                    Button {
                                        Task {
                                            await draft.speechCapture.retry(configuration: audioConfig)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.clockwise")
                                                .symbolRenderingMode(.monochrome)
                                            Text("Retry Dictation")
                                        }
                                        .font(.footnote.weight(.semibold))
                                    }
                                    .disabled(draft.isSubmitting || draft.speechCapture.isCapturing || draft.speechCapture.isStopping)
                                    .accessibilityIdentifier("HollerKitSpeechRetryButton")
                                }
                            }
                        }
                    }

                    Section("Attachments (\(displayedImages.count))") {
                        if !displayedImages.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(displayedImages) { image in
                                        ImageAttachmentThumbnail(
                                            image: image,
                                            isDisabled: draft.isSubmitting || draft.submissionOutcome != nil,
                                            onTap: image.isVideo ? nil : {
                                                draft.selectedImage = image
                                                activeAnnotationTarget = .userImage(image)
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
                            matching: .images
                        ) {
                            HStack(spacing: 8) {
                                Label(
                                    draft.isLoadingAttachments ? "Adding Photo..." : "Add Photo",
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

                    if !session.marks.isEmpty {
                        Section("Captured Marks (\(session.marks.count))") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(session.marks) { mark in
                                        #if canImport(UIKit)
                                        if let uiImage = UIImage(data: mark.imageData) {
                                            Button {
                                                activeAnnotationTarget = .mark(AnnotatableMarkImage(
                                                    markId: mark.id,
                                                    title: "\(mark.label) (+\(Int(mark.offsetSeconds))s)",
                                                    image: uiImage
                                                ))
                                            } label: {
                                                ImageAttachmentThumbnail(
                                                    image: BugReportImage(
                                                        title: "\(mark.label) (+\(Int(mark.offsetSeconds))s)",
                                                        image: uiImage
                                                    )
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        #endif
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    if let submissionError = draft.submissionError {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .symbolRenderingMode(.monochrome)
                                    Text(submissionError)
                                }
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("HollerKitSubmissionErrorText")

                                Button {
                                    Task {
                                        await submit()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.clockwise")
                                            .symbolRenderingMode(.monochrome)
                                        Text("Retry Submission")
                                    }
                                    .font(.footnote.weight(.semibold))
                                }
                                .disabled(draft.isSubmitting || draft.isLoadingAttachments || draft.speechCapture.isStopping)
                                .accessibilityIdentifier("HollerKitRetrySubmitButton")
                            }
                        }
                    }
                } else {
                    Section {
                        Text("No active quest session.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(draft.isSubmitting || draft.submissionOutcome != nil)
            .overlay {
                if draft.isSubmitting || draft.submissionOutcome != nil {
                    SubmissionFeedbackOverlayView(
                        isSubmitting: draft.isSubmitting,
                        stage: draft.submissionStage,
                        flow: .questResult,
                        outcome: draft.submissionOutcome,
                        sentTitle: "Quest Submitted",
                        onDone: {
                            finishSubmittedQuestAndDismiss()
                        },
                        onSendAnother: nil
                    )
                }
            }
            .animation(.easeInOut(duration: 0.22), value: draft.isSubmitting)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: draft.submissionOutcome != nil)
            .navigationTitle("Complete Quest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        draft.cancelCapture()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            questState.dismissResultSheet()
                        }
                        dismiss()
                    }
                    .disabled(draft.isSubmitting || draft.submissionOutcome != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft.submissionOutcome != nil {
                        Button("Done") {
                            finishSubmittedQuestAndDismiss()
                        }
                        .accessibilityIdentifier("HollerKitQuestResultDoneButton")
                    } else {
                        Button(draft.isSubmitting ? "Submitting..." : "Submit") {
                            Task {
                                await submit()
                            }
                        }
                        .disabled(draft.isSubmitting || draft.isLoadingAttachments || draft.speechCapture.isStopping || questState.activeQuest == nil)
                        .accessibilityIdentifier("HollerKitQuestResultSubmitButton")
                    }
                }
            }
        }
        .interactiveDismissDisabled(draft.isSubmitting)
        .onAppear {
            if let activeSession = questState.activeQuest {
                capturedSession = activeSession
            }
            refreshClipboardImageAvailability()
        }
        .onChange(of: questState.activeQuest) { _, newSession in
            if let newSession {
                capturedSession = newSession
            }
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
        .onChange(of: draft.speechCapture.transcript) { _, _ in
            draft.comment = draft.speechCapture.consumeTranscriptForCommentMerge(into: draft.comment)
        }
        .onChange(of: draft.selectedImage) { _, newImage in
            if let newImage {
                activeAnnotationTarget = .userImage(newImage)
            } else if case .userImage = activeAnnotationTarget {
                activeAnnotationTarget = nil
            }
        }
        .onChange(of: activeAnnotationTarget) { _, newTarget in
            if case .userImage(let img) = newTarget {
                draft.selectedImage = img
            } else {
                draft.selectedImage = nil
            }
        }
        .onDisappear {
            draft.cancelCapture()
            if draft.submissionOutcome != nil, let submittedSessionId = draft.submittedSessionId {
                questState.completeSubmittedSession(id: submittedSessionId)
            }
        }
        .sheet(item: $activeAnnotationTarget) { target in
            #if canImport(UIKit)
            NavigationStack {
                switch target {
                case .mark(let item):
                    AnnotationEditorScreen(
                        image: BugReportImage(title: item.title, image: item.image)
                    ) { renderedImage in
                        if let data = renderedImage.pngData() {
                            questState.replaceMarkImage(id: item.markId, with: data)
                        }
                    }
                case .userImage(let image):
                    AnnotationEditorScreen(image: image) { renderedImage in
                        draft.replaceImage(id: image.id, with: renderedImage)
                    }
                }
            }
            #else
            Text("Annotation is unavailable on this platform.")
            #endif
        }
        .accessibilityIdentifier("HollerKitQuestResultSheet")
    }

    /// Completes session teardown and dismisses the quest result sheet after submission.
    @MainActor
    private func finishSubmittedQuestAndDismiss() {
        draft.cancelCapture()
        if let submittedSessionId = draft.submittedSessionId {
            questState.completeSubmittedSession(id: submittedSessionId)
        }
        dismiss()
    }

    /// Finalizes any active speech capture and submits the completed quest run.
    @MainActor
    private func submit() async {
        await draft.submit(
            questState: questState,
            clearActiveSessionImmediately: false,
            onAutoDismiss: {
                finishSubmittedQuestAndDismiss()
            }
        )
    }

    /// Updates `draft.hasClipboardImage` from the system pasteboard without reading clipboard item payloads until tapped.
    @MainActor
    func refreshClipboardImageAvailability() {
        _ = draft.refreshClipboardImageAvailability()
    }

    #if canImport(PhotosUI) && canImport(UIKit)
    /// Loads and attaches photos selected from the system `PhotosPicker`.
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
                draft.attachmentStatusMessage = "You can attach up to \(QuestResultDraft.maxAttachments) photos per quest."
                break
            }
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
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
                ? "Could not load the selected photo."
                : "Could not load \(failedCount) selected photos."
        }
    }
    #endif

    /// Returns the SF Symbol name for a given quest result option.
    private func iconName(for result: QuestResult) -> String {
        switch result {
        case .pass:
            return "checkmark.seal.fill"
        case .fail:
            return "xmark.octagon.fill"
        case .unsure:
            return "questionmark.diamond.fill"
        case .abandoned:
            return "slash.circle"
        }
    }

    /// Returns the high-contrast tint color for a given quest result option in both light and dark appearances.
    private func color(for result: QuestResult) -> Color {
        switch result {
        case .pass:
            return Self.checkedStepColor
        case .fail:
            return Color(red: 0.78, green: 0.12, blue: 0.16)
        case .unsure:
            return Color(red: 0.70, green: 0.34, blue: 0.00)
        case .abandoned:
            return .secondary
        }
    }
}

private enum ActiveAnnotationTarget: Identifiable, Equatable {
    case mark(AnnotatableMarkImage)
    case userImage(BugReportImage)

    var id: UUID {
        switch self {
        case .mark(let mark):
            return mark.id
        case .userImage(let img):
            return img.id
        }
    }

    static func == (lhs: ActiveAnnotationTarget, rhs: ActiveAnnotationTarget) -> Bool {
        lhs.id == rhs.id
    }
}

private struct AnnotatableMarkImage: Identifiable, Equatable {
    var id: UUID { markId }
    var markId: UUID
    var title: String
    #if canImport(UIKit)
    var image: UIImage
    #endif

    static func == (lhs: AnnotatableMarkImage, rhs: AnnotatableMarkImage) -> Bool {
        lhs.markId == rhs.markId
    }
}
