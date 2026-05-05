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

public struct HollerKitAttachment: Sendable {
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
    public var inputMode: HollerKitInputMode
    public var comment: String?
    public var transcript: HollerKitTranscript?
    public var metadata: [String: String]
    public var breadcrumbs: [HollerKitBreadcrumb]
    public var userIdHash: String?
    public var images: [HollerKitAttachment]

    public init(
        inputMode: HollerKitInputMode,
        comment: String? = nil,
        transcript: HollerKitTranscript? = nil,
        metadata: [String: String] = [:],
        breadcrumbs: [HollerKitBreadcrumb] = [],
        userIdHash: String? = nil,
        images: [HollerKitAttachment] = []
    ) {
        self.inputMode = inputMode
        self.comment = comment
        self.transcript = transcript
        self.metadata = metadata
        self.breadcrumbs = breadcrumbs
        self.userIdHash = userIdHash
        self.images = images
    }
}
