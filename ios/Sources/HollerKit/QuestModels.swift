import CryptoKit
import Foundation

public enum QuestRecordMode: String, Codable, CaseIterable, Sendable {
    case none
    case optional
    case suggested
    case required
}

public enum QuestStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case passed
    case failed
}

public enum QuestResult: String, Codable, CaseIterable, Sendable {
    case pass
    case fail
    case unsure
    case abandoned

    public var displayTitle: String {
        switch self {
        case .pass:
            return "Pass"
        case .fail:
            return "Fail"
        case .unsure:
            return "Something's Off"
        case .abandoned:
            return "Abandon"
        }
    }
}

public struct QuestDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var area: String
    public var setup: [String]
    public var steps: [String]
    public var expect: [String]
    public var needs: [String]
    public var record: QuestRecordMode
    public var start: String?
    public var source: QuestManifestSource?

    public init(
        id: String,
        title: String,
        area: String,
        setup: [String] = [],
        steps: [String],
        expect: [String],
        needs: [String] = [],
        record: QuestRecordMode = .optional,
        start: String? = nil,
        source: QuestManifestSource? = nil
    ) {
        self.id = id
        self.title = title
        self.area = area
        self.setup = setup
        self.steps = steps
        self.expect = expect
        self.needs = needs
        self.record = record
        self.start = start
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case area
        case setup
        case steps
        case expect
        case needs
        case record
        case start
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.area = try container.decode(String.self, forKey: .area)
        self.setup = try container.decodeIfPresent([String].self, forKey: .setup) ?? []
        self.steps = try container.decode([String].self, forKey: .steps)
        self.expect = try container.decode([String].self, forKey: .expect)
        self.needs = try container.decodeIfPresent([String].self, forKey: .needs) ?? []
        self.record = try container.decodeIfPresent(QuestRecordMode.self, forKey: .record) ?? .optional
        self.start = try container.decodeIfPresent(String.self, forKey: .start)
        self.source = try container.decodeIfPresent(QuestManifestSource.self, forKey: .source)
    }

    public var contentHash: String {
        computeQuestContentHash(self)
    }

    public func toManifestEntry() -> QuestManifestEntry {
        let trimmedStart = start?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuestManifestEntry(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            contentHash: contentHash,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            area: area.trimmingCharacters(in: .whitespacesAndNewlines),
            setup: setup.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            steps: steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            expect: expect.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            needs: needs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            record: record.rawValue,
            start: (trimmedStart?.isEmpty == false) ? trimmedStart : nil,
            source: source
        )
    }
}

public struct QuestManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var quests: [QuestDefinition]

    public init(version: Int = 1, quests: [QuestDefinition]) {
        self.version = version
        self.quests = quests
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case quests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.quests = try container.decode([QuestDefinition].self, forKey: .quests)
    }
}

private struct CanonicalQuestPayload: Encodable {
    var area: String
    var expect: [String]
    var needs: [String]
    var record: String
    var setup: [String]
    var start: String?
    var steps: [String]
    var title: String

    private enum CodingKeys: String, CodingKey {
        case area
        case expect
        case needs
        case record
        case setup
        case start
        case steps
        case title
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(area, forKey: .area)
        try container.encode(expect, forKey: .expect)
        try container.encode(needs, forKey: .needs)
        try container.encode(record, forKey: .record)
        try container.encode(setup, forKey: .setup)
        if let start {
            try container.encode(start, forKey: .start)
        } else {
            try container.encodeNil(forKey: .start)
        }
        try container.encode(steps, forKey: .steps)
        try container.encode(title, forKey: .title)
    }
}

public func canonicalQuestJSON(_ quest: QuestDefinition) -> String {
    let trimmedStart = quest.start?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedStart = (trimmedStart?.isEmpty == false) ? trimmedStart : nil

    let payload = CanonicalQuestPayload(
        area: quest.area.trimmingCharacters(in: .whitespacesAndNewlines),
        expect: quest.expect.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
        needs: quest.needs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
        record: quest.record.rawValue,
        setup: quest.setup.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
        start: normalizedStart,
        steps: quest.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
        title: quest.title.trimmingCharacters(in: .whitespacesAndNewlines)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(payload)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Computes the canonical SHA-256 hex digest of a quest's functional definition,
/// matching `computeQuestContentHash` in `QUEST_PROTOCOL.md`.
public func computeQuestContentHash(_ quest: QuestDefinition) -> String {
    let json = canonicalQuestJSON(quest)
    let digest = SHA256.hash(data: Data(json.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

public struct QuestBoardItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var version: Int
    public var contentHash: String
    public var definition: QuestDefinition
    public var status: QuestStatus
    public var questStatus: String
    public var counts: QuestResultCounts
    public var needWarnings: [String]

    public init(
        id: String,
        version: Int = 1,
        contentHash: String? = nil,
        definition: QuestDefinition,
        status: QuestStatus = .pending,
        questStatus: String = "active",
        counts: QuestResultCounts = QuestResultCounts(),
        needWarnings: [String] = []
    ) {
        self.id = id
        self.version = version
        self.contentHash = contentHash ?? definition.contentHash
        self.definition = definition
        self.status = status
        self.questStatus = questStatus
        self.counts = counts
        self.needWarnings = needWarnings
    }
}

public struct QuestMarkCapture: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var offsetSeconds: Double
    public var createdAt: Date
    public var label: String
    public var imageData: Data

    public init(
        id: UUID = UUID(),
        offsetSeconds: Double,
        createdAt: Date = Date(),
        label: String,
        imageData: Data
    ) {
        self.id = id
        self.offsetSeconds = offsetSeconds
        self.createdAt = createdAt
        self.label = label
        self.imageData = imageData
    }
}

public struct ActiveQuestSession: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var quest: QuestBoardItem
    public var startedAt: Date
    public var stepsChecked: [Bool]
    public var marks: [QuestMarkCapture]
    public var isOverlayExpanded: Bool
    public var isPresentingResultSheet: Bool

    public init(
        id: UUID = UUID(),
        quest: QuestBoardItem,
        startedAt: Date = Date(),
        stepsChecked: [Bool]? = nil,
        marks: [QuestMarkCapture] = [],
        isOverlayExpanded: Bool = false,
        isPresentingResultSheet: Bool = false
    ) {
        self.id = id
        self.quest = quest
        self.startedAt = startedAt
        self.stepsChecked = stepsChecked ?? Array(repeating: false, count: quest.definition.steps.count)
        self.marks = marks
        self.isOverlayExpanded = isOverlayExpanded
        self.isPresentingResultSheet = isPresentingResultSheet
    }

    public func elapsedSeconds(at date: Date = Date()) -> Double {
        max(0, date.timeIntervalSince(startedAt))
    }
}
