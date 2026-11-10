import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct QuestResultSheet: View {
    @ObservedObject private var questState: HollerKitQuestState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedResult: QuestResult = .pass
    @State private var comment = ""
    @StateObject private var speechCapture = SpeechCaptureController()
    @State private var selectedMarkForAnnotation: AnnotatableMarkImage?
    @State private var isSubmitting = false
    @State private var submissionStage: SubmissionProgressStage?
    @State private var submissionError: String?
    @State private var submissionOutcome: OutboxSubmissionOutcome?
    @State private var submittedSessionId: UUID?
    @State private var autoDismissTask: Task<Void, Never>?

    private static let selectableResults: [QuestResult] = [.pass, .fail, .unsure]

    public init(questState: HollerKitQuestState = HollerKit.quests) {
        self.questState = questState
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let session = questState.activeQuest {
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
                                selectedResult = option
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: iconName(for: option))
                                        .symbolRenderingMode(.monochrome)
                                        .foregroundStyle(color(for: option))
                                        .frame(width: 20, height: 20, alignment: .center)
                                    Text(option.displayTitle)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedResult == option {
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
                            .disabled(isSubmitting)
                            .accessibilityValue(selectedResult == option ? "selected" : "unselected")
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
                                                    .foregroundStyle(Color.white, Color.green)
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
                                .disabled(isSubmitting)
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
                                    .disabled(isSubmitting)
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
                            if comment.isEmpty {
                                Text("Add an optional note about this quest run...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $comment)
                                .frame(minHeight: 100)
                                .disabled(isSubmitting)
                                .accessibilityIdentifier("HollerKitQuestResultCommentEditor")
                        }

                        if let audioConfig = HollerKit.currentConfiguration?.audio, audioConfig.isEnabled {
                            Button {
                                Task {
                                    await speechCapture.toggle(configuration: audioConfig)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: speechCapture.isCapturing ? "stop.circle.fill" : "mic.fill")
                                        .symbolRenderingMode(.monochrome)
                                    Text(speechCapture.isCapturing ? "Stop Dictation" : "Dictate Note")
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
                                            await speechCapture.retry(configuration: audioConfig)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.clockwise")
                                                .symbolRenderingMode(.monochrome)
                                            Text("Retry Dictation")
                                        }
                                        .font(.footnote.weight(.semibold))
                                    }
                                    .disabled(isSubmitting || speechCapture.isCapturing || speechCapture.isStopping)
                                    .accessibilityIdentifier("HollerKitSpeechRetryButton")
                                }
                            }
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
                                                selectedMarkForAnnotation = AnnotatableMarkImage(
                                                    markId: mark.id,
                                                    title: "\(mark.label) (+\(Int(mark.offsetSeconds))s)",
                                                    image: uiImage
                                                )
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

                    if let submissionError {
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
                                .disabled(isSubmitting || speechCapture.isStopping)
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
            .disabled(isSubmitting || submissionOutcome != nil)
            .overlay {
                if isSubmitting || submissionOutcome != nil {
                    SubmissionFeedbackOverlayView(
                        isSubmitting: isSubmitting,
                        stage: submissionStage,
                        outcome: submissionOutcome,
                        sentTitle: "Quest Submitted",
                        onDone: {
                            finishSubmittedQuestAndDismiss()
                        },
                        onSendAnother: nil
                    )
                }
            }
            .navigationTitle("Complete Quest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        speechCapture.cancelCapture()
                        questState.dismissResultSheet()
                        dismiss()
                    }
                    .disabled(isSubmitting || submissionOutcome != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submissionOutcome != nil {
                        Button("Done") {
                            finishSubmittedQuestAndDismiss()
                        }
                        .accessibilityIdentifier("HollerKitQuestResultDoneButton")
                    } else {
                        Button(isSubmitting ? "Submitting..." : "Submit") {
                            Task {
                                await submit()
                            }
                        }
                        .disabled(isSubmitting || speechCapture.isStopping || questState.activeQuest == nil)
                        .accessibilityIdentifier("HollerKitQuestResultSubmitButton")
                    }
                }
            }
        }
        .onChange(of: speechCapture.transcript) { _, _ in
            comment = speechCapture.consumeTranscriptForCommentMerge(into: comment)
        }
        .onDisappear {
            autoDismissTask?.cancel()
            autoDismissTask = nil
            speechCapture.cancelCapture()
            if submissionOutcome != nil, let submittedSessionId {
                questState.completeSubmittedSession(id: submittedSessionId)
            }
        }
        .sheet(item: $selectedMarkForAnnotation) { item in
            #if canImport(UIKit)
            NavigationStack {
                AnnotationEditorScreen(
                    image: BugReportImage(title: item.title, image: item.image)
                ) { renderedImage in
                    if let data = renderedImage.pngData() {
                        questState.replaceMarkImage(id: item.markId, with: data)
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
        autoDismissTask?.cancel()
        autoDismissTask = nil
        speechCapture.reset()
        comment = ""
        if let submittedSessionId {
            questState.completeSubmittedSession(id: submittedSessionId)
        }
        dismiss()
    }

    /// Finalizes any active speech capture and submits the completed quest run.
    @MainActor
    private func submit() async {
        guard !isSubmitting, let session = questState.activeQuest else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        isSubmitting = true
        submissionStage = .preparing
        submissionError = nil
        defer {
            isSubmitting = false
            submissionStage = nil
        }

        do {
            let wasCapturing = speechCapture.isCapturing
                || speechCapture.isStopping
                || speechCapture.capture.isCapturing
                || speechCapture.capture.isStopping
            await speechCapture.finalizeIfCapturing()
            if wasCapturing && speechCapture.errorMessage != nil {
                SubmissionHaptics.notifyError()
                return
            }

            comment = speechCapture.consumeTranscriptForCommentMerge(into: comment)
            let markCount = session.marks.filter { !$0.imageData.isEmpty }.count
            submissionStage = markCount > 0
                ? .uploadingAttachments(count: markCount)
                : .sending
            let commentToSubmit = comment
            let transcriptToSubmit = speechCapture.transcript
            let outcome = try await questState.submitActiveQuest(
                result: selectedResult,
                comment: commentToSubmit,
                transcript: transcriptToSubmit,
                clearActiveSessionImmediately: false,
                onProgress: { stage in
                    await MainActor.run {
                        submissionStage = stage
                    }
                }
            )
            submittedSessionId = session.id
            speechCapture.reset()
            comment = ""
            submissionOutcome = outcome
            SubmissionHaptics.notify(for: outcome)

            if case .sent = outcome {
                autoDismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard !Task.isCancelled, submissionOutcome != nil else { return }
                    finishSubmittedQuestAndDismiss()
                }
            }
        } catch {
            submissionError = error.localizedDescription
            SubmissionHaptics.notifyError()
        }
    }

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

    /// Returns the tint color for a given quest result option.
    private func color(for result: QuestResult) -> Color {
        switch result {
        case .pass:
            return .green
        case .fail:
            return .red
        case .unsure:
            return .orange
        case .abandoned:
            return .secondary
        }
    }
}

private struct AnnotatableMarkImage: Identifiable {
    var id: UUID { markId }
    var markId: UUID
    var title: String
    #if canImport(UIKit)
    var image: UIImage
    #endif
}
