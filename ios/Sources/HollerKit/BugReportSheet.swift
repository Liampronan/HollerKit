import CryptoKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct BugReportSheet: View {
    private let configuration: HollerKitConfiguration?
    private let breadcrumbs: BreadcrumbStore
    private let invocationAttachments: [HollerKitAttachment]
    @State private var comment = ""
    @State private var images: [BugReportImage] = []
    @State private var selectedImage: BugReportImage?
    @StateObject private var speechCapture = SpeechCaptureController()
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @State private var submittedIssueURL: URL?

    init(
        configuration: HollerKitConfiguration?,
        breadcrumbs: BreadcrumbStore,
        invocationAttachments: [HollerKitAttachment] = []
    ) {
        self.configuration = configuration
        self.breadcrumbs = breadcrumbs
        self.invocationAttachments = invocationAttachments
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $comment)
                        .frame(minHeight: 140)
                }

                if !images.isEmpty {
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

                if let submittedIssueURL {
                    Section("Submitted") {
                        Link("Open GitHub Issue", destination: submittedIssueURL)
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
                    Button(isSubmitting ? "Submitting..." : "Submit") {
                        Task {
                            await submit()
                        }
                    }
                    .disabled(!canSubmit)
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
            #if canImport(UIKit)
            let configuredImages = configuration?.initialImages() ?? []
            images = (invocationAttachments + configuredImages).compactMap(BugReportImage.init(attachment:))
            #endif
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
        guard configuration != nil, !isSubmitting, submittedIssueURL == nil else { return false }
        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !images.isEmpty
            || speechCapture.transcript != nil
    }

    @MainActor
    private func submit() async {
        guard let configuration else {
            submissionError = "HollerKit has not been configured."
            return
        }

        isSubmitting = true
        submissionError = nil
        defer { isSubmitting = false }

        do {
            let client = MultipartClient(endpoint: configuration.endpoint, appSecret: configuration.appSecret)
            let response = try await client.submit(HollerKitReportPayload(
                inputMode: configuration.inputMode,
                comment: normalizedComment,
                transcript: speechCapture.transcript,
                metadata: MetadataCollector.collect(extra: configuration.metadata()),
                breadcrumbs: configuration.captureBreadcrumbs ? breadcrumbs.snapshot() : [],
                userIdHash: hashedUserID(configuration.userID()),
                images: imageAttachments()
            ))
            submittedIssueURL = response.issueUrl
        } catch {
            submissionError = error.localizedDescription
        }
    }

    private var normalizedComment: String? {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func hashedUserID(_ userID: String?) -> String? {
        guard let userID, !userID.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(userID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    @MainActor
    private func toggleSpeechCapture() async {
        guard let configuration else { return }
        await speechCapture.toggle(configuration: configuration.audio)
    }

}

struct BugReportImage: Identifiable, Hashable {
    let id = UUID()
    var title: String

    #if canImport(UIKit)
    var image: UIImage

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

@MainActor
private final class SpeechCaptureController: ObservableObject {
    @Published var isCapturing = false
    @Published var transcript: HollerKitTranscript?
    @Published var errorMessage: String?
    @Published var partialTranscript = ""

    private let capture = SpeechNoteCapture()

    func toggle(configuration: HollerKitAudioConfiguration) async {
        errorMessage = nil

        if isCapturing {
            await stop(configuration: configuration)
        } else {
            await start(configuration: configuration)
        }
    }

    private func start(configuration: HollerKitAudioConfiguration) async {
        do {
            transcript = nil
            partialTranscript = ""
            try await capture.start(options: SpeechTranscriberOptions(
                requireOnDeviceRecognition: configuration.requiresOnDeviceTranscription
            ))
            isCapturing = true
            bindPartialTranscript()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stop(configuration: HollerKitAudioConfiguration) async {
        do {
            transcript = try capture.stop()
            partialTranscript = ""
            isCapturing = false
        } catch {
            isCapturing = false
            errorMessage = error.localizedDescription
        }
    }

    private func bindPartialTranscript() {
        Task { @MainActor in
            while capture.isCapturing {
                partialTranscript = capture.transcriptText
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private extension HollerKitAudioConfiguration {
    var requiresOnDeviceTranscription: Bool {
        switch self {
        case .transcriptOnly(_, let requireOnDeviceTranscription),
             .transcriptAndAttachment(_, let requireOnDeviceTranscription, _):
            return requireOnDeviceTranscription
        case .off, .attachmentOnly:
            return false
        }
    }

}

private struct ImageAttachmentThumbnail: View {
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
