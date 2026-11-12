import CryptoKit
import Foundation
import Network

#if canImport(UIKit)
import UIKit
#endif

public struct OutboxAttachmentPayload: Sendable, Equatable {
    public var kind: String
    public var mimeType: String
    public var data: Data
    public var fileURL: URL?
    public var offsetSeconds: Double?
    public var videoStartOffsetSeconds: Double?

    public init(
        kind: String = "image",
        mimeType: String = "image/png",
        data: Data = Data(),
        fileURL: URL? = nil,
        offsetSeconds: Double? = nil,
        videoStartOffsetSeconds: Double? = nil
    ) {
        self.kind = kind
        self.mimeType = mimeType
        self.data = data
        self.fileURL = fileURL
        self.offsetSeconds = offsetSeconds
        self.videoStartOffsetSeconds = videoStartOffsetSeconds
    }
}

public struct OutboxAttachmentManifest: Codable, Equatable, Sendable {
    public var index: Int
    public var fileName: String
    public var kind: String
    public var mimeType: String
    public var size: Int
    public var offsetSeconds: Double?
    public var videoStartOffsetSeconds: Double?
    public var uploadedKey: String?
    public var uploadedExpiresAt: String?

    public init(
        index: Int,
        fileName: String,
        kind: String,
        mimeType: String,
        size: Int,
        offsetSeconds: Double? = nil,
        videoStartOffsetSeconds: Double? = nil,
        uploadedKey: String? = nil,
        uploadedExpiresAt: String? = nil
    ) {
        self.index = index
        self.fileName = fileName
        self.kind = kind
        self.mimeType = mimeType
        self.size = size
        self.offsetSeconds = offsetSeconds
        self.videoStartOffsetSeconds = videoStartOffsetSeconds
        self.uploadedKey = uploadedKey
        self.uploadedExpiresAt = uploadedExpiresAt
    }
}

public struct OutboxEnvelope: Codable, Equatable, Sendable {
    public var feedbackId: UUID
    public var revision: UUID
    public var createdAt: Date
    public var serverURL: String?
    public var principalFingerprint: String?
    public var request: FeedbackSubmissionRequest
    public var attachmentManifests: [OutboxAttachmentManifest]
    public var questManifestEntry: QuestManifestEntry?
    public var submittedResponse: FeedbackSubmissionResponse?

    private enum CodingKeys: String, CodingKey {
        case feedbackId
        case revision
        case createdAt
        case serverURL
        case principalFingerprint
        case request
        case attachmentManifests
        case questManifestEntry
        case submittedResponse
    }

    public init(
        feedbackId: UUID,
        revision: UUID = UUID(),
        createdAt: Date = Date(),
        serverURL: String? = nil,
        principalFingerprint: String? = nil,
        request: FeedbackSubmissionRequest,
        attachmentManifests: [OutboxAttachmentManifest] = [],
        questManifestEntry: QuestManifestEntry? = nil,
        submittedResponse: FeedbackSubmissionResponse? = nil
    ) {
        self.feedbackId = feedbackId
        self.revision = revision
        self.createdAt = createdAt
        self.serverURL = serverURL
        self.principalFingerprint = principalFingerprint
        self.request = request
        self.attachmentManifests = attachmentManifests
        self.questManifestEntry = questManifestEntry
        self.submittedResponse = submittedResponse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.feedbackId = try container.decode(UUID.self, forKey: .feedbackId)
        self.revision = try container.decodeIfPresent(UUID.self, forKey: .revision) ?? UUID()
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        self.principalFingerprint = try container.decodeIfPresent(String.self, forKey: .principalFingerprint)
        self.request = try container.decode(FeedbackSubmissionRequest.self, forKey: .request)
        self.attachmentManifests = try container.decodeIfPresent([OutboxAttachmentManifest].self, forKey: .attachmentManifests) ?? []
        self.questManifestEntry = try container.decodeIfPresent(QuestManifestEntry.self, forKey: .questManifestEntry)
        self.submittedResponse = try container.decodeIfPresent(FeedbackSubmissionResponse.self, forKey: .submittedResponse)
    }
}

public struct OutboxFlushResult: Sendable, Equatable {
    public var flushedIds: [UUID]
    public var responses: [UUID: FeedbackSubmissionResponse]
    public var flushedRevisions: [UUID: UUID]
    public var rejectedErrors: [UUID: HollerKitAPIError]
    public var remainingCount: Int
    public var lastError: String?
    public var isAuthenticationError: Bool

    public init(
        flushedIds: [UUID] = [],
        responses: [UUID: FeedbackSubmissionResponse] = [:],
        flushedRevisions: [UUID: UUID] = [:],
        rejectedErrors: [UUID: HollerKitAPIError] = [:],
        remainingCount: Int = 0,
        lastError: String? = nil,
        isAuthenticationError: Bool = false
    ) {
        self.flushedIds = flushedIds
        self.responses = responses
        self.flushedRevisions = flushedRevisions
        self.rejectedErrors = rejectedErrors
        self.remainingCount = remainingCount
        self.lastError = lastError
        self.isAuthenticationError = isAuthenticationError
    }
}

public enum OutboxSubmissionOutcome: Sendable, Equatable {
    case sent(FeedbackSubmissionResponse)
    case queued(feedbackId: UUID, reason: String?, isAuthenticationError: Bool = false)
}

private actor OutboxDirectoryCoordinator {
    static let shared = OutboxDirectoryCoordinator()

    private var engines: [String: OutboxDirectoryEngine] = [:]

    func engine(for rootDirectoryURL: URL) -> OutboxDirectoryEngine {
        let key = rootDirectoryURL.standardizedFileURL.path
        if let existing = engines[key] {
            return existing
        }
        let created = OutboxDirectoryEngine(rootDirectoryURL: rootDirectoryURL)
        engines[key] = created
        return created
    }
}

actor OutboxDirectoryEngine {
    let rootDirectoryURL: URL
    private var activeFlushTask: Task<OutboxFlushResult, Never>?
    private var latestFlushClient: APIClient?
    private var needsFollowUpFlush = false
    private var inFlightFeedbackIds: Set<UUID> = []
    private var inFlightWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var progressCallbacks: [UUID: @Sendable (SubmissionProgressStage) async -> Void] = [:]

    /// Creates a directory-backed outbox engine rooted at `rootDirectoryURL`.
    init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL
    }

    /// Registers or clears the per-item submission progress callback for `feedbackId`.
    func setProgressCallback(
        _ callback: (@Sendable (SubmissionProgressStage) async -> Void)?,
        for feedbackId: UUID
    ) {
        progressCallbacks[feedbackId] = callback
    }

    func enqueue(
        request: FeedbackSubmissionRequest,
        attachments: [OutboxAttachmentPayload],
        questManifestEntry: QuestManifestEntry?,
        serverURL: String?,
        createdAt: Date
    ) async throws -> (feedbackId: UUID, revision: UUID) {
        let feedbackId = UUID(uuidString: request.id) ?? UUID()
        await waitUntilNotInFlight(feedbackId)

        let revision = UUID()
        var normalizedRequest = request
        normalizedRequest.id = feedbackId.uuidString.lowercased()
        normalizedRequest.clampToBudget()

        for attachment in attachments {
            if let sourceURL = attachment.fileURL,
               !FileManager.default.fileExists(atPath: sourceURL.path) {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
            }
        }

        let itemDirectoryURL = directoryURL(for: feedbackId)
        if FileManager.default.fileExists(atPath: itemDirectoryURL.path) {
            if let existingFiles = try? FileManager.default.contentsOfDirectory(
                at: itemDirectoryURL,
                includingPropertiesForKeys: nil
            ) {
                for existingURL in existingFiles where existingURL.lastPathComponent != "envelope.json" {
                    try? FileManager.default.removeItem(at: existingURL)
                }
            }
        } else {
            try FileManager.default.createDirectory(
                at: itemDirectoryURL,
                withIntermediateDirectories: true
            )
        }

        var manifests: [OutboxAttachmentManifest] = []
        manifests.reserveCapacity(attachments.count)

        for (index, attachment) in attachments.enumerated() {
            let ext = Self.fileExtension(for: attachment.mimeType, kind: attachment.kind)
            let fileName = "\(index).\(ext)"
            let fileURL = itemDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            let attachmentSize: Int
            if let sourceURL = attachment.fileURL {
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: fileURL)
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                attachmentSize = (attrs[.size] as? NSNumber)?.intValue ?? attachment.data.count
            } else {
                try attachment.data.write(to: fileURL, options: .atomic)
                attachmentSize = attachment.data.count
            }

            manifests.append(OutboxAttachmentManifest(
                index: index,
                fileName: fileName,
                kind: attachment.kind,
                mimeType: attachment.mimeType,
                size: attachmentSize,
                offsetSeconds: attachment.offsetSeconds,
                videoStartOffsetSeconds: attachment.videoStartOffsetSeconds
            ))
        }

        let envelope = OutboxEnvelope(
            feedbackId: feedbackId,
            revision: revision,
            createdAt: createdAt,
            serverURL: serverURL.map(Self.normalizedServerString),
            principalFingerprint: nil,
            request: normalizedRequest,
            attachmentManifests: manifests,
            questManifestEntry: questManifestEntry,
            submittedResponse: nil
        )

        try writeEnvelope(envelope, to: itemDirectoryURL)
        if activeFlushTask != nil {
            needsFollowUpFlush = true
        }
        return (feedbackId, revision)
    }

    /// Flushes all pending outbox items to `client`, coalescing concurrent flush requests so every caller
    /// awaits both the active pass and any follow-up passes triggered while the flush was running.
    func flush(using client: APIClient) async -> OutboxFlushResult {
        latestFlushClient = client
        if let existingTask = activeFlushTask {
            needsFollowUpFlush = true
            return await existingTask.value
        }

        let task = Task<OutboxFlushResult, Never> {
            await drainFlushLoop(initialClient: client)
        }
        activeFlushTask = task
        return await task.value
    }

    /// Runs `runFlushLoop` repeatedly until `needsFollowUpFlush` remains `false` at pass completion,
    /// merging results across passes before clearing `activeFlushTask`.
    private func drainFlushLoop(initialClient: APIClient) async -> OutboxFlushResult {
        var combinedResult = OutboxFlushResult()
        repeat {
            let currentClient = latestFlushClient ?? initialClient
            let passResult = await runFlushLoop(using: currentClient)
            combinedResult = Self.mergeFlushResults(combinedResult, passResult)
        } while needsFollowUpFlush
        activeFlushTask = nil
        latestFlushClient = nil
        return combinedResult
    }

    /// Merges two consecutive `OutboxFlushResult` values from coalesced flush passes.
    private static func mergeFlushResults(
        _ first: OutboxFlushResult,
        _ second: OutboxFlushResult
    ) -> OutboxFlushResult {
        var flushedIds = first.flushedIds
        for id in second.flushedIds where !flushedIds.contains(id) {
            flushedIds.append(id)
        }
        var responses = first.responses
        for (id, response) in second.responses {
            responses[id] = response
        }
        var flushedRevisions = first.flushedRevisions
        for (id, rev) in second.flushedRevisions {
            flushedRevisions[id] = rev
        }
        var rejectedErrors = first.rejectedErrors
        for (id, err) in second.rejectedErrors {
            rejectedErrors[id] = err
        }
        return OutboxFlushResult(
            flushedIds: flushedIds,
            responses: responses,
            flushedRevisions: flushedRevisions,
            rejectedErrors: rejectedErrors,
            remainingCount: second.remainingCount,
            lastError: second.lastError ?? first.lastError,
            isAuthenticationError: first.isAuthenticationError || second.isAuthenticationError
        )
    }

    func pendingEnvelopes() -> [OutboxEnvelope] {
        loadPendingItems().map(\.envelope)
    }

    func pendingCount() -> Int {
        loadPendingItems().count
    }

    func directoryURL(for feedbackId: UUID) -> URL {
        rootDirectoryURL.appendingPathComponent(feedbackId.uuidString.lowercased(), isDirectory: true)
    }

    private struct StoredOutboxItem {
        var directoryURL: URL
        var envelope: OutboxEnvelope
    }

    private func waitUntilNotInFlight(_ feedbackId: UUID) async {
        while inFlightFeedbackIds.contains(feedbackId) {
            await withCheckedContinuation { continuation in
                inFlightWaiters[feedbackId, default: []].append(continuation)
            }
        }
    }

    private func markInFlight(_ feedbackId: UUID) {
        inFlightFeedbackIds.insert(feedbackId)
    }

    private func unmarkInFlight(_ feedbackId: UUID) {
        inFlightFeedbackIds.remove(feedbackId)
        if let waiters = inFlightWaiters.removeValue(forKey: feedbackId) {
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func writeEnvelope(_ envelope: OutboxEnvelope, to itemDirectoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let envelopeData = try encoder.encode(envelope)
        let envelopeURL = itemDirectoryURL.appendingPathComponent("envelope.json", isDirectory: false)
        try envelopeData.write(to: envelopeURL, options: .atomic)
    }

    private func loadPendingItems() -> [StoredOutboxItem] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var items: [StoredOutboxItem] = []
        for entryURL in entries {
            let envelopeURL = entryURL.appendingPathComponent("envelope.json", isDirectory: false)
            guard let data = try? Data(contentsOf: envelopeURL),
                  let envelope = try? decoder.decode(OutboxEnvelope.self, from: data) else {
                continue
            }
            items.append(StoredOutboxItem(directoryURL: entryURL, envelope: envelope))
        }

        items.sort { lhs, rhs in
            if lhs.envelope.createdAt != rhs.envelope.createdAt {
                return lhs.envelope.createdAt < rhs.envelope.createdAt
            }
            return lhs.envelope.feedbackId.uuidString < rhs.envelope.feedbackId.uuidString
        }
        return items
    }

    private func runFlushLoop(using client: APIClient) async -> OutboxFlushResult {
        var combinedFlushedIds: [UUID] = []
        var combinedResponses: [UUID: FeedbackSubmissionResponse] = [:]
        var combinedRevisions: [UUID: UUID] = [:]
        var combinedRejectedErrors: [UUID: HollerKitAPIError] = [:]
        var lastError: String?
        var isAuthError = false
        var attemptedFailedRevisions: Set<UUID> = []

        repeat {
            needsFollowUpFlush = false
            let passResult = await performFlushPass(
                using: client,
                skippingRevisions: attemptedFailedRevisions
            )
            for id in passResult.flushedIds where !combinedFlushedIds.contains(id) {
                combinedFlushedIds.append(id)
            }
            for (id, response) in passResult.responses {
                combinedResponses[id] = response
            }
            for (id, rev) in passResult.flushedRevisions {
                combinedRevisions[id] = rev
            }
            for (id, err) in passResult.rejectedErrors {
                combinedRejectedErrors[id] = err
            }
            attemptedFailedRevisions.formUnion(passResult.failedRevisions)
            if let passError = passResult.lastError {
                lastError = passError
            }
            if passResult.isAuthenticationError {
                isAuthError = true
            }
        } while needsFollowUpFlush

        let remainingCount = loadPendingItems().count
        return OutboxFlushResult(
            flushedIds: combinedFlushedIds,
            responses: combinedResponses,
            flushedRevisions: combinedRevisions,
            rejectedErrors: combinedRejectedErrors,
            remainingCount: remainingCount,
            lastError: lastError,
            isAuthenticationError: isAuthError
        )
    }

    private struct FlushPassResult {
        var flushedIds: [UUID] = []
        var responses: [UUID: FeedbackSubmissionResponse] = [:]
        var flushedRevisions: [UUID: UUID] = [:]
        var rejectedErrors: [UUID: HollerKitAPIError] = [:]
        var failedRevisions: Set<UUID> = []
        var lastError: String?
        var isAuthenticationError = false
    }

    private func performFlushPass(
        using client: APIClient,
        skippingRevisions: Set<UUID>
    ) async -> FlushPassResult {
        let items = loadPendingItems().filter { !skippingRevisions.contains($0.envelope.revision) }
        guard !items.isEmpty else {
            return FlushPassResult()
        }

        var result = FlushPassResult()
        let activeServerString = Self.normalizedServerString(client.server.absoluteString)

        for item in items {
            let feedbackId = item.envelope.feedbackId
            let revision = item.envelope.revision

            // If a previous pass already submitted this item and only failed to delete the directory,
            // retry directory cleanup first without even needing an auth token or network call.
            if let existingResponse = item.envelope.submittedResponse {
                do {
                    try FileManager.default.removeItem(at: item.directoryURL)
                    result.flushedIds.append(feedbackId)
                    result.responses[feedbackId] = existingResponse
                    result.flushedRevisions[feedbackId] = revision
                } catch {
                    result.failedRevisions.insert(revision)
                    result.lastError = error.localizedDescription
                }
                continue
            }

            if let pinnedServer = item.envelope.serverURL,
               Self.normalizedServerString(pinnedServer) != activeServerString {
                result.failedRevisions.insert(revision)
                result.lastError = "Outbox item server URL does not match active server."
                continue
            }

            let token: String
            do {
                token = try await client.resolveToken()
            } catch {
                result.failedRevisions.insert(revision)
                result.lastError = error.localizedDescription
                if let apiError = error as? HollerKitAPIError, apiError.isAuthenticationError {
                    result.isAuthenticationError = true
                }
                break
            }

            markInFlight(feedbackId)
            defer { unmarkInFlight(feedbackId) }
            do {
                let response = try await flushSingleItem(item, token: token, using: client)
                do {
                    try FileManager.default.removeItem(at: item.directoryURL)
                } catch {
                    // `submittedResponse` has already been persisted to `envelope.json` inside `flushSingleItem`,
                    // so subsequent flushes will retry directory deletion without re-uploading or re-submitting.
                    result.lastError = error.localizedDescription
                }
                result.flushedIds.append(feedbackId)
                result.responses[feedbackId] = response
                result.flushedRevisions[feedbackId] = revision
            } catch {
                result.lastError = error.localizedDescription
                if let apiError = error as? HollerKitAPIError {
                    if apiError.isAuthenticationError {
                        result.isAuthenticationError = true
                    }
                    if apiError.isPermanentValidationError {
                        try? FileManager.default.removeItem(at: item.directoryURL)
                        result.rejectedErrors[feedbackId] = apiError
                        continue
                    }
                }
                result.failedRevisions.insert(revision)
            }
        }

        return result
    }

    private func flushSingleItem(
        _ item: StoredOutboxItem,
        token: String,
        using client: APIClient,
        allowGrantRefreshRetry: Bool = true
    ) async throws -> FeedbackSubmissionResponse {
        var envelope = item.envelope
        if let alreadySubmitted = envelope.submittedResponse {
            return alreadySubmitted
        }

        let currentFingerprint = Self.tokenFingerprint(token)
        let activeServerString = Self.normalizedServerString(client.server.absoluteString)
        if envelope.serverURL == nil {
            envelope.serverURL = activeServerString
        }

        // If a previous partial upload used a different principal token, invalidate cached upload keys
        // so fresh upload grants are requested under the current authenticated user.
        if let previousFingerprint = envelope.principalFingerprint,
           previousFingerprint != currentFingerprint {
            for index in envelope.attachmentManifests.indices {
                envelope.attachmentManifests[index].uploadedKey = nil
                envelope.attachmentManifests[index].uploadedExpiresAt = nil
            }
        }
        envelope.principalFingerprint = currentFingerprint

        var uploadedAttachments: [FeedbackAttachmentInput] = []
        uploadedAttachments.reserveCapacity(envelope.attachmentManifests.count)
        var reusedManifestIndices: [Int] = []
        let progressCallback = progressCallbacks[envelope.feedbackId]

        let totalCount = envelope.attachmentManifests.count
        if totalCount > 0 {
            await progressCallback?(.uploadingAttachments(count: totalCount))
        }

        for idx in envelope.attachmentManifests.indices {
            let manifest = envelope.attachmentManifests[idx]
            let fileURL = item.directoryURL.appendingPathComponent(manifest.fileName, isDirectory: false)
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? manifest.size

            if let cachedKey = manifest.uploadedKey,
               Self.isUploadGrantStillReusable(expiresAt: manifest.uploadedExpiresAt) {
                reusedManifestIndices.append(idx)
                uploadedAttachments.append(FeedbackAttachmentInput(
                    key: cachedKey,
                    kind: manifest.kind,
                    mimeType: manifest.mimeType,
                    size: fileSize,
                    offsetSeconds: manifest.offsetSeconds,
                    videoStartOffsetSeconds: manifest.videoStartOffsetSeconds
                ))
                continue
            }

            let grant = try await client.requestUploadGrant(
                feedbackId: envelope.feedbackId,
                kind: manifest.kind,
                mimeType: manifest.mimeType,
                size: fileSize,
                token: token
            )

            let itemIndex = idx + 1
            let itemProgressCallback: (@Sendable (Double) async -> Void)?
            if let progressCallback {
                itemProgressCallback = { fraction in
                    await progressCallback(.uploadingAttachment(
                        index: itemIndex,
                        total: totalCount,
                        progress: fraction
                    ))
                }
            } else {
                itemProgressCallback = nil
            }

            try await client.uploadFile(
                url: grant.url,
                fileURL: fileURL,
                fileSize: fileSize,
                mimeType: manifest.mimeType,
                onProgress: itemProgressCallback
            )

            envelope.attachmentManifests[idx].uploadedKey = grant.key
            envelope.attachmentManifests[idx].uploadedExpiresAt = grant.expiresAt
            try? writeEnvelope(envelope, to: item.directoryURL)

            uploadedAttachments.append(FeedbackAttachmentInput(
                key: grant.key,
                kind: manifest.kind,
                mimeType: manifest.mimeType,
                size: fileSize,
                offsetSeconds: manifest.offsetSeconds,
                videoStartOffsetSeconds: manifest.videoStartOffsetSeconds
            ))
        }

        await progressCallback?(.sending)

        var finalRequest = envelope.request
        finalRequest.id = envelope.feedbackId.uuidString.lowercased()
        finalRequest.attachments = envelope.request.attachments + uploadedAttachments

        if let manifestEntry = envelope.questManifestEntry {
            let manifestResponse = try await client.syncBuildManifest(
                build: finalRequest.build,
                appVersion: finalRequest.appVersion,
                quests: [manifestEntry],
                token: token
            )
            if let syncedQuest = manifestResponse.quests.first(where: { $0.id == manifestEntry.id }) {
                finalRequest.questVersion = syncedQuest.version
                envelope.request.questVersion = syncedQuest.version
            }
            envelope.questManifestEntry = nil
            try? writeEnvelope(envelope, to: item.directoryURL)
        }

        do {
            let response = try await client.submitFeedback(finalRequest, token: token)
            envelope.submittedResponse = response
            try? writeEnvelope(envelope, to: item.directoryURL)
            return response
        } catch let apiError as HollerKitAPIError where apiError.isExpiredOrConsumedGrantError {
            let indicesToRefresh: [Int]
            if !reusedManifestIndices.isEmpty {
                indicesToRefresh = reusedManifestIndices
            } else if envelope.request.attachments.isEmpty {
                indicesToRefresh = Array(envelope.attachmentManifests.indices)
            } else {
                indicesToRefresh = []
            }

            guard allowGrantRefreshRetry, !indicesToRefresh.isEmpty else {
                throw apiError
            }

            for index in indicesToRefresh {
                envelope.attachmentManifests[index].uploadedKey = nil
                envelope.attachmentManifests[index].uploadedExpiresAt = nil
            }
            try? writeEnvelope(envelope, to: item.directoryURL)
            let refreshedItem = StoredOutboxItem(directoryURL: item.directoryURL, envelope: envelope)
            return try await flushSingleItem(
                refreshedItem,
                token: token,
                using: client,
                allowGrantRefreshRetry: false
            )
        }
    }

    private static func isUploadGrantStillReusable(expiresAt: String?) -> Bool {
        guard let expiresAt, !expiresAt.isEmpty else {
            return true
        }
        let formatter = ISO8601DateFormatter()
        if let expiryDate = formatter.date(from: expiresAt) {
            return expiryDate.timeIntervalSinceNow > 30
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let expiryDate = formatter.date(from: expiresAt) {
            return expiryDate.timeIntervalSinceNow > 30
        }
        return true
    }

    static func tokenFingerprint(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedServerString(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private static func fileExtension(for mimeType: String, kind: String) -> String {
        let lower = mimeType.lowercased()
        if lower.contains("png") { return "png" }
        if lower.contains("jpeg") || lower.contains("jpg") { return "jpg" }
        if lower.contains("heic") { return "heic" }
        if lower.contains("heif") { return "heif" }
        if lower.contains("webp") { return "webp" }
        if lower.contains("m4a") || lower.contains("aac") { return "m4a" }
        if lower.contains("mp4") { return kind == "audio" ? "m4a" : "mp4" }
        if lower.contains("quicktime") { return "mov" }
        return "bin"
    }
}

public actor OutboxStore {
    public let rootDirectoryURL: URL

    public init(rootDirectoryURL: URL? = nil) {
        if let rootDirectoryURL {
            self.rootDirectoryURL = rootDirectoryURL
        } else {
            self.rootDirectoryURL = Self.defaultOutboxDirectoryURL()
        }
    }

    public static func defaultOutboxDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("HollerKit", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true)
    }

    @discardableResult
    public func enqueue(
        request: FeedbackSubmissionRequest,
        attachments: [OutboxAttachmentPayload] = [],
        questManifestEntry: QuestManifestEntry? = nil,
        serverURL: String? = nil,
        createdAt: Date = Date()
    ) async throws -> UUID {
        let engine = await OutboxDirectoryCoordinator.shared.engine(for: rootDirectoryURL)
        let (feedbackId, _) = try await engine.enqueue(
            request: request,
            attachments: attachments,
            questManifestEntry: questManifestEntry,
            serverURL: serverURL,
            createdAt: createdAt
        )
        return feedbackId
    }

    public func submit(
        request: FeedbackSubmissionRequest,
        attachments: [OutboxAttachmentPayload] = [],
        questManifestEntry: QuestManifestEntry? = nil,
        using client: APIClient,
        onProgress: (@Sendable (SubmissionProgressStage) async -> Void)? = nil
    ) async throws -> OutboxSubmissionOutcome {
        let engine = await OutboxDirectoryCoordinator.shared.engine(for: rootDirectoryURL)
        let (feedbackId, revision) = try await engine.enqueue(
            request: request,
            attachments: attachments,
            questManifestEntry: questManifestEntry,
            serverURL: client.server.absoluteString,
            createdAt: Date()
        )
        await engine.setProgressCallback(onProgress, for: feedbackId)
        let flushResult = await engine.flush(using: client)
        await engine.setProgressCallback(nil, for: feedbackId)
        if !flushResult.rejectedErrors.isEmpty {
            let rejectedIds = Set(flushResult.rejectedErrors.keys)
            await MainActor.run {
                HollerKit.quests.rollbackRejectedFeedbackIds(rejectedIds)
            }
        }
        if let rejectedError = flushResult.rejectedErrors[feedbackId] {
            throw rejectedError
        }
        if flushResult.flushedRevisions[feedbackId] == revision,
           let response = flushResult.responses[feedbackId] {
            return .sent(response)
        }
        return .queued(
            feedbackId: feedbackId,
            reason: flushResult.lastError,
            isAuthenticationError: flushResult.isAuthenticationError
        )
    }

    @discardableResult
    public func flush(using client: APIClient) async -> OutboxFlushResult {
        let engine = await OutboxDirectoryCoordinator.shared.engine(for: rootDirectoryURL)
        let flushResult = await engine.flush(using: client)
        if !flushResult.rejectedErrors.isEmpty {
            let rejectedIds = Set(flushResult.rejectedErrors.keys)
            await MainActor.run {
                HollerKit.quests.rollbackRejectedFeedbackIds(rejectedIds)
            }
        }
        return flushResult
    }

    public func pendingEnvelopes() async -> [OutboxEnvelope] {
        let engine = await OutboxDirectoryCoordinator.shared.engine(for: rootDirectoryURL)
        return await engine.pendingEnvelopes()
    }

    public func pendingCount() async -> Int {
        let engine = await OutboxDirectoryCoordinator.shared.engine(for: rootDirectoryURL)
        return await engine.pendingCount()
    }

    public func directoryURL(for feedbackId: UUID) -> URL {
        rootDirectoryURL.appendingPathComponent(feedbackId.uuidString.lowercased(), isDirectory: true)
    }
}

@MainActor
final class OutboxLifecycleMonitor {
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.hollerkit.outbox.network")
    private var foregroundObserver: NSObjectProtocol?
    private var wasNetworkSatisfied = false
    private let onTriggerFlush: @Sendable @MainActor () -> Void

    init(onTriggerFlush: @escaping @Sendable @MainActor () -> Void) {
        self.onTriggerFlush = onTriggerFlush
    }

    func start() {
        stop()

        let trigger = onTriggerFlush
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let transitionedToSatisfied = !self.wasNetworkSatisfied && isSatisfied
                self.wasNetworkSatisfied = isSatisfied
                if transitionedToSatisfied {
                    trigger()
                }
            }
        }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor

        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                trigger()
            }
        }
        #endif
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil

        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
        wasNetworkSatisfied = false
    }
}
