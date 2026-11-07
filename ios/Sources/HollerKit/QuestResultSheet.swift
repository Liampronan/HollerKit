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
    @State private var submissionError: String?

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
                                HStack {
                                    Image(systemName: iconName(for: option))
                                        .foregroundStyle(color(for: option))
                                    Text(option.displayTitle)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedResult == option {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(color(for: option))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("HollerKitQuestResultOption_\(option.rawValue)")
                        }
                    }

                    Section("Note (Optional)") {
                        TextEditor(text: $comment)
                            .frame(minHeight: 100)

                        if let audioConfig = HollerKit.currentConfiguration?.audio, audioConfig.isEnabled {
                            Button(speechCapture.isCapturing ? "Stop Dictation" : "Dictate Note") {
                                Task {
                                    await speechCapture.toggle(configuration: audioConfig)
                                }
                            }
                            .disabled(isSubmitting)

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
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
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
                            Text(submissionError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Section {
                        Text("No active quest session.")
                            .foregroundStyle(.secondary)
                    }
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
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Submitting..." : "Submit") {
                        Task {
                            await submit()
                        }
                    }
                    .disabled(isSubmitting || questState.activeQuest == nil)
                    .accessibilityIdentifier("HollerKitQuestResultSubmitButton")
                }
            }
        }
        .onDisappear {
            speechCapture.cancelCapture()
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

    @MainActor
    private func submit() async {
        isSubmitting = true
        submissionError = nil
        defer { isSubmitting = false }

        do {
            await speechCapture.finalizeIfCapturing()
            _ = try await questState.submitActiveQuest(
                result: selectedResult,
                comment: comment,
                transcript: speechCapture.transcript
            )
            dismiss()
        } catch {
            submissionError = error.localizedDescription
        }
    }

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
