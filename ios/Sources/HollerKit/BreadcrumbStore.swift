import Foundation

public struct HollerKitBreadcrumb: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var category: String?
    public var message: String
    public var metadata: [String: String]
    public var offsetSeconds: Double?

    public init(
        timestamp: Date = Date(),
        category: String? = nil,
        message: String,
        metadata: [String: String] = [:],
        offsetSeconds: Double? = nil
    ) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.metadata = metadata
        self.offsetSeconds = offsetSeconds
    }
}

public struct BreadcrumbStore: Sendable {
    public private(set) var breadcrumbs: [HollerKitBreadcrumb] = []
    public private(set) var questStartedAt: Date?
    public var capacity: Int

    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    public mutating func beginQuestRun(startedAt: Date = Date()) {
        self.questStartedAt = startedAt
    }

    public mutating func endQuestRun() {
        self.questStartedAt = nil
    }

    public mutating func append(_ breadcrumb: HollerKitBreadcrumb) {
        var entry = breadcrumb
        if entry.offsetSeconds == nil, let questStartedAt {
            entry.offsetSeconds = max(0, entry.timestamp.timeIntervalSince(questStartedAt))
        }
        breadcrumbs.append(entry)
        if breadcrumbs.count > capacity {
            breadcrumbs.removeFirst(breadcrumbs.count - capacity)
        }
    }

    public func snapshot() -> [HollerKitBreadcrumb] {
        breadcrumbs
    }

    public func questEvents(since startedAt: Date) -> [FeedbackEventInput] {
        let isoFormatter = ISO8601DateFormatter()
        return breadcrumbs
            .filter { $0.timestamp >= startedAt }
            .map { crumb in
                var payload = crumb.metadata
                payload["message"] = crumb.message
                payload["timestamp"] = isoFormatter.string(from: crumb.timestamp)
                if let category = crumb.category {
                    payload["category"] = category
                }
                let offset = crumb.offsetSeconds ?? max(0, crumb.timestamp.timeIntervalSince(startedAt))
                return FeedbackEventInput(
                    offsetSeconds: offset,
                    kind: "breadcrumb",
                    payload: payload
                )
            }
    }
}
