import AVFoundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Progress stages displayed while a bug report or quest run is being submitted.
public enum SubmissionProgressStage: Equatable, Sendable {
    case preparing
    case uploadingAttachments(count: Int)
    case uploadingAttachment(index: Int, total: Int, progress: Double)
    case sending

    /// Human-readable headline for the current submission stage.
    public var title: String {
        switch self {
        case .preparing:
            return "Preparing feedback..."
        case .uploadingAttachments(let count):
            return count == 1 ? "Uploading 1 attachment..." : "Uploading \(count) attachments..."
        case .uploadingAttachment(let index, let total, let progress):
            let percent = Int((min(1.0, max(0.0, progress)) * 100).rounded())
            if total <= 1 {
                return "Uploading attachment (\(percent)%)..."
            }
            return "Uploading attachment \(index) of \(total) (\(percent)%)..."
        case .sending:
            return "Sending to server..."
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

/// Holds the mutable form state and submission lifecycle for a bug report presentation.
@Observable
@MainActor
final class BugReportDraft {
    nonisolated static let maxAttachments = 12
    nonisolated static let maxVideoAttachments = 3
    nonisolated static let maxAttachmentBytes = 10 * 1024 * 1024
    nonisolated static let defaultMaxVideoBytes = 50 * 1024 * 1024
    nonisolated static let maxVideoDurationSeconds: TimeInterval = 60
    nonisolated static let preferredPNGMaxBytes = 2 * 1024 * 1024
    nonisolated static let maxPixelDimension: CGFloat = 2400

    let id = UUID()
    var comment = ""
    var images: [BugReportAttachment] = []
    var selectedImage: BugReportAttachment? {
        didSet {
            if selectedImage?.isVideo == true {
                selectedImage = nil
            }
        }
    }
    var isLoadingAttachments = false
    var attachmentStatusMessage: String?
    var isSubmitting = false
    var submissionStage: SubmissionProgressStage?
    var submissionError: String?
    var submissionOutcome: OutboxSubmissionOutcome?

    @ObservationIgnored
    var invokingTrigger: String = "manual"
    let speechCapture = SpeechCaptureController()
    @ObservationIgnored
    var autoDismissDelaySeconds: TimeInterval? = nil
    @ObservationIgnored
    var maxVideoBytesOverride: Int? = nil
    @ObservationIgnored
    private(set) var photoLoadGeneration: UInt64 = 0
    @ObservationIgnored
    private(set) var transcodeInvocationCount: Int = 0
    @ObservationIgnored
    let tempDirectoryURL: URL

    @ObservationIgnored
    var videoDurationInspector: @Sendable (URL) async throws -> TimeInterval = { url in
        try await BugReportAttachment.inspectVideoDurationSeconds(at: url)
    }
    @ObservationIgnored
    var videoTranscoder: @Sendable (URL, URL, Int) async throws -> URL = { sourceURL, outputDir, maxBytes in
        try await BugReportAttachment.transcodeVideo(
            sourceURL: sourceURL,
            outputDirectoryURL: outputDir,
            maxBytes: maxBytes
        )
    }
    #if canImport(UIKit)
    @ObservationIgnored
    var videoThumbnailGenerator: @Sendable (URL) async -> UIImage? = { url in
        await BugReportAttachment.generateVideoThumbnail(for: url)
    }
    #endif

    @ObservationIgnored
    private var didLoadInitialImages = false
    @ObservationIgnored
    private var nextAddedImageNumber = 1
    @ObservationIgnored
    private var nextAddedVideoNumber = 1
    @ObservationIgnored
    private var autoDismissTask: Task<Void, Never>?

    /// Returns `true` when additional attachments can be added to the draft.
    var canAddMoreImages: Bool {
        images.count < Self.maxAttachments
    }

    /// Returns the number of remaining attachment slots before hitting `maxAttachments`.
    var remainingImageSlots: Int {
        max(0, Self.maxAttachments - images.count)
    }

    /// Returns the number of video attachments currently in the draft.
    var videoCount: Int {
        images.filter(\.isVideo).count
    }

    /// Returns `true` when additional video attachments can be added (fewer than 3 videos and fewer than 12 total attachments).
    var canAddMoreVideos: Bool {
        canAddMoreImages && videoCount < Self.maxVideoAttachments
    }

    /// Returns the number of remaining video attachment slots before hitting `maxVideoAttachments` or `maxAttachments`.
    var remainingVideoSlots: Int {
        min(remainingImageSlots, max(0, Self.maxVideoAttachments - videoCount))
    }

    /// Returns the effective maximum video size in bytes, preferring any test override or server-reported limit before falling back to 50 MB.
    var effectiveMaxVideoBytes: Int {
        if let override = maxVideoBytesOverride, override > 0 {
            return override
        }
        if let serverLimit = HollerKit.quests.serverMaxVideoBytes, serverLimit > 0 {
            return serverLimit
        }
        return Self.defaultMaxVideoBytes
    }

    #if canImport(PhotosUI)
    /// Filter used by `PhotosPicker`: allows both images and videos until 3 videos are attached, then limits selection to images.
    var pickerFilter: PHPickerFilter {
        canAddMoreVideos ? .any(of: [.images, .videos]) : .images
    }
    #endif

    /// Creates a new bug report draft optionally preloaded with initial attachments.
    init(
        configuration: HollerKitConfiguration? = nil,
        invocationAttachments: [HollerKitAttachment] = [],
        invokingTrigger: String = "manual",
        tempDirectoryURL: URL? = nil
    ) {
        self.invokingTrigger = invokingTrigger
        self.tempDirectoryURL = tempDirectoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("HollerKitDrafts", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        if configuration != nil || !invocationAttachments.isEmpty {
            loadInitialImagesIfNeeded(
                configuration: configuration,
                invocationAttachments: invocationAttachments
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }

    private func isDraftOwned(_ url: URL) -> Bool {
        let basePath = tempDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = basePath.hasSuffix("/") ? basePath : (basePath + "/")
        return targetPath.hasPrefix(prefix)
    }

    /// Removes all temporary video files created for this draft.
    func cleanupTempFiles() {
        for attachment in images {
            if let fileURL = attachment.videoFileURL, isDraftOwned(fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }

    /// Loads initial attachments once for the current draft when not in audio-only mode.
    func loadInitialImagesIfNeeded(
        configuration: HollerKitConfiguration?,
        invocationAttachments: [HollerKitAttachment]
    ) {
        guard !didLoadInitialImages else { return }
        didLoadInitialImages = true
        guard configuration?.isEnabled() != false else { return }
        guard !Self.isAudioOnly(configuration: configuration) else { return }
        #if canImport(UIKit)
        let configuredImages = configuration?.initialImages() ?? []
        var loaded: [BugReportImage] = []
        loaded.reserveCapacity(min(invocationAttachments.count + configuredImages.count, Self.maxAttachments))
        for attachment in invocationAttachments + configuredImages {
            guard loaded.count < Self.maxAttachments else { break }
            if let image = BugReportImage(attachment: attachment) {
                loaded.append(image)
            }
        }
        images = loaded
        nextAddedImageNumber = loaded.count + 1
        #endif
    }

    /// Returns `true` when the draft has content and is ready to submit.
    func canSubmit(configuration: HollerKitConfiguration?) -> Bool {
        guard let configuration,
              configuration.isEnabled(),
              !isSubmitting,
              !isLoadingAttachments,
              !speechCapture.isStopping,
              submissionOutcome == nil else {
            return false
        }
        if Self.isAudioOnly(configuration: configuration) {
            return speechCapture.transcript != nil
        }

        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !images.isEmpty
            || speechCapture.transcript != nil
    }

    /// Clears all draft inputs after a report has been submitted or queued so stale text never remains in the editor.
    func clearInputsAfterSubmission() {
        photoLoadGeneration &+= 1
        isLoadingAttachments = false
        attachmentStatusMessage = nil
        speechCapture.reset()
        comment = ""
        cleanupTempFiles()
        images = []
        selectedImage = nil
        nextAddedImageNumber = 1
        nextAddedVideoNumber = 1
    }

    /// Resets the draft to a clean state so the tester can file another report immediately.
    func resetForAnotherReport(
        configuration: HollerKitConfiguration?,
        invocationAttachments: [HollerKitAttachment] = []
    ) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        photoLoadGeneration &+= 1
        isLoadingAttachments = false
        attachmentStatusMessage = nil
        speechCapture.reset()
        comment = ""
        cleanupTempFiles()
        images = []
        selectedImage = nil
        nextAddedImageNumber = 1
        nextAddedVideoNumber = 1
        isSubmitting = false
        submissionStage = nil
        submissionError = nil
        submissionOutcome = nil
        didLoadInitialImages = false
        loadInitialImagesIfNeeded(
            configuration: configuration,
            invocationAttachments: invocationAttachments
        )
    }

    /// Cancels any active voice dictation and pending auto-dismiss task.
    func cancelCapture() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        photoLoadGeneration &+= 1
        isLoadingAttachments = false
        speechCapture.cancelCapture()
    }

    /// Removes the attached item with `id` from the draft and cleans up its temporary file if it is a video owned by the draft.
    func removeImage(id: UUID) {
        let removed = images.filter { $0.id == id }
        images.removeAll { $0.id == id }
        for item in removed {
            if let fileURL = item.videoFileURL, isDraftOwned(fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        if selectedImage?.id == id {
            selectedImage = nil
        }
        if images.count < Self.maxAttachments {
            attachmentStatusMessage = nil
        }
    }

    #if canImport(UIKit)
    /// Replaces an annotated attachment image in the draft (no-op for video attachments).
    func replaceImage(id: UUID, with renderedImage: UIImage) {
        guard let index = images.firstIndex(where: { $0.id == id }),
              !images[index].isVideo else { return }
        images[index].image = BugReportAttachment.normalizedImage(renderedImage)
    }

    /// Normalizes and appends `image` to the draft if the attachment cap has not been reached.
    @discardableResult
    func addImage(_ image: UIImage, title: String? = nil) -> Bool {
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return false
        }
        let resolvedTitle: String
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            resolvedTitle = trimmed
        } else {
            resolvedTitle = "Photo \(nextAddedImageNumber)"
        }
        nextAddedImageNumber += 1
        images.append(BugReportAttachment(title: resolvedTitle, image: image))
        attachmentStatusMessage = nil
        return true
    }

    /// Downsamples `data` into a `UIImage` within `maxPixelDimension` and appends it to the draft.
    @discardableResult
    func addImageData(_ data: Data, title: String? = nil) -> Bool {
        guard let decoded = BugReportAttachment.downsampledImage(from: data) else {
            attachmentStatusMessage = "Could not load the selected image."
            return false
        }
        return addImage(decoded, title: title)
    }

    /// Downsamples `data` off the main actor before appending the resulting image to the draft.
    @discardableResult
    func addImageDataOffMainActor(_ data: Data, title: String? = nil) async -> Bool {
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return false
        }
        let generation = photoLoadGeneration
        let maxDimension = Self.maxPixelDimension
        let cgImage = await Task.detached(priority: .userInitiated) {
            BugReportAttachment.downsampledCGImage(from: data, maxPixelDimension: maxDimension)
        }.value
        guard photoLoadGeneration == generation else { return false }
        if let cgImage {
            return addImage(UIImage(cgImage: cgImage, scale: 1.0, orientation: .up), title: title)
        }
        return addImageData(data, title: title)
    }

    /// Validates, optionally transcodes, generates a thumbnail for, and appends a video file at `sourceURL` to the draft.
    ///
    /// Validation order:
    /// 1. Total attachment cap (`12`) and per-report video cap (`3`).
    /// 2. Video duration (`<= 60` seconds) is checked **before** any transcoding.
    /// 3. File size is checked against `effectiveMaxVideoBytes` (server `maxVideoBytes` or 50 MB fallback).
    ///    Under-size clips are kept untouched; over-size clips are transcoded via `AVAssetExportSession` and rejected only if still over the limit.
    @discardableResult
    func addVideo(from sourceURL: URL, title: String? = nil) async -> Bool {
        let generation = photoLoadGeneration
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return false
        }
        guard canAddMoreVideos else {
            attachmentStatusMessage = "You can attach up to \(Self.maxVideoAttachments) videos per report."
            return false
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path),
              let sourceAttrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let initialSize = (sourceAttrs[.size] as? NSNumber)?.intValue,
              initialSize > 0 else {
            attachmentStatusMessage = "Could not load the selected video."
            return false
        }

        let durationSeconds: TimeInterval
        do {
            durationSeconds = try await videoDurationInspector(sourceURL)
        } catch {
            guard photoLoadGeneration == generation else { return false }
            attachmentStatusMessage = "Could not load the selected video."
            return false
        }
        guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
            return false
        }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            attachmentStatusMessage = "Could not load the selected video."
            return false
        }
        if durationSeconds > Self.maxVideoDurationSeconds {
            attachmentStatusMessage = "Videos must be 1 minute or shorter."
            return false
        }

        do {
            try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        } catch {
            attachmentStatusMessage = "Could not load the selected video."
            return false
        }

        let ext = Self.normalizedVideoExtension(for: sourceURL)
        let workingURL = tempDirectoryURL.appendingPathComponent("video-\(UUID().uuidString).\(ext)", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: workingURL.path) {
                try? FileManager.default.removeItem(at: workingURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: workingURL)
        } catch {
            attachmentStatusMessage = "Could not load the selected video."
            return false
        }

        let maxBytes = effectiveMaxVideoBytes
        var finalURL = workingURL
        var finalSize = initialSize

        if initialSize > maxBytes {
            transcodeInvocationCount += 1
            do {
                let transcodedURL = try await videoTranscoder(workingURL, tempDirectoryURL, maxBytes)
                if transcodedURL.standardizedFileURL != workingURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: workingURL)
                }
                guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                    try? FileManager.default.removeItem(at: transcodedURL)
                    return false
                }
                guard let transcodedAttrs = try? FileManager.default.attributesOfItem(atPath: transcodedURL.path),
                      let transcodedSize = (transcodedAttrs[.size] as? NSNumber)?.intValue,
                      transcodedSize > 0 else {
                    try? FileManager.default.removeItem(at: transcodedURL)
                    attachmentStatusMessage = "Could not compress the selected video."
                    return false
                }
                if transcodedSize > maxBytes {
                    try? FileManager.default.removeItem(at: transcodedURL)
                    attachmentStatusMessage = "Video exceeds the maximum size limit even after compression."
                    return false
                }
                finalURL = transcodedURL
                finalSize = transcodedSize
            } catch {
                try? FileManager.default.removeItem(at: workingURL)
                guard photoLoadGeneration == generation else { return false }
                attachmentStatusMessage = "Could not compress the selected video."
                return false
            }
        }

        let thumbnail = await videoThumbnailGenerator(finalURL) ?? BugReportAttachment.placeholderVideoThumbnail()
        guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
            try? FileManager.default.removeItem(at: finalURL)
            return false
        }
        guard canAddMoreImages else {
            try? FileManager.default.removeItem(at: finalURL)
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return false
        }
        guard canAddMoreVideos else {
            try? FileManager.default.removeItem(at: finalURL)
            attachmentStatusMessage = "You can attach up to \(Self.maxVideoAttachments) videos per report."
            return false
        }

        let resolvedTitle: String
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            resolvedTitle = trimmed
        } else {
            resolvedTitle = "Video \(nextAddedVideoNumber)"
        }
        nextAddedVideoNumber += 1

        let mimeType = Self.mimeTypeForVideoExtension(finalURL.pathExtension)
        let attachment = BugReportAttachment(
            title: resolvedTitle,
            thumbnail: thumbnail,
            videoFileURL: finalURL,
            videoMimeType: mimeType,
            durationSeconds: durationSeconds,
            fileSize: finalSize
        )
        images.append(attachment)
        attachmentStatusMessage = nil
        return true
    }

    /// Pastes one or more images from the system clipboard (or the supplied `pasteboardImages` in tests) into the draft.
    @discardableResult
    func pasteImagesFromClipboard(images pasteboardImages: [UIImage]? = nil) -> Int {
        let sourceImages: [UIImage]
        if let pasteboardImages {
            sourceImages = pasteboardImages
        } else if let allImages = UIPasteboard.general.images, !allImages.isEmpty {
            sourceImages = allImages
        } else if let singleImage = UIPasteboard.general.image {
            sourceImages = [singleImage]
        } else {
            sourceImages = []
        }

        guard !sourceImages.isEmpty else {
            attachmentStatusMessage = "No image found on the clipboard."
            return 0
        }
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return 0
        }

        var addedCount = 0
        for image in sourceImages {
            guard canAddMoreImages else {
                attachmentStatusMessage = "Attached \(addedCount) attachment\(addedCount == 1 ? "" : "s") (maximum \(Self.maxAttachments) per report)."
                return addedCount
            }
            let pastedTitle = "Pasted Image \(nextAddedImageNumber)"
            if addImage(image, title: pastedTitle) {
                addedCount += 1
            }
        }
        return addedCount
    }

    /// Pastes attachments from the supplied `[NSItemProvider]` test seam (and optional `fallbackImages`), branching dynamically between videos and images.
    @discardableResult
    func pasteImagesFromClipboard(
        itemProviders: [NSItemProvider],
        fallbackImages: [UIImage]? = nil
    ) async -> Int {
        await pasteFromClipboard(itemProviders: itemProviders, fallbackImages: fallbackImages)
    }

    /// Dynamically inspects clipboard `NSItemProvider`s to attach videos (`UTType.movie` / `UTType.video`) and images (`UTType.image`),
    /// falling back to images when a source only provides a URL or thumbnail.
    @discardableResult
    func pasteFromClipboard(
        itemProviders injectedProviders: [NSItemProvider]? = nil,
        fallbackImages: [UIImage]? = nil
    ) async -> Int {
        let providers: [NSItemProvider]
        if let injectedProviders {
            providers = injectedProviders
        } else if fallbackImages != nil {
            providers = []
        } else {
            providers = UIPasteboard.general.itemProviders
        }

        if providers.isEmpty {
            if let fallbackImages {
                return pasteImagesFromClipboard(images: fallbackImages)
            }
            if UIPasteboard.general.hasImages {
                return pasteImagesFromClipboard()
            }
            attachmentStatusMessage = "No image or video found on the clipboard."
            return 0
        }

        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return 0
        }

        let generation = photoLoadGeneration
        isLoadingAttachments = true
        defer {
            if photoLoadGeneration == generation {
                isLoadingAttachments = false
            }
        }

        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        var addedCount = 0
        var usedURLOrThumbnailFallback = false
        var sawOnlyURLWithoutMedia = false
        var fallbackImageIndex = 0
        var lastRejectionStatusMessage: String?

        for provider in providers {
            guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                return addedCount
            }
            guard canAddMoreImages else {
                attachmentStatusMessage = "Attached \(addedCount) attachment\(addedCount == 1 ? "" : "s") (maximum \(Self.maxAttachments) per report)."
                return addedCount
            }

            let movieTypeId = Self.preferredMovieTypeIdentifier(for: provider)
            let imageTypeId = Self.preferredImageTypeIdentifier(for: provider)
            let urlTypeId = Self.preferredURLTypeIdentifier(for: provider)

            if let movieTypeId {
                if let tempMovieURL = await Self.loadTemporaryFile(
                    from: provider,
                    typeIdentifier: movieTypeId,
                    into: tempDirectoryURL
                ) {
                    defer { try? FileManager.default.removeItem(at: tempMovieURL) }
                    guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                        return addedCount
                    }
                    let pastedTitle = "Pasted Video \(nextAddedVideoNumber)"
                    let didAddVideo = await addVideo(from: tempMovieURL, title: pastedTitle)
                    guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                        return addedCount
                    }
                    if didAddVideo {
                        addedCount += 1
                    } else if let status = attachmentStatusMessage {
                        lastRejectionStatusMessage = status
                    }
                    continue
                } else {
                    guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                        return addedCount
                    }
                    let loadedImage = await Self.loadImage(from: provider, imageTypeIdentifier: imageTypeId)
                    guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                        return addedCount
                    }
                    if let image = loadedImage ?? Self.nextFallbackImage(from: fallbackImages, index: &fallbackImageIndex) {
                        let pastedTitle = "Pasted Image \(nextAddedImageNumber)"
                        if addImage(image, title: pastedTitle) {
                            addedCount += 1
                            usedURLOrThumbnailFallback = true
                        }
                        continue
                    }
                }
            }

            if let urlTypeId {
                let loadedURL = await Self.loadURL(from: provider, typeIdentifier: urlTypeId)
                guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                    return addedCount
                }
                if let loadedURL,
                   loadedURL.isFileURL,
                   FileManager.default.fileExists(atPath: loadedURL.path),
                   Self.isMovieFileURL(loadedURL) {
                    let pastedTitle = "Pasted Video \(nextAddedVideoNumber)"
                    let didAddVideo = await addVideo(from: loadedURL, title: pastedTitle)
                    guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                        return addedCount
                    }
                    if didAddVideo {
                        addedCount += 1
                    } else if let status = attachmentStatusMessage {
                        lastRejectionStatusMessage = status
                    }
                    continue
                }

                let loadedImage = await Self.loadImage(from: provider, imageTypeIdentifier: imageTypeId)
                guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                    return addedCount
                }
                if let image = loadedImage ?? Self.nextFallbackImage(from: fallbackImages, index: &fallbackImageIndex) {
                    let pastedTitle = "Pasted Image \(nextAddedImageNumber)"
                    if addImage(image, title: pastedTitle) {
                        addedCount += 1
                        usedURLOrThumbnailFallback = true
                    }
                } else {
                    sawOnlyURLWithoutMedia = true
                }
                continue
            }

            if imageTypeId != nil || provider.canLoadObject(ofClass: UIImage.self) {
                let loadedImage = await Self.loadImage(from: provider, imageTypeIdentifier: imageTypeId)
                guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                    return addedCount
                }
                if let image = loadedImage ?? Self.nextFallbackImage(from: fallbackImages, index: &fallbackImageIndex) {
                    let pastedTitle = "Pasted Image \(nextAddedImageNumber)"
                    if addImage(image, title: pastedTitle) {
                        addedCount += 1
                    }
                }
                continue
            }
        }

        guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
            return addedCount
        }

        if addedCount == 0, let fallbackImages, !fallbackImages.isEmpty {
            let count = pasteImagesFromClipboard(images: fallbackImages)
            if count > 0, sawOnlyURLWithoutMedia {
                attachmentStatusMessage = "Clipboard only contained a link or thumbnail; attached image preview instead of video."
            }
            return count
        }

        if usedURLOrThumbnailFallback {
            attachmentStatusMessage = "Clipboard only contained a link or thumbnail; attached image preview instead of video."
        } else if let lastRejectionStatusMessage {
            attachmentStatusMessage = lastRejectionStatusMessage
        } else if addedCount == 0 {
            if sawOnlyURLWithoutMedia {
                attachmentStatusMessage = "Clipboard only contained a link, not a video file or image."
            } else {
                attachmentStatusMessage = "No image or video found on the clipboard."
            }
        }

        return addedCount
    }

    private nonisolated static func preferredMovieTypeIdentifier(for provider: NSItemProvider) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            if let utType = UTType(identifier),
               (utType.conforms(to: .movie) || utType.conforms(to: .video) || utType == .mpeg4Movie || utType == .quickTimeMovie) {
                return identifier
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return UTType.movie.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
            return UTType.video.identifier
        }
        return nil
    }

    private nonisolated static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            if let utType = UTType(identifier), utType.conforms(to: .image) {
                return identifier
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return UTType.image.identifier
        }
        return nil
    }

    private nonisolated static func preferredURLTypeIdentifier(for provider: NSItemProvider) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            if let utType = UTType(identifier), (utType.conforms(to: .url) || utType.conforms(to: .fileURL)) {
                return identifier
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return UTType.url.identifier
        }
        return nil
    }

    private nonisolated static func isMovieFileURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            return true
        }
        if let utType = UTType(filenameExtension: ext) {
            return utType.conforms(to: .movie) || utType.conforms(to: .video)
        }
        return false
    }

    private nonisolated static func normalizedVideoExtension(for url: URL) -> String {
        let lower = url.pathExtension.lowercased()
        if lower == "mp4" {
            return "mp4"
        }
        return "mov"
    }

    private nonisolated static func mimeTypeForVideoExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower == "mp4" {
            return "video/mp4"
        }
        return "video/quicktime"
    }

    private static func nextFallbackImage(from fallbackImages: [UIImage]?, index: inout Int) -> UIImage? {
        guard let fallbackImages, index < fallbackImages.count else { return nil }
        let img = fallbackImages[index]
        index += 1
        return img
    }

    private static func loadTemporaryFile(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directoryURL: URL
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { fileURL, _ in
                guard let fileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                    let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension
                    let copiedURL = directoryURL.appendingPathComponent("paste-\(UUID().uuidString).\(ext)", isDirectory: false)
                    try FileManager.default.copyItem(at: fileURL, to: copiedURL)
                    continuation.resume(returning: copiedURL)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadImage(
        from provider: NSItemProvider,
        imageTypeIdentifier: String?
    ) async -> UIImage? {
        let typeId = imageTypeIdentifier ?? UTType.image.identifier
        if provider.hasItemConformingToTypeIdentifier(typeId) {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data, let image = BugReportAttachment.downsampledImage(from: data) {
                return image
            }
        }
        if provider.canLoadObject(ofClass: UIImage.self) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        return nil
    }

    private static func loadURL(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data {
                if let url = URL(dataRepresentation: data, relativeTo: nil) {
                    return url
                }
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: str) {
                    return url
                }
            }
        }
        if provider.canLoadObject(ofClass: NSURL.self) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: (object as? NSURL) as URL?)
                }
            }
        }
        return nil
    }
    #endif

    /// Submits the current draft or queues it in the local outbox, clearing inputs upon completion.
    func submit(
        configuration: HollerKitConfiguration?,
        breadcrumbs: BreadcrumbStore,
        outboxStore: OutboxStore,
        onDisabled: (() -> Void)? = nil,
        onAutoDismiss: (() -> Void)? = nil,
        onAutoReset: (() -> Void)? = nil
    ) async {
        guard !isSubmitting else { return }
        guard let configuration else {
            submissionError = "HollerKit has not been configured."
            return
        }
        guard configuration.isEnabled() else {
            HollerKit.reconcileEnablement()
            onDisabled?()
            return
        }

        autoDismissTask?.cancel()
        autoDismissTask = nil
        submissionOutcome = nil
        submissionError = nil
        isSubmitting = true
        submissionStage = .preparing
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

            let audioOnly = Self.isAudioOnly(configuration: configuration)
            if !audioOnly {
                comment = speechCapture.consumeTranscriptForCommentMerge(into: comment)
            }

            let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedComment = trimmedComment.isEmpty ? nil : trimmedComment
            let attachmentsToUpload = audioOnly ? [] : imageAttachments()
            let transcriptToSubmit = speechCapture.transcript

            if audioOnly {
                guard transcriptToSubmit != nil else { return }
            } else {
                guard normalizedComment != nil || !attachmentsToUpload.isEmpty || transcriptToSubmit != nil else {
                    return
                }
            }

            var reportMetadata = MetadataCollector.collect(extra: configuration.metadata())
            reportMetadata["invocation"] = invokingTrigger

            let payload = HollerKitReportPayload(
                inputMode: configuration.inputMode,
                comment: audioOnly ? nil : normalizedComment,
                transcript: transcriptToSubmit,
                metadata: reportMetadata,
                breadcrumbs: configuration.captureBreadcrumbs ? breadcrumbs.snapshot() : [],
                images: attachmentsToUpload
            )
            let (request, attachments) = payload.toFeedbackSubmission()
            submissionStage = attachments.isEmpty
                ? .sending
                : .uploadingAttachments(count: attachments.count)
            let client = APIClient(configuration: configuration)
            let outcome = try await outboxStore.submit(
                request: request,
                attachments: attachments,
                using: client,
                onProgress: { [weak self] stage in
                    await MainActor.run {
                        self?.submissionStage = stage
                    }
                }
            )

            clearInputsAfterSubmission()
            submissionOutcome = outcome
            SubmissionHaptics.notify(for: outcome)

            if case .sent = outcome {
                let afterSend = configuration.afterSend
                let executeAfterSendAction = { [weak self] in
                    guard let self else { return }
                    switch afterSend {
                    case .stayOpen:
                        self.resetForAnotherReport(
                            configuration: configuration,
                            invocationAttachments: []
                        )
                        onAutoReset?()
                    case .close:
                        onAutoDismiss?()
                    }
                }

                if let override = autoDismissDelaySeconds {
                    // Internal testing override: delay <= 0 completely disables auto-dismiss/reset
                    // so tests can inspect .sent outcome synchronously without background tasks.
                    if override > 0 {
                        let delayNanoseconds = UInt64(override * 1_000_000_000)
                        autoDismissTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: delayNanoseconds)
                            guard !Task.isCancelled, let self, self.submissionOutcome != nil else { return }
                            executeAfterSendAction()
                        }
                    }
                } else if afterSend.delay <= 0 {
                    // Configured with zero delay: perform reset or dismissal immediately.
                    executeAfterSendAction()
                } else {
                    let delayNanoseconds = UInt64(afterSend.delay * 1_000_000_000)
                    autoDismissTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                        guard !Task.isCancelled, let self, self.submissionOutcome != nil else { return }
                        executeAfterSendAction()
                    }
                }
            }
        } catch {
            submissionError = error.localizedDescription
            SubmissionHaptics.notifyError()
        }
    }

    /// Returns whether `configuration` is set to `.audioOnly`.
    static func isAudioOnly(configuration: HollerKitConfiguration?) -> Bool {
        guard let configuration else { return false }
        if case .audioOnly = configuration.inputMode { return true }
        return false
    }

    /// Converts draft `BugReportImage` items into size-bounded `HollerKitAttachment` payloads.
    func imageAttachments() -> [HollerKitAttachment] {
        #if canImport(UIKit)
        return Array(images.prefix(Self.maxAttachments)).enumerated().compactMap { index, image in
            image.encodedAttachment(index: index)
        }
        #else
        return []
        #endif
    }
}

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
    #if canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif
    @State private var hasClipboardImage = false

    private var speechCapture: SpeechCaptureController {
        draft.speechCapture
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
                            if hasClipboardImage {
                                Button {
                                    Task { @MainActor in
                                        _ = await draft.pasteFromClipboard()
                                        refreshClipboardImageAvailability()
                                    }
                                } label: {
                                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                                }
                                .disabled(draft.isSubmitting || draft.isLoadingAttachments || !draft.canAddMoreImages)
                                .accessibilityIdentifier("HollerKitPasteImageButton")
                            }
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
            refreshClipboardImageAvailability()
            if let externalDraft {
                draft = externalDraft
            }
            draft.resetForAnotherReport(
                configuration: configuration,
                invocationAttachments: invocationAttachments
            )
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

    /// Updates `hasClipboardImage` from the system pasteboard without reading clipboard item payloads until tapped.
    @MainActor
    private func refreshClipboardImageAvailability() {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages || pasteboard.hasURLs {
            hasClipboardImage = true
            return
        }
        hasClipboardImage = pasteboard.types.contains { identifier in
            guard let utType = UTType(identifier) else { return false }
            return utType.conforms(to: .movie)
                || utType.conforms(to: .video)
                || utType.conforms(to: .image)
                || utType.conforms(to: .url)
        }
        #else
        hasClipboardImage = false
        #endif
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

/// Full-sheet progress and post-submission confirmation overlay shared by bug reports and quest runs.
struct SubmissionFeedbackOverlayView: View {
    var isSubmitting: Bool
    var stage: SubmissionProgressStage?
    var outcome: OutboxSubmissionOutcome?
    var sentTitle: String
    var onDone: () -> Void
    var onSendAnother: (() -> Void)?

    @State private var animateBadge = false

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

                    Text((stage ?? .sending).title)
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

    /// Transcodes the video at `sourceURL` into `outputDirectoryURL` using `AVAssetExportSession` with a 720p/medium preset and `fileLengthLimit`.
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

/// Coordinates live voice dictation for bug report and quest result sheets.
@Observable
@MainActor
final class SpeechCaptureController {
    static let maxCommentCharacters = 20_000

    var isCapturing = false
    var isStopping = false
    var transcript: HollerKitTranscript?
    var errorMessage: String?
    var partialTranscript = ""

    let capture = SpeechNoteCapture()
    @ObservationIgnored
    private var autoStopTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeStopTask: Task<Void, Never>?
    @ObservationIgnored
    private var startGeneration: UInt64 = 0
    @ObservationIgnored
    private var consumedTranscriptForCommentMerge: HollerKitTranscript?

    init() {
        capture.onStateChange = { [weak self] in
            self?.handleCaptureStateChange()
        }
    }

    /// Merges `transcriptText` into `existingComment` while respecting the 20,000 UTF-16 unit server limit.
    static func mergeTranscript(_ transcriptText: String, into existingComment: String) -> String {
        let trimmedTranscript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return existingComment }
        let trimmedExisting = existingComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else {
            return trimmedTranscript.utf16.count <= maxCommentCharacters ? trimmedTranscript : existingComment
        }
        if trimmedExisting.hasSuffix(trimmedTranscript) {
            return existingComment
        }
        let combined = "\(trimmedExisting)\n\(trimmedTranscript)"
        guard combined.utf16.count <= maxCommentCharacters else {
            return existingComment
        }
        return combined
    }

    /// Merges the latest completed transcript into `existingComment` at most once so subsequent user edits are preserved.
    func consumeTranscriptForCommentMerge(into existingComment: String) -> String {
        guard let current = transcript, current != consumedTranscriptForCommentMerge else {
            return existingComment
        }
        consumedTranscriptForCommentMerge = current
        return Self.mergeTranscript(current.text, into: existingComment)
    }

    /// Toggles between starting and stopping live dictation.
    func toggle(configuration: HollerKitAudioConfiguration) async {
        guard !isStopping else { return }
        errorMessage = nil

        if isCapturing {
            await stop(configuration: configuration)
        } else {
            await start(configuration: configuration)
        }
    }

    /// Cancels any active session and starts a fresh dictation attempt.
    func retry(configuration: HollerKitAudioConfiguration) async {
        guard !isStopping else { return }
        cancelCapture()
        errorMessage = nil
        await start(configuration: configuration)
    }

    /// Finalizes an in-progress dictation session or awaits an in-flight stop prior to form submission.
    func finalizeIfCapturing() async {
        await performStop()
    }

    /// Cancels any pending or active dictation session immediately.
    func cancelCapture() {
        startGeneration &+= 1
        autoStopTask?.cancel()
        autoStopTask = nil
        activeStopTask?.cancel()
        activeStopTask = nil
        capture.cancel()
        partialTranscript = ""
        isStopping = false
        isCapturing = false
    }

    /// Cancels any active session and clears all captured transcript and error state.
    func reset() {
        cancelCapture()
        transcript = nil
        consumedTranscriptForCommentMerge = nil
        errorMessage = nil
    }

    /// Starts a new dictation session with the given audio configuration.
    private func start(configuration: HollerKitAudioConfiguration) async {
        startGeneration &+= 1
        let generation = startGeneration
        do {
            transcript = nil
            consumedTranscriptForCommentMerge = nil
            partialTranscript = ""
            try await capture.start(options: SpeechTranscriberOptions(
                requireOnDeviceRecognition: configuration.requiresOnDeviceTranscription
            ))
            guard !Task.isCancelled, startGeneration == generation else {
                capture.cancel()
                return
            }
            isStopping = false
            isCapturing = true
            handleCaptureStateChange()
            scheduleAutoStop(after: configuration.maxDuration)
        } catch is CancellationError {
            isStopping = false
            isCapturing = false
        } catch {
            guard startGeneration == generation else { return }
            isStopping = false
            isCapturing = false
            recordError(error)
        }
    }

    /// Stops the active dictation session and stores the resulting transcript.
    private func stop(configuration: HollerKitAudioConfiguration) async {
        await performStop()
    }

    /// Stops the active dictation session or awaits an already-running stop operation.
    private func performStop() async {
        if let existingStopTask = activeStopTask {
            await existingStopTask.value
            return
        }
        guard isCapturing || isStopping || capture.isCapturing || capture.isStopping else { return }

        autoStopTask?.cancel()
        autoStopTask = nil
        errorMessage = nil
        isStopping = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeStopTask = nil }
            do {
                let completedTranscript = try await self.capture.stopAsync()
                self.transcript = completedTranscript
                self.partialTranscript = ""
                self.isStopping = false
                self.isCapturing = false
            } catch is CancellationError {
                self.partialTranscript = ""
                self.isStopping = false
                self.isCapturing = false
            } catch {
                if !self.capture.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.partialTranscript = self.capture.transcriptText
                } else {
                    self.partialTranscript = ""
                }
                self.isStopping = false
                self.isCapturing = false
                self.recordError(error)
            }
        }
        activeStopTask = task
        await task.value
    }

    /// Schedules an automatic stop after `maxDuration` seconds.
    private func scheduleAutoStop(after maxDuration: TimeInterval) {
        autoStopTask?.cancel()
        guard maxDuration > 0 else { return }

        autoStopTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(maxDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.isCapturing, !self.isStopping else { return }
            await self.performStop()
        }
    }

    /// Synchronizes partial transcription updates and mid-capture errors reactively from `capture`.
    private func handleCaptureStateChange() {
        guard isCapturing || isStopping else { return }
        if let failure = capture.lastError, !capture.isCapturing {
            autoStopTask?.cancel()
            autoStopTask = nil
            if !capture.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                partialTranscript = capture.transcriptText
            } else {
                partialTranscript = ""
            }
            isStopping = false
            isCapturing = false
            recordErrorMessage(failure)
            return
        }
        if capture.isCapturing {
            partialTranscript = capture.transcriptText
        }
    }

    /// Formats `error`, assigns `errorMessage`, and records a diagnostic breadcrumb.
    private func recordError(_ error: Error) {
        recordErrorMessage(SpeechNoteCaptureError.describeError(error))
    }

    /// Assigns `described` to `errorMessage` and records a diagnostic breadcrumb.
    private func recordErrorMessage(_ described: String) {
        errorMessage = described
        HollerKit.breadcrumb(
            "Speech capture failed: \(described)",
            category: "speech_error",
            metadata: ["error": described]
        )
    }
}

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
