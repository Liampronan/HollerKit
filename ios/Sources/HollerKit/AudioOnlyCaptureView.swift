import SwiftUI

public struct AudioOnlyCaptureView: View {
    @StateObject private var capture = SpeechNoteCapture()
    @State private var transcript: HollerKitTranscript?
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(capture.isCapturing ? "Listening" : "Voice Note")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
            Button(capture.isCapturing ? "Stop Transcribing" : "Start Transcribing") {
                Task {
                    await toggleTranscription()
                }
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            if let transcript {
                Text(transcript.text)
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else if !capture.transcriptText.isEmpty {
                Text(capture.transcriptText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
        .accessibilityIdentifier("HollerKitAudioOnlyCaptureView")
    }

    @MainActor
    private func toggleTranscription() async {
        errorMessage = nil

        do {
            if capture.isCapturing {
                transcript = try capture.stop()
            } else {
                transcript = nil
                try await capture.start()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
