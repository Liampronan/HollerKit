import Foundation

public struct HollerKitBreadcrumb: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var category: String?
    public var message: String
    public var metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        category: String? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

public struct BreadcrumbStore: Sendable {
    public private(set) var breadcrumbs: [HollerKitBreadcrumb] = []
    public var capacity: Int

    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    public mutating func append(_ breadcrumb: HollerKitBreadcrumb) {
        breadcrumbs.append(breadcrumb)
        if breadcrumbs.count > capacity {
            breadcrumbs.removeFirst(breadcrumbs.count - capacity)
        }
    }

    public func snapshot() -> [HollerKitBreadcrumb] {
        breadcrumbs
    }
}
