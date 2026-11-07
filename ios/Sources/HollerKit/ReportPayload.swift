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

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct HollerKitReportPayload: Sendable {
    public var id: UUID
    public var inputMode: HollerKitInputMode
    public var comment: String?
    public var transcript: HollerKitTranscript?
    public var metadata: [String: String]
    public var breadcrumbs: [HollerKitBreadcrumb]
    public var images: [HollerKitAttachment]

    public init(
        id: UUID = UUID(),
        inputMode: HollerKitInputMode,
        comment: String? = nil,
        transcript: HollerKitTranscript? = nil,
        metadata: [String: String] = [:],
        breadcrumbs: [HollerKitBreadcrumb] = [],
        images: [HollerKitAttachment] = []
    ) {
        self.id = id
        self.inputMode = inputMode
        self.comment = comment
        self.transcript = transcript
        self.metadata = metadata
        self.breadcrumbs = breadcrumbs
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
        let events: [FeedbackEventInput] = breadcrumbs.map { crumb in
            var payload = crumb.metadata
            payload["message"] = crumb.message
            payload["timestamp"] = isoFormatter.string(from: crumb.timestamp)
            if let category = crumb.category {
                payload["category"] = category
            }
            return FeedbackEventInput(
                offsetSeconds: crumb.offsetSeconds ?? 0,
                kind: "breadcrumb",
                payload: payload
            )
        }

        let outboxAttachments: [OutboxAttachmentPayload] = images.map { attachment in
            OutboxAttachmentPayload(
                kind: "image",
                mimeType: attachment.mimeType,
                data: attachment.data
            )
        }

        let request = FeedbackSubmissionRequest(
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

        return (request, outboxAttachments)
    }
}
