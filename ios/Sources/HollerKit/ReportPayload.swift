import Foundation

public struct HollerKitTranscript: Codable, Equatable, Sendable {
    public var text: String
    public var locale: String
    public var engine: Engine
    public var confidence: Double?
    public var durationSeconds: Double?

    public enum Engine: String, Codable, Sendable {
        case appleOnDevice = "apple-on-device"
        case appleNetwork = "apple-network"
        case manual
        case unavailable
    }

    public init(
        text: String,
        locale: String,
        engine: Engine,
        confidence: Double? = nil,
        durationSeconds: Double? = nil
    ) {
        self.text = text
        self.locale = locale
        self.engine = engine
        self.confidence = confidence
        self.durationSeconds = durationSeconds
    }
}

public struct HollerKitAttachment: Equatable, Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var fileURL: URL?
    public var kind: String
    public var durationSeconds: Double?
    public var videoStartOffsetSeconds: Double?

    public init(
        filename: String,
        mimeType: String,
        data: Data = Data(),
        fileURL: URL? = nil,
        kind: String? = nil,
        durationSeconds: Double? = nil,
        videoStartOffsetSeconds: Double? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.fileURL = fileURL
        if let kind {
            self.kind = kind
        } else if mimeType.lowercased().hasPrefix("video/") {
            self.kind = "video"
        } else if mimeType.lowercased().hasPrefix("audio/") {
            self.kind = "audio"
        } else {
            self.kind = "image"
        }
        self.durationSeconds = durationSeconds
        self.videoStartOffsetSeconds = videoStartOffsetSeconds
    }
}

public struct HollerKitReportPayload: Sendable {
    public static let maxFeedbackEvents = 200

    public var id: UUID
    public var inputMode: HollerKitInputMode
    public var comment: String?
    public var transcript: HollerKitTranscript?
    public var metadata: [String: String]
    public var breadcrumbs: [HollerKitBreadcrumb]
    public var truncatedBreadcrumbsCount: Int
    public var images: [HollerKitAttachment]

    public init(
        id: UUID = UUID(),
        inputMode: HollerKitInputMode,
        comment: String? = nil,
        transcript: HollerKitTranscript? = nil,
        metadata: [String: String] = [:],
        breadcrumbs: [HollerKitBreadcrumb] = [],
        truncatedBreadcrumbsCount: Int = 0,
        images: [HollerKitAttachment] = []
    ) {
        self.id = id
        self.inputMode = inputMode
        self.comment = comment
        self.transcript = transcript
        self.metadata = metadata
        self.breadcrumbs = breadcrumbs
        self.truncatedBreadcrumbsCount = max(0, truncatedBreadcrumbsCount)
        self.images = images
    }

    public func toFeedbackSubmission(build: String? = nil) -> (
        request: FeedbackSubmissionRequest,
        attachments: [OutboxAttachmentPayload]
    ) {
        var enrichedMetadata = metadata
        enrichedMetadata["inputMode"] = inputMode.wireValue
        if let transcript {
            enrichedMetadata["transcriptLocale"] = transcript.locale
            enrichedMetadata["transcriptEngine"] = transcript.engine.rawValue
            if let confidence = transcript.confidence {
                enrichedMetadata["transcriptConfidence"] = String(confidence)
            }
            if let durationSeconds = transcript.durationSeconds {
                enrichedMetadata["transcriptDurationSeconds"] = String(durationSeconds)
            }
        }

        let resolvedBuild = build ?? MetadataCollector.currentBuild(from: enrichedMetadata)
        let appVersion = MetadataCollector.currentAppVersion(from: enrichedMetadata)
        let device = enrichedMetadata["deviceModel"]
        let os = enrichedMetadata["osVersion"]

        let isoFormatter = ISO8601DateFormatter()
        var markerDroppedCount = 0
        var normalEvents: [FeedbackEventInput] = []
        normalEvents.reserveCapacity(breadcrumbs.count)

        for crumb in breadcrumbs {
            if crumb.message == "breadcrumbs.truncated" {
                if case .int(let dropped) = crumb.fields["dropped"] {
                    markerDroppedCount += max(0, dropped)
                } else if let rawDropped = crumb.metadata["dropped"], let dropped = Int(rawDropped) {
                    markerDroppedCount += max(0, dropped)
                }
                continue
            }

            var payload = FeedbackEventPayload(strings: crumb.metadata)
            payload["message"] = crumb.message
            payload["timestamp"] = isoFormatter.string(from: crumb.timestamp)
            if let category = crumb.category {
                payload["category"] = category
            }
            if !crumb.fields.isEmpty {
                payload.fields = crumb.fields
            }
            if let durationMs = crumb.durationMs {
                payload.durationMs = durationMs
            }
            if let startOffset = crumb.startOffsetSeconds {
                payload.startOffsetSeconds = startOffset
            }
            normalEvents.append(FeedbackEventInput(
                offsetSeconds: crumb.offsetSeconds ?? 0,
                kind: "breadcrumb",
                payload: payload
            ))
        }

        let baseDroppedCount = max(markerDroppedCount, max(0, truncatedBreadcrumbsCount))
        let events: [FeedbackEventInput]
        if baseDroppedCount == 0 && normalEvents.count <= Self.maxFeedbackEvents {
            events = normalEvents
        } else {
            let maxNormalEvents = max(0, Self.maxFeedbackEvents - 1)
            let newlyDroppedCount = max(0, normalEvents.count - maxNormalEvents)
            let totalDroppedCount = baseDroppedCount + newlyDroppedCount
            let retainedEvents = Array(normalEvents.suffix(maxNormalEvents))

            var markerPayload = FeedbackEventPayload()
            markerPayload["message"] = "breadcrumbs.truncated"
            markerPayload["category"] = "hollerkit"
            markerPayload["truncated"] = "true"
            markerPayload["dropped"] = String(totalDroppedCount)
            markerPayload.fields = ["dropped": .int(totalDroppedCount)]
            let markerEvent = FeedbackEventInput(
                offsetSeconds: 0,
                kind: "breadcrumb",
                payload: markerPayload
            )
            events = [markerEvent] + retainedEvents
        }

        let outboxAttachments: [OutboxAttachmentPayload] = images.map { attachment in
            OutboxAttachmentPayload(
                kind: attachment.kind,
                mimeType: attachment.mimeType,
                data: attachment.data,
                fileURL: attachment.fileURL,
                videoStartOffsetSeconds: attachment.videoStartOffsetSeconds
            )
        }

        var request = FeedbackSubmissionRequest(
            id: id,
            kind: "report",
            build: resolvedBuild,
            appVersion: appVersion,
            device: device,
            os: os,
            comment: comment,
            transcript: transcript?.text,
            metadata: enrichedMetadata,
            events: events
        )
        request.clampToBudget()

        return (request, outboxAttachments)
    }
}
