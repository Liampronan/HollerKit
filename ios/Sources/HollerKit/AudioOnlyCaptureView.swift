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
                .disabled(capture.isStopping)

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
                VStack(spacing: 8) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button {
                        Task {
                            await retryTranscription()
                        }
                    } label: {
                        Label("Retry Dictation", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                    }
                    .disabled(capture.isCapturing || capture.isStopping)
                }
            }
            Spacer()
        }
        .padding()
        .onChange(of: capture.lastError) { _, newError in
            if let newError {
                errorMessage = newError
            }
        }
        .accessibilityIdentifier("HollerKitAudioOnlyCaptureView")
    }

    /// Toggles between starting and stopping live voice transcription.
    @MainActor
    private func toggleTranscription() async {
        guard !capture.isStopping else { return }
        errorMessage = nil

        do {
            if capture.isCapturing {
                transcript = try await capture.stopAsync()
            } else {
                transcript = nil
                try await capture.start()
            }
        } catch {
            errorMessage = SpeechNoteCaptureError.describeError(error)
        }
    }

    /// Retries starting voice transcription after an error.
    @MainActor
    private func retryTranscription() async {
        guard !capture.isStopping else { return }
        errorMessage = nil
        transcript = nil
        do {
            try await capture.start()
        } catch {
            errorMessage = SpeechNoteCaptureError.describeError(error)
        }
    }
}
