import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#endif

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
    var hasClipboardImage = false
    var attachmentStatusMessage: String?
    var isSubmitting = false
    var submissionStage: SubmissionProgressStage?
    var submissionError: String?
    var submissionOutcome: OutboxSubmissionOutcome?

    /// Human-readable headline for the active bug report submission stage, if submitting.
    var submissionProgressTitle: String? {
        submissionStage?.title(for: .bugReport)
    }

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
    var pasteboard: UIPasteboard = .general
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

    /// Returns the number of image (non-video) attachments currently in the draft.
    var imageCount: Int {
        images.filter { !$0.isVideo }.count
    }

    /// Returns the effective maximum number of image attachments allowed per report, preferring the server-advertised `maxImages` limit.
    var effectiveMaxImages: Int {
        if let serverLimit = HollerKit.quests.serverMaxImages, serverLimit > 0 {
            return min(serverLimit, Self.maxAttachments)
        }
        return Self.maxAttachments
    }

    /// Returns `true` when additional image attachments can be added to the draft.
    var canAddMoreImages: Bool {
        images.count < Self.maxAttachments && imageCount < effectiveMaxImages
    }

    /// Returns the number of remaining image attachment slots before hitting `effectiveMaxImages` or `maxAttachments`.
    var remainingImageSlots: Int {
        min(max(0, Self.maxAttachments - images.count), max(0, effectiveMaxImages - imageCount))
    }

    /// Returns the number of video attachments currently in the draft.
    var videoCount: Int {
        images.filter(\.isVideo).count
    }

    /// Returns `true` when additional video attachments can be added (fewer than 3 videos and fewer than 12 total attachments).
    var canAddMoreVideos: Bool {
        images.count < Self.maxAttachments && videoCount < Self.maxVideoAttachments
    }

    /// Returns the number of remaining video attachment slots before hitting `maxVideoAttachments` or `maxAttachments`.
    var remainingVideoSlots: Int {
        min(max(0, Self.maxAttachments - images.count), max(0, Self.maxVideoAttachments - videoCount))
    }

    /// Returns the effective maximum image size in bytes, preferring the server-reported limit before falling back to 10 MB.
    var effectiveMaxImageBytes: Int {
        if let serverLimit = HollerKit.quests.serverMaxImageBytes, serverLimit > 0 {
            return serverLimit
        }
        return Self.maxAttachmentBytes
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
        _ = refreshClipboardImageAvailability()
        if configuration != nil || !invocationAttachments.isEmpty {
            loadInitialImagesIfNeeded(
                configuration: configuration,
                invocationAttachments: invocationAttachments
            )
        }
    }

    /// Updates `hasClipboardImage` from the pasteboard using a type-only check without reading item payloads.
    @discardableResult
    func refreshClipboardImageAvailability() -> Bool {
        #if canImport(UIKit)
        let available = ClipboardAttachmentAvailability.hasAttachableItem(pasteboard: pasteboard)
        hasClipboardImage = available
        return available
        #else
        hasClipboardImage = false
        return false
        #endif
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
        let activeMaxImages = effectiveMaxImages
        var loaded: [BugReportImage] = []
        loaded.reserveCapacity(min(invocationAttachments.count + configuredImages.count, Self.maxAttachments))
        var loadedImageCount = 0
        var loadedVideoCount = 0
        for attachment in invocationAttachments + configuredImages {
            guard loaded.count < Self.maxAttachments else { break }
            if let image = BugReportImage(attachment: attachment) {
                if image.isVideo {
                    guard loadedVideoCount < Self.maxVideoAttachments else { continue }
                    loadedVideoCount += 1
                } else {
                    guard loadedImageCount < activeMaxImages else { continue }
                    loadedImageCount += 1
                }
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
        _ = refreshClipboardImageAvailability()
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
        guard images.count < Self.maxAttachments else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return false
        }
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(effectiveMaxImages) images per report."
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
        guard images.count < Self.maxAttachments else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) attachments per report."
            return false
        }
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(effectiveMaxImages) images per report."
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
        guard images.count < Self.maxAttachments else {
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
        guard images.count < Self.maxAttachments else {
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
        } else if let allImages = pasteboard.images, !allImages.isEmpty {
            sourceImages = allImages
        } else if let singleImage = pasteboard.image {
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
            providers = pasteboard.itemProviders
        }

        if providers.isEmpty {
            if let fallbackImages {
                return pasteImagesFromClipboard(images: fallbackImages)
            }
            if pasteboard.hasImages {
                return pasteImagesFromClipboard()
            }
            attachmentStatusMessage = "No image or video found on the clipboard."
            return 0
        }

        guard images.count < Self.maxAttachments, canAddMoreImages || canAddMoreVideos else {
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
            guard images.count < Self.maxAttachments, canAddMoreImages || canAddMoreVideos else {
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

    nonisolated static func preferredMovieTypeIdentifier(for provider: NSItemProvider) -> String? {
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

    nonisolated static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
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

    nonisolated static func preferredURLTypeIdentifier(for provider: NSItemProvider) -> String? {
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

    nonisolated static func isMovieFileURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            return true
        }
        if let utType = UTType(filenameExtension: ext) {
            return utType.conforms(to: .movie) || utType.conforms(to: .video)
        }
        return false
    }

    nonisolated static func normalizedVideoExtension(for url: URL) -> String {
        let lower = url.pathExtension.lowercased()
        if lower == "mp4" {
            return "mp4"
        }
        return "mov"
    }

    nonisolated static func mimeTypeForVideoExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower == "mp4" {
            return "video/mp4"
        }
        return "video/quicktime"
    }

    nonisolated static func nextFallbackImage(from fallbackImages: [UIImage]?, index: inout Int) -> UIImage? {
        guard let fallbackImages, index < fallbackImages.count else { return nil }
        let img = fallbackImages[index]
        index += 1
        return img
    }

    private nonisolated static func startLoadFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directoryURL: URL,
        continuation: CheckedContinuation<URL?, Never>
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { @Sendable fileURL, _ in
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

    private nonisolated static func startLoadDataRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        continuation: CheckedContinuation<Data?, Never>
    ) {
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { @Sendable data, _ in
            continuation.resume(returning: data)
        }
    }

    private nonisolated static func startLoadUIImageObject(
        from provider: NSItemProvider,
        continuation: CheckedContinuation<UIImage?, Never>
    ) {
        _ = provider.loadObject(ofClass: UIImage.self) { @Sendable object, _ in
            if let image = object as? UIImage {
                continuation.resume(returning: image)
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    private nonisolated static func startLoadNSURLObject(
        from provider: NSItemProvider,
        continuation: CheckedContinuation<URL?, Never>
    ) {
        _ = provider.loadObject(ofClass: NSURL.self) { @Sendable object, _ in
            continuation.resume(returning: (object as? NSURL) as URL?)
        }
    }

    static func loadTemporaryFile(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directoryURL: URL
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            startLoadFileRepresentation(
                from: provider,
                typeIdentifier: typeIdentifier,
                into: directoryURL,
                continuation: continuation
            )
        }
    }

    static func loadImage(
        from provider: NSItemProvider,
        imageTypeIdentifier: String?
    ) async -> UIImage? {
        let typeId = imageTypeIdentifier ?? UTType.image.identifier
        if provider.hasItemConformingToTypeIdentifier(typeId) {
            let data: Data? = await withCheckedContinuation { continuation in
                startLoadDataRepresentation(
                    from: provider,
                    typeIdentifier: typeId,
                    continuation: continuation
                )
            }
            if let data, let image = BugReportAttachment.downsampledImage(from: data) {
                return image
            }
        }
        if provider.canLoadObject(ofClass: UIImage.self) {
            return await withCheckedContinuation { continuation in
                startLoadUIImageObject(from: provider, continuation: continuation)
            }
        }
        return nil
    }

    static func loadURL(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                startLoadDataRepresentation(
                    from: provider,
                    typeIdentifier: typeIdentifier,
                    continuation: continuation
                )
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
                startLoadNSURLObject(from: provider, continuation: continuation)
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
            if !audioOnly,
               trimmedComment.utf16.count > SpeechCaptureController.maxCommentCharacters
                || trimmedComment.count > SpeechCaptureController.maxCommentCharacters {
                submissionError = "Comments must be \(SpeechCaptureController.maxCommentCharacters) characters or fewer."
                SubmissionHaptics.notifyError()
                return
            }
            if !audioOnly {
                let activeMaxImages = effectiveMaxImages
                if imageCount > activeMaxImages {
                    submissionError = "You can attach up to \(activeMaxImages) images per report."
                    SubmissionHaptics.notifyError()
                    return
                }
            }
            let normalizedComment = trimmedComment.isEmpty ? nil : trimmedComment
            if !audioOnly {
                guard await prepareVideoAttachmentsForSubmission() else {
                    SubmissionHaptics.notifyError()
                    return
                }
            }
            let attachmentsToUpload = audioOnly ? [] : imageAttachments()
            if !audioOnly, attachmentsToUpload.count != min(images.count, Self.maxAttachments) {
                submissionError = "Some attachments could not be prepared within the server limits. Remove them and try again."
                SubmissionHaptics.notifyError()
                return
            }
            let transcriptToSubmit = speechCapture.transcript
            if let transcriptText = transcriptToSubmit?.text,
               transcriptText.utf16.count > SpeechCaptureController.maxCommentCharacters
                || transcriptText.count > SpeechCaptureController.maxCommentCharacters {
                submissionError = "Voice note transcripts must be \(SpeechCaptureController.maxCommentCharacters) characters or fewer."
                SubmissionHaptics.notifyError()
                return
            }

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

    /// Validates and prepares any video attachments (such as preloaded videos) against the active duration and byte limits before encoding.
    private func prepareVideoAttachmentsForSubmission() async -> Bool {
        #if canImport(UIKit)
        let maxBytes = effectiveMaxVideoBytes
        for index in images.indices where images[index].isVideo {
            guard let sourceURL = images[index].videoFileURL,
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  let sourceAttrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                  let currentSize = (sourceAttrs[.size] as? NSNumber)?.intValue,
                  currentSize > 0 else {
                submissionError = "Could not load the attached video."
                return false
            }

            let durationSeconds: TimeInterval
            if let existingDuration = images[index].videoDurationSeconds, existingDuration.isFinite, existingDuration > 0 {
                durationSeconds = existingDuration
            } else {
                do {
                    durationSeconds = try await videoDurationInspector(sourceURL)
                } catch {
                    submissionError = "Could not load the attached video."
                    return false
                }
            }
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                submissionError = "Could not load the attached video."
                return false
            }
            if durationSeconds > Self.maxVideoDurationSeconds {
                submissionError = "Videos must be 1 minute or shorter."
                return false
            }
            images[index].videoDurationSeconds = durationSeconds

            if currentSize > maxBytes {
                do {
                    try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
                    let ext = Self.normalizedVideoExtension(for: sourceURL)
                    let workingURL = tempDirectoryURL.appendingPathComponent("video-\(UUID().uuidString).\(ext)", isDirectory: false)
                    if FileManager.default.fileExists(atPath: workingURL.path) {
                        try? FileManager.default.removeItem(at: workingURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: workingURL)
                    transcodeInvocationCount += 1
                    do {
                        let transcodedURL = try await videoTranscoder(workingURL, tempDirectoryURL, maxBytes)
                        if transcodedURL.standardizedFileURL != workingURL.standardizedFileURL {
                            try? FileManager.default.removeItem(at: workingURL)
                        }
                        guard let transcodedAttrs = try? FileManager.default.attributesOfItem(atPath: transcodedURL.path),
                              let transcodedSize = (transcodedAttrs[.size] as? NSNumber)?.intValue,
                              transcodedSize > 0 else {
                            try? FileManager.default.removeItem(at: transcodedURL)
                            submissionError = "Could not compress the selected video."
                            return false
                        }
                        if transcodedSize > maxBytes {
                            try? FileManager.default.removeItem(at: transcodedURL)
                            submissionError = "Video exceeds the maximum size limit even after compression."
                            return false
                        }
                        if isDraftOwned(sourceURL) && sourceURL.standardizedFileURL != transcodedURL.standardizedFileURL {
                            try? FileManager.default.removeItem(at: sourceURL)
                        }
                        images[index].videoFileURL = transcodedURL
                        images[index].videoFileSize = transcodedSize
                        images[index].videoMimeType = Self.mimeTypeForVideoExtension(transcodedURL.pathExtension)
                    } catch {
                        try? FileManager.default.removeItem(at: workingURL)
                        submissionError = "Could not compress the selected video."
                        return false
                    }
                } catch {
                    submissionError = "Could not load the attached video."
                    return false
                }
            }
        }
        #endif
        return true
    }

    /// Converts draft `BugReportImage` items into size-bounded `HollerKitAttachment` payloads.
    func imageAttachments() -> [HollerKitAttachment] {
        #if canImport(UIKit)
        let maxImageBytes = effectiveMaxImageBytes
        let maxVideoBytes = effectiveMaxVideoBytes
        return Array(images.prefix(Self.maxAttachments)).enumerated().compactMap { index, image in
            image.encodedAttachment(index: index, maxBytes: maxImageBytes, maxVideoBytes: maxVideoBytes)
        }
        #else
        return []
        #endif
    }
}
