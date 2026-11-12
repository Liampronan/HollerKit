import Foundation

@frozen
public enum HollerKitFieldValue: Codable, Equatable, Sendable,
    ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .int(value)
    }

    public init(floatLiteral value: Double) {
        self = .double(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String, Int, Double, or Bool"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let val):
            try container.encode(val)
        case .int(let val):
            try container.encode(val)
        case .double(let val):
            try container.encode(val)
        case .bool(let val):
            try container.encode(val)
        }
    }

    public var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        }
    }
}

public final class HollerKitSpan: @unchecked Sendable {
    public let name: String
    public let category: String?
    public let startDate: Date
    public let startFields: [String: HollerKitFieldValue]
    public let startMetadata: [String: String]
    public let generation: UInt64
    private let isEnabled: Bool
    private let lock = NSLock()
    private var hasEnded = false

    public init(
        name: String,
        category: String? = nil,
        fields: [String: HollerKitFieldValue] = [:],
        metadata: [String: String] = [:],
        startDate: Date = Date(),
        isEnabled: Bool = true,
        generation: UInt64 = 0
    ) {
        self.name = name
        self.category = category
        self.startFields = fields
        self.startMetadata = metadata
        self.startDate = startDate
        self.isEnabled = isEnabled
        self.generation = generation
    }

    public func end(
        fields: [String: HollerKitFieldValue] = [:],
        metadata: [String: String] = [:],
        endDate: Date = Date()
    ) {
        lock.lock()
        guard isEnabled, !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        lock.unlock()

        let durationMs = max(0, endDate.timeIntervalSince(startDate) * 1000.0)
        var mergedFields = startFields
        for (k, v) in fields {
            mergedFields[k] = v
        }
        var mergedMetadata = startMetadata
        for (k, v) in metadata {
            mergedMetadata[k] = v
        }

        let recordAction = { @MainActor in
            HollerKit.recordSpanBreadcrumb(
                name: self.name,
                category: self.category,
                fields: mergedFields,
                metadata: mergedMetadata,
                durationMs: durationMs,
                startDate: self.startDate,
                endDate: endDate,
                generation: self.generation
            )
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                recordAction()
            }
        } else {
            DispatchQueue.main.sync {
                recordAction()
            }
        }
    }

    public func end(
        fields: [String: HollerKitFieldValue] = [:],
        metadata: [String: String] = [:],
        endDate: Date = Date()
    ) async {
        await MainActor.run {
            self.end(fields: fields, metadata: metadata, endDate: endDate)
        }
    }
}

public struct HollerKitBreadcrumb: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var category: String?
    public var message: String
    public var fields: [String: HollerKitFieldValue]
    public var metadata: [String: String]
    public var durationMs: Double?
    public var offsetSeconds: Double?
    public var startOffsetSeconds: Double?
    public var startDate: Date?

    public init(
        timestamp: Date = Date(),
        category: String? = nil,
        message: String,
        fields: [String: HollerKitFieldValue] = [:],
        metadata: [String: String] = [:],
        durationMs: Double? = nil,
        offsetSeconds: Double? = nil,
        startOffsetSeconds: Double? = nil,
        startDate: Date? = nil
    ) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.fields = fields
        self.metadata = metadata
        self.durationMs = durationMs
        self.offsetSeconds = offsetSeconds
        self.startOffsetSeconds = startOffsetSeconds
        self.startDate = startDate
    }

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
        self.fields = [:]
        self.metadata = metadata
        self.durationMs = nil
        self.offsetSeconds = offsetSeconds
        self.startOffsetSeconds = nil
        self.startDate = nil
    }
}

public struct BreadcrumbStore: Sendable {
    public private(set) var breadcrumbs: [HollerKitBreadcrumb] = []
    public private(set) var questStartedAt: Date?
    public var capacity: Int {
        didSet {
            enforceCapacity()
        }
    }
    public private(set) var truncatedCount: Int = 0

    public init(capacity: Int = 500) {
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
        if entry.startOffsetSeconds == nil, let questStartedAt, let startDate = entry.startDate {
            entry.startOffsetSeconds = max(0, startDate.timeIntervalSince(questStartedAt))
        }
        breadcrumbs.append(entry)
        enforceCapacity()
    }

    private mutating func enforceCapacity() {
        if capacity <= 0 {
            breadcrumbs.removeAll()
            truncatedCount = 0
            return
        }

        let hasMarker = !breadcrumbs.isEmpty && breadcrumbs[0].message == "breadcrumbs.truncated"
        let normalCount = hasMarker ? breadcrumbs.count - 1 : breadcrumbs.count
        let allowedNormal = max(0, capacity - 1)

        if breadcrumbs.count > capacity {
            let overflow = normalCount - allowedNormal
            if overflow > 0 {
                truncatedCount += overflow

                let truncatedCrumb = HollerKitBreadcrumb(
                    timestamp: questStartedAt ?? (breadcrumbs.first?.timestamp ?? Date()),
                    category: "hollerkit",
                    message: "breadcrumbs.truncated",
                    fields: ["dropped": .int(truncatedCount)],
                    metadata: ["truncated": "true"],
                    offsetSeconds: 0
                )

                if hasMarker {
                    breadcrumbs.removeSubrange(1...overflow)
                    breadcrumbs[0] = truncatedCrumb
                } else {
                    breadcrumbs.removeFirst(overflow)
                    breadcrumbs.insert(truncatedCrumb, at: 0)
                }
            }
        }
    }

    public func snapshot() -> [HollerKitBreadcrumb] {
        breadcrumbs
    }

    public func questEvents(since startedAt: Date) -> [FeedbackEventInput] {
        let isoFormatter = ISO8601DateFormatter()
        return breadcrumbs
            .filter { $0.timestamp >= startedAt || $0.message == "breadcrumbs.truncated" }
            .map { crumb in
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
                let startOffset = crumb.startOffsetSeconds ?? (crumb.startDate.map { max(0, $0.timeIntervalSince(startedAt)) })
                if let startOffset {
                    payload.startOffsetSeconds = startOffset
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
