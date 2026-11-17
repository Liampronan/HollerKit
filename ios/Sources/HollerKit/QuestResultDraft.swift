import Foundation
import ImageIO
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Holds the mutable form state and submission lifecycle for completing an active quest run.
@Observable
@MainActor
final class QuestResultDraft {
    nonisolated static let maxAttachments = BugReportDraft.maxAttachments
    nonisolated static let maxVideoAttachments = BugReportDraft.maxVideoAttachments
    nonisolated static let maxAttachmentBytes = BugReportDraft.maxAttachmentBytes
    nonisolated static let defaultMaxVideoBytes = BugReportDraft.defaultMaxVideoBytes
    nonisolated static let maxVideoDurationSeconds = BugReportDraft.maxVideoDurationSeconds
    nonisolated static let preferredPNGMaxBytes = BugReportDraft.preferredPNGMaxBytes
    nonisolated static let maxPixelDimension: CGFloat = BugReportDraft.maxPixelDimension

    let id = UUID()
    var selectedResult: QuestResult = .pass
    var comment: String = ""
    var images: [BugReportImage] = []
    var selectedImage: BugReportImage? {
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
    var submittedSessionId: UUID?
    private(set) var submittedSessionSnapshot: ActiveQuestSession?
    private(set) var submittedCommentSnapshot: String = ""
    private(set) var submittedImagesSnapshot: [BugReportImage] = []

    /// Human-readable headline for the active quest result submission stage, if submitting.
    var submissionProgressTitle: String? {
        submissionStage?.title(for: .questResult)
    }

    let speechCapture = SpeechCaptureController()
    @ObservationIgnored
    var autoDismissDelaySeconds: TimeInterval? = 1.2
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
    private var nextAddedImageNumber = 1
    @ObservationIgnored
    private var nextAddedVideoNumber = 1
    @ObservationIgnored
    private var autoDismissTask: Task<Void, Never>?

    /// Returns the number of image (non-video) attachments currently in the draft.
    var imageCount: Int {
        images.filter { !$0.isVideo }.count
    }

    /// Returns the effective maximum number of image attachments allowed per quest run, preferring the server-advertised `maxImages` limit.
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

    /// Returns the number of remaining attachment slots before hitting `effectiveMaxImages` or `maxAttachments`.
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

    /// Creates a new quest result draft with optional initial outcome and comment.
    init(
        initialResult: QuestResult = .pass,
        initialComment: String = "",
        tempDirectoryURL: URL? = nil
    ) {
        self.selectedResult = initialResult
        self.comment = initialComment
        self.tempDirectoryURL = tempDirectoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("HollerKitQuestDrafts", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        _ = refreshClipboardImageAvailability()
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

    /// Clears draft inputs after successful submission.
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

    /// Cancels any active voice dictation and pending auto-dismiss task.
    func cancelCapture() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        photoLoadGeneration &+= 1
        isLoadingAttachments = false
        speechCapture.cancelCapture()
    }

    /// Removes the attached image with `id` from the draft.
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
        images[index].image = BugReportImage.normalizedImage(renderedImage)
    }

    /// Normalizes and appends `image` to the draft if the attachment cap has not been reached.
    @discardableResult
    func addImage(_ image: UIImage, title: String? = nil) -> Bool {
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) photos per quest."
            return false
        }
        let resolvedTitle: String
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            resolvedTitle = trimmed
        } else {
            resolvedTitle = "Photo \(nextAddedImageNumber)"
        }
        nextAddedImageNumber += 1
        images.append(BugReportImage(title: resolvedTitle, image: image))
        attachmentStatusMessage = nil
        return true
    }

    /// Downsamples `data` into a `UIImage` within `maxPixelDimension` and appends it to the draft.
    @discardableResult
    func addImageData(_ data: Data, title: String? = nil) -> Bool {
        guard let decoded = BugReportImage.downsampledImage(from: data) else {
            attachmentStatusMessage = "Could not load the selected image."
            return false
        }
        return addImage(decoded, title: title)
    }

    /// Downsamples `data` off the main actor before appending the resulting image to the draft.
    @discardableResult
    func addImageDataOffMainActor(_ data: Data, title: String? = nil) async -> Bool {
        guard canAddMoreImages else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) photos per quest."
            return false
        }
        let generation = photoLoadGeneration
        let maxDimension = Self.maxPixelDimension
        let cgImage = await Task.detached(priority: .userInitiated) {
            BugReportImage.downsampledCGImage(from: data, maxPixelDimension: maxDimension)
        }.value
        guard photoLoadGeneration == generation else { return false }
        if let cgImage {
            return addImage(UIImage(cgImage: cgImage, scale: 1.0, orientation: .up), title: title)
        }
        return addImageData(data, title: title)
    }

    /// Validates, optionally transcodes, generates a thumbnail for, and appends a video file at `sourceURL` to the draft.
    @discardableResult
    func addVideo(from sourceURL: URL, title: String? = nil) async -> Bool {
        let generation = photoLoadGeneration
        guard images.count < Self.maxAttachments else {
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) photos per quest."
            return false
        }
        guard canAddMoreVideos else {
            attachmentStatusMessage = "You can attach up to \(Self.maxVideoAttachments) videos per quest."
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

        let ext = BugReportDraft.normalizedVideoExtension(for: sourceURL)
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
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) photos per quest."
            return false
        }
        guard canAddMoreVideos else {
            try? FileManager.default.removeItem(at: finalURL)
            attachmentStatusMessage = "You can attach up to \(Self.maxVideoAttachments) videos per quest."
            return false
        }

        let resolvedTitle: String
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            resolvedTitle = trimmed
        } else {
            resolvedTitle = "Video \(nextAddedVideoNumber)"
        }
        nextAddedVideoNumber += 1

        let mimeType = BugReportDraft.mimeTypeForVideoExtension(finalURL.pathExtension)
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
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) photos per quest."
            return 0
        }

        var addedCount = 0
        for image in sourceImages {
            guard canAddMoreImages else {
                attachmentStatusMessage = "Attached \(addedCount) photo\(addedCount == 1 ? "" : "s") (maximum \(Self.maxAttachments) per quest)."
                return addedCount
            }
            let pastedTitle = "Pasted Image \(nextAddedImageNumber)"
            if addImage(image, title: pastedTitle) {
                addedCount += 1
            }
        }
        return addedCount
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
            attachmentStatusMessage = "You can attach up to \(Self.maxAttachments) photos per quest."
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
                attachmentStatusMessage = "Attached \(addedCount) photo\(addedCount == 1 ? "" : "s") (maximum \(Self.maxAttachments) per quest)."
                return addedCount
            }

            let movieTypeId = BugReportDraft.preferredMovieTypeIdentifier(for: provider)
            let imageTypeId = BugReportDraft.preferredImageTypeIdentifier(for: provider)
            let urlTypeId = BugReportDraft.preferredURLTypeIdentifier(for: provider)

            if let movieTypeId {
                if let tempMovieURL = await BugReportDraft.loadTemporaryFile(
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
                    let loadedImage = await BugReportDraft.loadImage(from: provider, imageTypeIdentifier: imageTypeId)
                    guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                        return addedCount
                    }
                    if let image = loadedImage ?? BugReportDraft.nextFallbackImage(from: fallbackImages, index: &fallbackImageIndex) {
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
                let loadedURL = await BugReportDraft.loadURL(from: provider, typeIdentifier: urlTypeId)
                guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                    return addedCount
                }
                if let loadedURL,
                   loadedURL.isFileURL,
                   FileManager.default.fileExists(atPath: loadedURL.path),
                   BugReportDraft.isMovieFileURL(loadedURL) {
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

                let loadedImage = await BugReportDraft.loadImage(from: provider, imageTypeIdentifier: imageTypeId)
                guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                    return addedCount
                }
                if let image = loadedImage ?? BugReportDraft.nextFallbackImage(from: fallbackImages, index: &fallbackImageIndex) {
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
                let loadedImage = await BugReportDraft.loadImage(from: provider, imageTypeIdentifier: imageTypeId)
                guard photoLoadGeneration == generation, !isSubmitting, submissionOutcome == nil else {
                    return addedCount
                }
                if let image = loadedImage ?? BugReportDraft.nextFallbackImage(from: fallbackImages, index: &fallbackImageIndex) {
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
    #endif

    /// Converts draft `BugReportImage` items into size-bounded `HollerKitAttachment` payloads.
    func imageAttachments() -> [HollerKitAttachment] {
        #if canImport(UIKit)
        let maxImageBytes = effectiveMaxImageBytes
        let maxVideoBytes = effectiveMaxVideoBytes
        return images.enumerated().compactMap { index, image in
            image.encodedAttachment(index: index, maxBytes: maxImageBytes, maxVideoBytes: maxVideoBytes)
        }
        #else
        return []
        #endif
    }

    /// Submits the completed quest run with any user-attached photos and captured marks.
    func submit(
        questState: HollerKitQuestState,
        clearActiveSessionImmediately: Bool = false,
        onAutoDismiss: (() -> Void)? = nil
    ) async {
        guard !isSubmitting, !isLoadingAttachments, let session = questState.activeQuest else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            submissionOutcome = nil
            submissionError = nil
            isSubmitting = true
            submissionStage = .preparing
        }
        defer {
            if isSubmitting || submissionStage != nil {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSubmitting = false
                    submissionStage = nil
                }
            }
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
            let userAttachments = imageAttachments()
            let markCount = session.marks.filter { !$0.imageData.isEmpty }.count
            let totalAttachmentCount = markCount + userAttachments.count
            let userImageCount = userAttachments.filter { $0.kind != "video" }.count
            let maxImagesLimit = effectiveMaxImages
            if totalAttachmentCount > Self.maxAttachments || (markCount + userImageCount) > maxImagesLimit {
                submissionError = "You can attach up to \(maxImagesLimit) images (including captured marks) per quest."
                SubmissionHaptics.notifyError()
                return
            }
            submissionStage = totalAttachmentCount > 0
                ? .uploadingAttachments(count: totalAttachmentCount)
                : .sending

            let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedComment.utf16.count > SpeechCaptureController.maxCommentCharacters
                || trimmedComment.count > SpeechCaptureController.maxCommentCharacters {
                submissionError = "Comments must be \(SpeechCaptureController.maxCommentCharacters) characters or fewer."
                SubmissionHaptics.notifyError()
                return
            }
            let commentToSubmit = trimmedComment.isEmpty ? nil : trimmedComment
            let transcriptToSubmit = speechCapture.transcript
            if let transcriptText = transcriptToSubmit?.text,
               transcriptText.utf16.count > SpeechCaptureController.maxCommentCharacters
                || transcriptText.count > SpeechCaptureController.maxCommentCharacters {
                submissionError = "Voice note transcripts must be \(SpeechCaptureController.maxCommentCharacters) characters or fewer."
                SubmissionHaptics.notifyError()
                return
            }

            guard questState.activeQuest?.id == session.id else {
                return
            }

            let outcome = try await questState.submitActiveQuest(
                result: selectedResult,
                comment: commentToSubmit,
                transcript: transcriptToSubmit,
                additionalAttachments: userAttachments,
                clearActiveSessionImmediately: clearActiveSessionImmediately,
                onProgress: { [weak self] stage in
                    await MainActor.run {
                        self?.submissionStage = stage
                    }
                }
            )

            submittedSessionId = session.id
            submittedSessionSnapshot = questState.activeQuest ?? session
            submittedCommentSnapshot = comment
            submittedImagesSnapshot = images
            clearInputsAfterSubmission()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                submissionOutcome = outcome
                isSubmitting = false
                submissionStage = nil
            }
            SubmissionHaptics.notify(for: outcome)

            let delay = autoDismissDelaySeconds ?? 1.2
            if delay > 0 {
                let delayNanoseconds = UInt64(delay * 1_000_000_000)
                autoDismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    guard !Task.isCancelled, let self, self.submissionOutcome != nil else { return }
                    onAutoDismiss?()
                }
            }
        } catch {
            submissionError = error.localizedDescription
            SubmissionHaptics.notifyError()
        }
    }
}
