import SwiftUI
import UniformTypeIdentifiers

#if canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Evaluates whether the pasteboard currently advertises any attachable image, video, or URL types
/// without reading item payloads (preventing iOS paste permission prompts before the user taps Paste).
enum ClipboardAttachmentAvailability {
    #if canImport(UIKit)
    @MainActor
    static func hasAttachableItem(pasteboard: UIPasteboard = .general) -> Bool {
        if pasteboard.hasImages || pasteboard.hasURLs {
            return true
        }
        let allItemTypes = pasteboard.types(forItemSet: nil)?.flatMap { $0 } ?? pasteboard.types
        return hasAttachableTypeIdentifiers(allItemTypes)
    }
    #endif

    static func hasAttachableTypeIdentifiers(_ identifiers: [String]) -> Bool {
        identifiers.contains { identifier in
            guard let utType = UTType(identifier) else { return false }
            return utType.conforms(to: .movie)
                || utType.conforms(to: .video)
                || utType.conforms(to: .image)
                || utType.conforms(to: .url)
        }
    }
}

/// Shared row displaying the "Paste from Clipboard" action button alongside an always-reachable info button and hint.
@MainActor
struct ClipboardPasteAttachmentRow: View {
    nonisolated static let pasteButtonTitle = "Paste from Clipboard"
    nonisolated static let pasteButtonSystemImage = "doc.on.clipboard"
    nonisolated static let pasteButtonAccessibilityIdentifier = "HollerKitPasteImageButton"
    nonisolated static let hintButtonSystemImage = "info.circle"
    nonisolated static let hintButtonAccessibilityIdentifier = "HollerKitPasteHintButton"
    nonisolated static let hintButtonAccessibilityLabel = "Paste from Clipboard Info"
    nonisolated static let hintTextAccessibilityIdentifier = "HollerKitPasteHintText"
    nonisolated static let hintMessage = "Copy a screenshot or screen recording, then paste it here."

    var hasClipboardImage: Bool
    var isSubmitting: Bool
    var isLoadingAttachments: Bool
    var canAddMoreImages: Bool
    var onPaste: @MainActor () -> Void

    @State private var isShowingHint = false

    /// Returns `true` when the paste button should be disabled (empty clipboard, submitting, loading, or at attachment cap).
    var isPasteButtonDisabled: Bool {
        !hasClipboardImage || isSubmitting || isLoadingAttachments || !canAddMoreImages
    }

    /// Returns `true` when the info button should be disabled (only while actively submitting, never when the clipboard is empty).
    var isHintButtonDisabled: Bool {
        isSubmitting
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onPaste()
            } label: {
                Label(Self.pasteButtonTitle, systemImage: Self.pasteButtonSystemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isPasteButtonDisabled)
            .accessibilityIdentifier(Self.pasteButtonAccessibilityIdentifier)
            .accessibilityHint(Self.hintMessage)

            Button {
                isShowingHint.toggle()
            } label: {
                Image(systemName: Self.hintButtonSystemImage)
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isHintButtonDisabled)
            .accessibilityIdentifier(Self.hintButtonAccessibilityIdentifier)
            .accessibilityLabel(Self.hintButtonAccessibilityLabel)
            .accessibilityValue(Self.hintMessage)
            .accessibilityHint(Self.hintMessage)
            .popover(isPresented: $isShowingHint, arrowEdge: .top) {
                Text(Self.hintMessage)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(idealWidth: 240, maxWidth: 260, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .presentationCompactAdaptation(.popover)
                    .accessibilityIdentifier(Self.hintTextAccessibilityIdentifier)
            }
        }
    }
}

#if canImport(PhotosUI)
/// File-backed `Transferable` representation for `PhotosPicker` video items so large clips are copied to disk rather than loaded into `Data`.
struct PickedMovieTransferable: Transferable, Sendable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("HollerKitPickedMovies", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = tempDir.appendingPathComponent("\(UUID().uuidString).\(ext)", isDirectory: false)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovieTransferable(fileURL: destination)
        }
    }
}
#endif

struct ImageAttachmentThumbnail: View {
    var image: BugReportAttachment
    var isDisabled: Bool = false
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        #if canImport(UIKit)
        ZStack(alignment: .topTrailing) {
            if let onTap, !image.isVideo {
                Button(action: onTap) {
                    thumbnailContent
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .contextMenu {
                    Button {
                        onTap()
                    } label: {
                        Label("Annotate", systemImage: "pencil.tip.crop.circle")
                    }

                    if let onRemove {
                        Button(role: .destructive) {
                            onRemove()
                        } label: {
                            Label("Remove Attachment", systemImage: "trash")
                        }
                    }
                }
            } else {
                thumbnailContent
                    .contextMenu {
                        if let onRemove {
                            Button(role: .destructive) {
                                onRemove()
                            } label: {
                                Label("Remove Attachment", systemImage: "trash")
                            }
                        }
                    }
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.68))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel("Remove \(image.title)")
                .accessibilityIdentifier("HollerKitRemoveAttachmentButton_\(image.title)")
            }
        }
        #else
        EmptyView()
        #endif
    }

    #if canImport(UIKit)
    /// Renders the thumbnail preview image, optional video duration badge, and title caption for an attachment.
    private var thumbnailContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
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

                if image.isVideo, let durationText = image.formattedDuration {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(durationText)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .padding(6)
                    .accessibilityIdentifier("HollerKitVideoDurationBadge_\(image.title)")
                }
            }

            Text(image.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 136, alignment: .leading)
        }
        .accessibilityLabel(
            image.isVideo
                ? "Attached video \(image.title)\(image.formattedDuration.map { ", duration \($0)" } ?? "")"
                : "Attached image \(image.title)"
        )
    }
    #endif
}
