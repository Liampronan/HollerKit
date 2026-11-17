import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Identifies the user-facing submission flow for progress copy.
public enum SubmissionFlow: String, CaseIterable, Equatable, Sendable {
    case bugReport
    case questResult
}

/// Progress stages displayed while a bug report or quest run is being submitted.
public enum SubmissionProgressStage: Equatable, Sendable {
    public typealias Flow = SubmissionFlow

    case preparing
    case uploadingAttachments(count: Int)
    case uploadingAttachment(index: Int, total: Int, progress: Double)
    case sending

    /// Human-readable headline for the current submission stage.
    public var title: String {
        title(for: .bugReport)
    }

    /// Flow-specific human-readable headline for the current submission stage.
    public func title(for flow: SubmissionFlow) -> String {
        switch self {
        case .preparing:
            return "Preparing feedback…"
        case .uploadingAttachments(let count):
            return count == 1 ? "Uploading 1 attachment…" : "Uploading \(count) attachments…"
        case .uploadingAttachment(let index, let total, let progress):
            let percent = Int((min(1.0, max(0.0, progress)) * 100).rounded())
            if total <= 1 {
                return "Uploading attachment (\(percent)%)…"
            }
            return "Uploading attachment \(index) of \(total) (\(percent)%)…"
        case .sending:
            switch flow {
            case .bugReport:
                return "Sending your report…"
            case .questResult:
                return "Sending your result…"
            }
        }
    }

    /// Fractional upload progress (`0.0 ... 1.0`) when actively uploading an attachment, or `nil` for indeterminate stages.
    public var progress: Double? {
        switch self {
        case .uploadingAttachment(let index, let total, let itemProgress):
            let clampedItem = min(1.0, max(0.0, itemProgress))
            guard total > 0 else { return clampedItem }
            let completed = Double(max(0, index - 1))
            return min(1.0, max(0.0, (completed + clampedItem) / Double(total)))
        case .preparing, .uploadingAttachments, .sending:
            return nil
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

/// Full-sheet progress and post-submission confirmation overlay shared by bug reports and quest runs.
struct SubmissionFeedbackOverlayView: View {
    var isSubmitting: Bool
    var stage: SubmissionProgressStage?
    var flow: SubmissionFlow = .bugReport
    var outcome: OutboxSubmissionOutcome?
    var sentTitle: String
    var onDone: () -> Void
    var onSendAnother: (() -> Void)?

    @State private var animateBadge = false

    /// Resolved human-readable progress headline for the overlay's current stage and submission flow.
    var progressTitle: String {
        (stage ?? .sending).title(for: flow)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if isSubmitting {
                    if let progressValue = stage?.progress {
                        ProgressView(value: progressValue, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)
                            .padding(.bottom, 4)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .padding(.bottom, 4)
                    }

                    Text(progressTitle)
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

                    case .queued(_, let reason, let isAuthenticationError):
                        let isAuthFailure = isAuthenticationError || Self.isAuthenticationFailureReason(reason)
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
                                ? "Your feedback is stored on this device. Sign in, then reopen the app or submit again to finish sending."
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
