import Foundation
import Network

#if canImport(UIKit)
import UIKit
#endif

public struct OutboxAttachmentPayload: Sendable, Equatable {
    public var kind: String
    public var mimeType: String
    public var data: Data
    public var offsetSeconds: Double?
    public var videoStartOffsetSeconds: Double?

    public init(
        kind: String = "image",
        mimeType: String = "image/png",
        data: Data,
        offsetSeconds: Double? = nil,
        videoStartOffsetSeconds: Double? = nil
    ) {
        self.kind = kind
        self.mimeType = mimeType
        self.data = data
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

    public init(
        index: Int,
        fileName: String,
        kind: String,
        mimeType: String,
        size: Int,
        offsetSeconds: Double? = nil,
        videoStartOffsetSeconds: Double? = nil
    ) {
        self.index = index
        self.fileName = fileName
        self.kind = kind
        self.mimeType = mimeType
        self.size = size
        self.offsetSeconds = offsetSeconds
        self.videoStartOffsetSeconds = videoStartOffsetSeconds
    }
}

public struct OutboxEnvelope: Codable, Equatable, Sendable {
    public var feedbackId: UUID
    public var createdAt: Date
    public var request: FeedbackSubmissionRequest
    public var attachmentManifests: [OutboxAttachmentManifest]

    public init(
        feedbackId: UUID,
        createdAt: Date = Date(),
        request: FeedbackSubmissionRequest,
        attachmentManifests: [OutboxAttachmentManifest] = []
    ) {
        self.feedbackId = feedbackId
        self.createdAt = createdAt
        self.request = request
        self.attachmentManifests = attachmentManifests
    }
}

public struct OutboxFlushResult: Sendable, Equatable {
    public var flushedIds: [UUID]
    public var responses: [UUID: FeedbackSubmissionResponse]
    public var remainingCount: Int
    public var lastError: String?

    public init(
        flushedIds: [UUID] = [],
        responses: [UUID: FeedbackSubmissionResponse] = [:],
        remainingCount: Int = 0,
        lastError: String? = nil
    ) {
        self.flushedIds = flushedIds
        self.responses = responses
        self.remainingCount = remainingCount
        self.lastError = lastError
    }
}

public enum OutboxSubmissionOutcome: Sendable, Equatable {
    case sent(FeedbackSubmissionResponse)
    case queued(feedbackId: UUID, reason: String?)
}

public actor OutboxStore {
    public let rootDirectoryURL: URL
    private var activeFlushTask: Task<OutboxFlushResult, Never>?

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
        createdAt: Date = Date()
    ) throws -> UUID {
        let feedbackId = UUID(uuidString: request.id) ?? UUID()
        var normalizedRequest = request
        normalizedRequest.id = feedbackId.uuidString.lowercased()
        normalizedRequest.attachments = []

        let itemDirectoryURL = directoryURL(for: feedbackId)
        try FileManager.default.createDirectory(
            at: itemDirectoryURL,
            withIntermediateDirectories: true
        )

        var manifests: [OutboxAttachmentManifest] = []
        manifests.reserveCapacity(attachments.count)

        for (index, attachment) in attachments.enumerated() {
            let ext = Self.fileExtension(for: attachment.mimeType, kind: attachment.kind)
            let fileName = "\(index).\(ext)"
            let fileURL = itemDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try attachment.data.write(to: fileURL, options: .atomic)

            manifests.append(OutboxAttachmentManifest(
                index: index,
                fileName: fileName,
                kind: attachment.kind,
                mimeType: attachment.mimeType,
                size: attachment.data.count,
                offsetSeconds: attachment.offsetSeconds,
                videoStartOffsetSeconds: attachment.videoStartOffsetSeconds
            ))
        }

        let envelope = OutboxEnvelope(
            feedbackId: feedbackId,
            createdAt: createdAt,
            request: normalizedRequest,
            attachmentManifests: manifests
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let envelopeData = try encoder.encode(envelope)
        let envelopeURL = itemDirectoryURL.appendingPathComponent("envelope.json", isDirectory: false)
        try envelopeData.write(to: envelopeURL, options: .atomic)

        return feedbackId
    }

    public func submit(
        request: FeedbackSubmissionRequest,
        attachments: [OutboxAttachmentPayload] = [],
        using client: APIClient
    ) async throws -> OutboxSubmissionOutcome {
        let feedbackId = try enqueue(request: request, attachments: attachments)
        let flushResult = await flush(using: client)
        if let response = flushResult.responses[feedbackId] {
            return .sent(response)
        }
        return .queued(feedbackId: feedbackId, reason: flushResult.lastError)
    }

    @discardableResult
    public func flush(using client: APIClient) async -> OutboxFlushResult {
        if let existingTask = activeFlushTask {
            return await existingTask.value
        }

        let task = Task<OutboxFlushResult, Never> {
            await performFlush(using: client)
        }
        activeFlushTask = task
        let result = await task.value
        activeFlushTask = nil
        return result
    }

    public func pendingEnvelopes() -> [OutboxEnvelope] {
        loadPendingItems().map(\.envelope)
    }

    public func pendingCount() -> Int {
        loadPendingItems().count
    }

    public func directoryURL(for feedbackId: UUID) -> URL {
        rootDirectoryURL.appendingPathComponent(feedbackId.uuidString.lowercased(), isDirectory: true)
    }

    private struct StoredOutboxItem {
        var directoryURL: URL
        var envelope: OutboxEnvelope
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

    private func performFlush(using client: APIClient) async -> OutboxFlushResult {
        let items = loadPendingItems()
        guard !items.isEmpty else {
            return OutboxFlushResult(flushedIds: [], responses: [:], remainingCount: 0, lastError: nil)
        }

        var flushedIds: [UUID] = []
        var responses: [UUID: FeedbackSubmissionResponse] = [:]
        var lastError: String?

        for item in items {
            let token: String
            do {
                token = try await client.resolveToken()
            } catch {
                lastError = error.localizedDescription
                break
            }

            do {
                let response = try await flushSingleItem(item, token: token, using: client)
                try? FileManager.default.removeItem(at: item.directoryURL)
                flushedIds.append(item.envelope.feedbackId)
                responses[item.envelope.feedbackId] = response
            } catch {
                lastError = error.localizedDescription
            }
        }

        let remainingCount = loadPendingItems().count
        return OutboxFlushResult(
            flushedIds: flushedIds,
            responses: responses,
            remainingCount: remainingCount,
            lastError: lastError
        )
    }

    private func flushSingleItem(
        _ item: StoredOutboxItem,
        token: String,
        using client: APIClient
    ) async throws -> FeedbackSubmissionResponse {
        var uploadedAttachments: [FeedbackAttachmentInput] = []
        uploadedAttachments.reserveCapacity(item.envelope.attachmentManifests.count)

        for manifest in item.envelope.attachmentManifests {
            let fileURL = item.directoryURL.appendingPathComponent(manifest.fileName, isDirectory: false)
            let fileData = try Data(contentsOf: fileURL)

            let grant = try await client.requestUploadGrant(
                feedbackId: item.envelope.feedbackId,
                kind: manifest.kind,
                mimeType: manifest.mimeType,
                size: fileData.count,
                token: token
            )

            try await client.uploadFile(
                url: grant.url,
                data: fileData,
                mimeType: manifest.mimeType
            )

            uploadedAttachments.append(FeedbackAttachmentInput(
                key: grant.key,
                kind: manifest.kind,
                mimeType: manifest.mimeType,
                size: fileData.count,
                offsetSeconds: manifest.offsetSeconds,
                videoStartOffsetSeconds: manifest.videoStartOffsetSeconds
            ))
        }

        var finalRequest = item.envelope.request
        finalRequest.id = item.envelope.feedbackId.uuidString.lowercased()
        finalRequest.attachments = uploadedAttachments

        return try await client.submitFeedback(finalRequest, token: token)
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
        monitor.pathUpdateHandler = { path in
            let isSatisfied = (path.status == .satisfied)
            Task { @MainActor in
                if isSatisfied {
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
