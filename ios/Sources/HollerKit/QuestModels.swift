import CryptoKit
import Foundation

extension String {
    /// Trims leading and trailing whitespace matching ECMAScript `String.prototype.trim()`,
    /// which preserves `U+0085` (Next Line) unlike `CharacterSet.whitespacesAndNewlines`.
    var jsTrimmed: String {
        trimmingCharacters(in: Self.jsWhitespaceAndLineTerminators)
    }

    private static let jsWhitespaceAndLineTerminators: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.remove(charactersIn: "\u{0085}")
        return set
    }()
}

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
    case unsure

    /// Sort priority for the Pending tab (`pending` / untried first, then `unsure`, then `failed`).
    public var pendingSortRank: Int {
        switch self {
        case .pending:
            return 0
        case .unsure:
            return 1
        case .failed:
            return 2
        case .passed:
            return 3
        }
    }
}

public struct QuestLatestRun: Codable, Equatable, Sendable {
    public var id: String?
    public var result: QuestResult
    public var build: String
    public var createdAt: String
    public var comment: String?
    public var triageStatus: String?

    public init(
        id: String? = nil,
        result: QuestResult,
        build: String,
        createdAt: String,
        comment: String? = nil,
        triageStatus: String? = nil
    ) {
        self.id = id
        self.result = result
        self.build = build
        self.createdAt = createdAt
        let trimmedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.comment = (trimmedComment?.isEmpty == false) ? trimmedComment : nil
        self.triageStatus = triageStatus
    }

    public var firstCommentLine: String? {
        guard let comment, !comment.isEmpty else { return nil }
        let line = comment
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return line
    }

    public var resultSummaryLabel: String {
        switch result {
        case .pass:
            return "Passed"
        case .fail:
            return "Failed"
        case .unsure:
            return "Unsure"
        case .abandoned:
            return "Abandoned"
        }
    }

    public func formattedSummary(relativeTo referenceDate: Date = Date()) -> String {
        var parts: [String] = [resultSummaryLabel]
        if !build.isEmpty {
            parts.append("build \(build)")
        }
        if let runDate = Self.parseISO8601(createdAt) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relative = formatter.localizedString(for: runDate, relativeTo: referenceDate)
            parts.append(relative)
        }
        if triageStatus == "triaged" {
            parts.append("Triaged")
        }
        return parts.joined(separator: " · ")
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
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
        self.id = id.jsTrimmed
        self.title = title.jsTrimmed
        self.area = area.jsTrimmed
        self.setup = setup.map(\.jsTrimmed)
        self.steps = steps.map(\.jsTrimmed)
        self.expect = expect.map(\.jsTrimmed)
        self.needs = needs.map(\.jsTrimmed)
        self.record = record
        let trimmedStart = start?.jsTrimmed
        self.start = (trimmedStart?.isEmpty == false) ? trimmedStart : nil
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
        let rawId = try container.decode(String.self, forKey: .id)
        let rawTitle = try container.decode(String.self, forKey: .title)
        let rawArea = try container.decode(String.self, forKey: .area)
        let rawSetup = try container.decodeIfPresent([String].self, forKey: .setup) ?? []
        let rawSteps = try container.decode([String].self, forKey: .steps)
        let rawExpect = try container.decode([String].self, forKey: .expect)
        let rawNeeds = try container.decodeIfPresent([String].self, forKey: .needs) ?? []
        let rawRecord = try container.decodeIfPresent(QuestRecordMode.self, forKey: .record) ?? .optional
        let rawStart = try container.decodeIfPresent(String.self, forKey: .start)
        let rawSource = try container.decodeIfPresent(QuestManifestSource.self, forKey: .source)

        self.init(
            id: rawId,
            title: rawTitle,
            area: rawArea,
            setup: rawSetup,
            steps: rawSteps,
            expect: rawExpect,
            needs: rawNeeds,
            record: rawRecord,
            start: rawStart,
            source: rawSource
        )
    }

    public var contentHash: String {
        computeQuestContentHash(self)
    }

    public func toManifestEntry() -> QuestManifestEntry {
        let trimmedStart = start?.jsTrimmed
        return QuestManifestEntry(
            id: id.jsTrimmed,
            contentHash: contentHash,
            title: title.jsTrimmed,
            area: area.jsTrimmed,
            setup: setup.map(\.jsTrimmed),
            steps: steps.map(\.jsTrimmed),
            expect: expect.map(\.jsTrimmed),
            needs: needs.map(\.jsTrimmed),
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
    let trimmedStart = quest.start?.jsTrimmed
    let normalizedStart = (trimmedStart?.isEmpty == false) ? trimmedStart : nil

    let payload = CanonicalQuestPayload(
        area: quest.area.jsTrimmed,
        expect: quest.expect.map(\.jsTrimmed),
        needs: quest.needs.map(\.jsTrimmed),
        record: quest.record.rawValue,
        setup: quest.setup.map(\.jsTrimmed),
        start: normalizedStart,
        steps: quest.steps.map(\.jsTrimmed),
        title: quest.title.jsTrimmed
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
    public var isVersionConfirmed: Bool
    public var contentHash: String
    public var definition: QuestDefinition
    public var status: QuestStatus
    public var questStatus: String
    public var counts: QuestResultCounts
    public var latestRun: QuestLatestRun?
    public var needWarnings: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case isVersionConfirmed
        case contentHash
        case definition
        case status
        case questStatus
        case counts
        case latestRun
        case needWarnings
    }

    public init(
        id: String,
        version: Int = 1,
        isVersionConfirmed: Bool = true,
        contentHash: String? = nil,
        definition: QuestDefinition,
        status: QuestStatus = .pending,
        questStatus: String = "active",
        counts: QuestResultCounts = QuestResultCounts(),
        latestRun: QuestLatestRun? = nil,
        needWarnings: [String] = []
    ) {
        self.id = id.jsTrimmed
        self.version = version
        self.isVersionConfirmed = isVersionConfirmed
        self.contentHash = contentHash ?? definition.contentHash
        self.definition = definition
        self.status = status
        self.questStatus = questStatus
        self.counts = counts
        self.latestRun = latestRun
        self.needWarnings = needWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try container.decode(String.self, forKey: .id)
        self.id = rawId.jsTrimmed
        self.version = try container.decode(Int.self, forKey: .version)
        self.isVersionConfirmed = try container.decodeIfPresent(Bool.self, forKey: .isVersionConfirmed) ?? true
        self.contentHash = try container.decode(String.self, forKey: .contentHash)
        self.definition = try container.decode(QuestDefinition.self, forKey: .definition)
        self.status = try container.decode(QuestStatus.self, forKey: .status)
        self.questStatus = try container.decode(String.self, forKey: .questStatus)
        self.counts = try container.decode(QuestResultCounts.self, forKey: .counts)
        self.latestRun = try container.decodeIfPresent(QuestLatestRun.self, forKey: .latestRun)
        self.needWarnings = try container.decodeIfPresent([String].self, forKey: .needWarnings) ?? []
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
