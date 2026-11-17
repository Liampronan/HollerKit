import AVFoundation
import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
#endif

public enum BugReportAttachmentKind: String, Codable, Equatable, Hashable, Sendable {
    case image
    case video
}

typealias BugReportImage = BugReportAttachment

struct BugReportAttachment: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var kind: BugReportAttachmentKind
    var videoFileURL: URL?
    var videoMimeType: String?
    var videoDurationSeconds: TimeInterval?
    var videoFileSize: Int?

    var isVideo: Bool {
        kind == .video
    }

    var formattedDuration: String? {
        guard isVideo, let duration = videoDurationSeconds, duration.isFinite, duration >= 0 else {
            return nil
        }
        let totalSeconds = max(1, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    #if canImport(UIKit)
    var image: UIImage

    /// Creates a normalized bug report image attachment with the given display title and `UIImage`.
    init(title: String, image: UIImage) {
        self.title = title
        self.kind = .image
        self.image = Self.normalizedImage(image)
    }

    /// Creates a bug report video attachment with a thumbnail preview, file URL, MIME type, duration, and file size.
    init(
        title: String,
        thumbnail: UIImage,
        videoFileURL: URL,
        videoMimeType: String,
        durationSeconds: TimeInterval,
        fileSize: Int
    ) {
        self.title = title
        self.kind = .video
        self.image = Self.normalizedImage(thumbnail)
        self.videoFileURL = videoFileURL
        self.videoMimeType = videoMimeType
        self.videoDurationSeconds = durationSeconds
        self.videoFileSize = fileSize
    }

    /// Creates a bug report attachment from a `HollerKitAttachment` (image or video).
    init?(attachment: HollerKitAttachment) {
        if attachment.kind == "video" || attachment.mimeType.lowercased().hasPrefix("video/") {
            guard let fileURL = attachment.fileURL,
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? attachment.data.count
            self.title = attachment.filename
            self.kind = .video
            self.image = Self.placeholderVideoThumbnail()
            self.videoFileURL = fileURL
            self.videoMimeType = attachment.mimeType
            self.videoDurationSeconds = attachment.durationSeconds ?? 1
            self.videoFileSize = size
            return
        }
        guard let image = Self.downsampledImage(from: attachment.data) else { return nil }
        self.title = attachment.filename
        self.kind = .image
        self.image = image
    }

    /// Inspects the duration in seconds of the video asset at `url`.
    nonisolated static func inspectVideoDurationSeconds(at url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let cmDuration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(cmDuration)
        guard seconds.isFinite, seconds > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return seconds
    }

    /// Generates a thumbnail `UIImage` from the first frame of the video at `url`.
    nonisolated static func generateVideoThumbnail(
        for url: URL,
        maxPixelDimension: CGFloat = 480
    ) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelDimension, height: maxPixelDimension)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        }
        return nil
    }

    /// Renders a fallback placeholder thumbnail when `AVAssetImageGenerator` cannot decode a frame.
    nonisolated static func placeholderVideoThumbnail() -> UIImage {
        let size = CGSize(width: 272, height: 208)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Transcodes the video at `sourceURL` into `outputDirectoryURL` using `AVAssetExportSession` with a 720p/medium preset.
    nonisolated static func transcodeVideo(
        sourceURL: URL,
        outputDirectoryURL: URL,
        maxBytes: Int
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let preferredPresets = [
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPresetLowQuality
        ]
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let chosenPreset = preferredPresets.first(where: { compatible.contains($0) }) ?? AVAssetExportPresetMediumQuality

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: chosenPreset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        let outputURL = outputDirectoryURL.appendingPathComponent("transcoded-\(UUID().uuidString).mp4", isDirectory: false)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let fileType: AVFileType = exportSession.supportedFileTypes.contains(.mp4)
            ? .mp4
            : (exportSession.supportedFileTypes.first ?? .mov)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = fileType
        exportSession.shouldOptimizeForNetworkUse = true

        let box = UncheckedSendableBox(value: exportSession)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.value.exportAsynchronously {
                continuation.resume()
            }
        }

        switch box.value.status {
        case .completed:
            return outputURL
        default:
            try? FileManager.default.removeItem(at: outputURL)
            throw box.value.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// Downsamples encoded image `data` using `ImageIO` without decoding the full-resolution bitmap into memory,
    /// preserving EXIF orientation and capping the longest side at `maxPixelDimension`.
    nonisolated static func downsampledCGImage(
        from data: Data,
        maxPixelDimension: CGFloat = BugReportDraft.maxPixelDimension
    ) -> CGImage? {
        guard !data.isEmpty else { return nil }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let maxPixelSize = max(1, Int(maxPixelDimension.rounded()))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// Downsamples encoded image `data` into a normalized `UIImage` capped at `maxPixelDimension`.
    nonisolated static func downsampledImage(
        from data: Data,
        maxPixelDimension: CGFloat = BugReportDraft.maxPixelDimension
    ) -> UIImage? {
        if let cgImage = downsampledCGImage(from: data, maxPixelDimension: maxPixelDimension) {
            return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        }
        guard let fallback = UIImage(data: data) else { return nil }
        return normalizedImage(fallback, maxPixelDimension: maxPixelDimension)
    }

    /// Downscales `image` proportionally when its pixel width or height exceeds `maxPixelDimension`
    /// and normalizes image orientation to `.up`.
    static func normalizedImage(
        _ image: UIImage,
        maxPixelDimension: CGFloat = BugReportDraft.maxPixelDimension
    ) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let maxSide = max(pixelWidth, pixelHeight)
        guard maxSide > 0 else { return image }

        let scaleFactor = maxSide > maxPixelDimension ? (maxPixelDimension / maxSide) : 1.0
        if scaleFactor == 1.0 && image.imageOrientation == .up {
            return image
        }

        let targetSize = CGSize(
            width: max(1, (pixelWidth * scaleFactor).rounded()),
            height: max(1, (pixelHeight * scaleFactor).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Encodes the attachment into a `HollerKitAttachment`:
    /// - Video attachments reference their on-disk `videoFileURL` directly without reading the video into `Data`.
    /// - Image attachments are encoded within `maxBytes`, keeping compact screenshots as PNG and compressing larger photos as JPEG.
    func encodedAttachment(
        index: Int,
        maxBytes: Int = BugReportDraft.maxAttachmentBytes,
        preferredPNGMaxBytes: Int = BugReportDraft.preferredPNGMaxBytes,
        maxPixelDimension: CGFloat = BugReportDraft.maxPixelDimension
    ) -> HollerKitAttachment? {
        if isVideo {
            guard let fileURL = videoFileURL,
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let ext = fileURL.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"
            let mime = videoMimeType ?? (ext == "mp4" ? "video/mp4" : "video/quicktime")
            return HollerKitAttachment(
                filename: submissionFilename(index: index, fileExtension: ext),
                mimeType: mime,
                data: Data(),
                fileURL: fileURL,
                kind: "video",
                durationSeconds: videoDurationSeconds
            )
        }

        var candidate = Self.normalizedImage(image, maxPixelDimension: maxPixelDimension)
        let pngThreshold = min(maxBytes, preferredPNGMaxBytes)
        if let pngData = candidate.pngData(), pngData.count <= pngThreshold {
            return HollerKitAttachment(
                filename: submissionFilename(index: index, fileExtension: "png"),
                mimeType: "image/png",
                data: pngData
            )
        }

        let qualities: [CGFloat] = [0.82, 0.7, 0.55, 0.4, 0.25]
        var currentDimension = max(
            candidate.size.width * candidate.scale,
            candidate.size.height * candidate.scale
        )

        for pass in 0..<4 {
            if pass > 0 {
                currentDimension = max(320, (currentDimension * 0.7).rounded())
                candidate = Self.normalizedImage(candidate, maxPixelDimension: currentDimension)
            }
            for quality in qualities {
                if let jpegData = candidate.jpegData(compressionQuality: quality),
                   jpegData.count <= maxBytes {
                    return HollerKitAttachment(
                        filename: submissionFilename(index: index, fileExtension: "jpg"),
                        mimeType: "image/jpeg",
                        data: jpegData
                    )
                }
            }
        }

        if let pngData = candidate.pngData(), pngData.count <= maxBytes {
            return HollerKitAttachment(
                filename: submissionFilename(index: index, fileExtension: "png"),
                mimeType: "image/png",
                data: pngData
            )
        }
        return nil
    }
    #endif

    static func == (lhs: BugReportAttachment, rhs: BugReportAttachment) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Builds a sanitized attachment filename using `title` (or `image-<index + 1>` / `video-<index + 1>`) and `fileExtension`.
    func submissionFilename(index: Int, fileExtension: String = "png") -> String {
        let base = (title as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPrefix = isVideo ? "video" : "image"
        let safeBase = base.isEmpty ? "\(defaultPrefix)-\(index + 1)" : base
        return "\(safeBase).\(fileExtension)"
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}
