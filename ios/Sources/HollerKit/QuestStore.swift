import CryptoKit
import Foundation
import Observation
import SwiftUI

public enum QuestStoreError: Error, LocalizedError, Sendable, Equatable {
    case manifestNotFound(String)
    case invalidManifestData(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound(let name):
            return "Could not find quest manifest resource '\(name)'."
        case .invalidManifestData(let reason):
            return "Invalid quest manifest JSON: \(reason)"
        }
    }
}

public struct OptimisticQuestRunRecord: Codable, Equatable, Sendable {
    public var feedbackId: UUID?
    public var build: String
    public var questKey: String
    public var questId: String
    public var contentHash: String
    public var result: QuestResult
    public var latestRun: QuestLatestRun?
    public var createdAt: Date

    public init(
        feedbackId: UUID? = nil,
        build: String,
        questKey: String,
        questId: String,
        contentHash: String,
        result: QuestResult,
        latestRun: QuestLatestRun? = nil,
        createdAt: Date = Date()
    ) {
        self.feedbackId = feedbackId
        self.build = build
        self.questKey = questKey
        self.questId = questId.jsTrimmed
        self.contentHash = contentHash
        self.result = result
        self.latestRun = latestRun
        self.createdAt = createdAt
    }
}

public struct QuestBoardCachePayload: Codable, Equatable, Sendable {
    public var items: [QuestBoardItem]
    public var confirmedItems: [QuestBoardItem]
    public var optimisticRuns: [OptimisticQuestRunRecord]

    public init(
        items: [QuestBoardItem] = [],
        confirmedItems: [QuestBoardItem] = [],
        optimisticRuns: [OptimisticQuestRunRecord] = []
    ) {
        self.items = items
        self.confirmedItems = confirmedItems
        self.optimisticRuns = optimisticRuns
    }
}

public struct QuestStore: Sendable {
    public var cacheDirectoryURL: URL
    public var serverIdentity: String?

    public init(cacheDirectoryURL: URL? = nil, serverIdentity: String? = nil) {
        if let cacheDirectoryURL {
            self.cacheDirectoryURL = cacheDirectoryURL
        } else {
            self.cacheDirectoryURL = Self.defaultCacheDirectoryURL()
        }
        self.serverIdentity = serverIdentity
    }

    public static func defaultCacheDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("HollerKit", isDirectory: true)
            .appendingPathComponent("QuestCache", isDirectory: true)
    }

    public static var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    public static func evaluateNeedWarnings(
        for needs: [String],
        isSimulator: Bool = Self.isRunningOnSimulator,
        isBackendReachable: Bool = true
    ) -> [String] {
        var warnings: [String] = []
        for rawNeed in needs {
            let need = rawNeed.jsTrimmed.lowercased()
            guard !need.isEmpty else { continue }
            switch need {
            case "device":
                if isSimulator {
                    warnings.append("Requires physical device")
                }
            case "backend":
                if !isBackendReachable {
                    warnings.append("Requires reachable backend")
                }
            default:
                warnings.append("Requires \(rawNeed.jsTrimmed)")
            }
        }
        return warnings
    }

    public func loadManifest(from configuration: HollerKitQuestsConfiguration) throws -> [QuestDefinition] {
        switch configuration.manifestSource {
        case .definitions(let definitions):
            try Self.validateUniqueQuestIds(in: definitions)
            return definitions
        case .fileURL(let url):
            let data = try Data(contentsOf: url)
            return try Self.decodeDefinitions(from: data)
        case .bundled(let resourceName):
            let cleanedName: String
            if resourceName.lowercased().hasSuffix(".json") {
                cleanedName = String(resourceName.dropLast(5))
            } else {
                cleanedName = resourceName
            }
            guard let url = configuration.bundle.url(forResource: cleanedName, withExtension: "json") else {
                throw QuestStoreError.manifestNotFound(resourceName)
            }
            let data = try Data(contentsOf: url)
            return try Self.decodeDefinitions(from: data)
        }
    }

    public static func decodeDefinitions(from data: Data) throws -> [QuestDefinition] {
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(QuestManifest.self, from: data) {
            try validateUniqueQuestIds(in: manifest.quests)
            return manifest.quests
        }
        if let array = try? decoder.decode([QuestDefinition].self, from: data) {
            try validateUniqueQuestIds(in: array)
            return array
        }
        throw QuestStoreError.invalidManifestData("Expected a QuestManifest object or array of QuestDefinitions.")
    }

    public static func validateUniqueQuestIds(in definitions: [QuestDefinition]) throws {
        var seen: Set<String> = []
        for definition in definitions {
            let id = definition.id.jsTrimmed
            if id.isEmpty {
                throw QuestStoreError.invalidManifestData("Quest id must not be empty.")
            }
            if !seen.insert(id).inserted {
                throw QuestStoreError.invalidManifestData("Duplicate quest id '\(id)' in manifest.")
            }
        }
    }

    public func buildLocalBoardItems(
        from definitions: [QuestDefinition],
        build: String,
        isSimulator: Bool = Self.isRunningOnSimulator,
        isBackendReachable: Bool = true
    ) -> [QuestBoardItem] {
        let cached = loadCachedBoardItems(forBuild: build)
        return Self.resolveBoardItems(
            from: definitions,
            cached: cached,
            isSimulator: isSimulator,
            isBackendReachable: isBackendReachable
        )
    }

    public func buildConfirmedLocalBoardItems(
        from definitions: [QuestDefinition],
        build: String,
        isSimulator: Bool = Self.isRunningOnSimulator,
        isBackendReachable: Bool = true
    ) -> [QuestBoardItem] {
        let payload = loadCachedBoardPayload(forBuild: build)
        return Self.resolveBoardItems(
            from: definitions,
            cached: payload.confirmedItems,
            isSimulator: isSimulator,
            isBackendReachable: isBackendReachable
        )
    }

    private static func resolveBoardItems(
        from definitions: [QuestDefinition],
        cached: [QuestBoardItem],
        isSimulator: Bool,
        isBackendReachable: Bool
    ) -> [QuestBoardItem] {
        let cachedByHash = Dictionary(
            cached.map { ("\($0.id.jsTrimmed):\($0.contentHash)", $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var maxVersionById: [String: Int] = [:]
        for item in cached {
            let normalizedId = item.id.jsTrimmed
            maxVersionById[normalizedId] = max(maxVersionById[normalizedId] ?? 0, item.version)
        }

        return definitions.map { definition in
            let normalizedId = definition.id.jsTrimmed
            let hash = definition.contentHash
            let key = "\(normalizedId):\(hash)"
            let cachedItem = cachedByHash[key]
            let warnings = Self.evaluateNeedWarnings(
                for: definition.needs,
                isSimulator: isSimulator,
                isBackendReachable: isBackendReachable
            )
            let resolvedVersion: Int
            let isVersionConfirmed: Bool
            if let cachedItem {
                resolvedVersion = cachedItem.version
                isVersionConfirmed = cachedItem.isVersionConfirmed
            } else if let priorMaxVersion = maxVersionById[normalizedId] {
                resolvedVersion = priorMaxVersion + 1
                isVersionConfirmed = false
            } else {
                resolvedVersion = 1
                isVersionConfirmed = false
            }
            return QuestBoardItem(
                id: normalizedId,
                version: resolvedVersion,
                isVersionConfirmed: isVersionConfirmed,
                contentHash: hash,
                definition: definition,
                status: cachedItem?.status ?? .pending,
                questStatus: cachedItem?.questStatus ?? "active",
                counts: cachedItem?.counts ?? QuestResultCounts(),
                latestRun: cachedItem?.latestRun,
                needWarnings: warnings
            )
        }
    }

    public func syncWithServer(
        definitions: [QuestDefinition],
        build: String,
        appVersion: String?,
        client: APIClient,
        isSimulator: Bool = Self.isRunningOnSimulator,
        persistToCache: Bool = true
    ) async throws -> [QuestBoardItem] {
        try Self.validateUniqueQuestIds(in: definitions)
        let entries = definitions.map { $0.toManifestEntry() }
        let response = try await client.syncBuildManifest(
            build: build,
            appVersion: appVersion,
            quests: entries
        )

        let definitionsById = Dictionary(
            definitions.map { ($0.id.jsTrimmed, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let items: [QuestBoardItem] = response.quests.map { serverItem in
            let normalizedServerId = serverItem.id.jsTrimmed
            let definition = definitionsById[normalizedServerId] ?? QuestDefinition(
                id: normalizedServerId,
                title: serverItem.title,
                area: serverItem.area,
                setup: serverItem.setup,
                steps: serverItem.steps,
                expect: serverItem.expect,
                needs: serverItem.needs,
                record: QuestRecordMode(rawValue: serverItem.record) ?? .optional,
                start: serverItem.start,
                source: serverItem.source
            )
            let warnings = Self.evaluateNeedWarnings(
                for: definition.needs,
                isSimulator: isSimulator,
                isBackendReachable: true
            )
            let counts = serverItem.counts ?? QuestResultCounts()
            var status = QuestStatus(rawValue: serverItem.boardStatus) ?? .pending
            if status == .failed, counts.fail == 0, counts.unsure > 0 {
                status = .unsure
            }
            return QuestBoardItem(
                id: normalizedServerId,
                version: serverItem.version,
                isVersionConfirmed: true,
                contentHash: serverItem.contentHash,
                definition: definition,
                status: status,
                questStatus: serverItem.questStatus,
                counts: counts,
                latestRun: serverItem.latestRun,
                needWarnings: warnings
            )
        }

        if persistToCache {
            saveCachedBoardItems(items, forBuild: build)
        }
        return items
    }

    public func boardItems(
        from pendingItems: [PendingQuestItem],
        definitions: [QuestDefinition] = [],
        isSimulator: Bool = Self.isRunningOnSimulator
    ) -> [QuestBoardItem] {
        let definitionsById = Dictionary(
            definitions.map { ($0.id.jsTrimmed, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return pendingItems.map { serverItem in
            let normalizedServerId = serverItem.id.jsTrimmed
            let definition = definitionsById[normalizedServerId] ?? QuestDefinition(
                id: normalizedServerId,
                title: serverItem.title,
                area: serverItem.area,
                setup: serverItem.setup,
                steps: serverItem.steps,
                expect: serverItem.expect,
                needs: serverItem.needs,
                record: QuestRecordMode(rawValue: serverItem.record) ?? .optional,
                start: serverItem.start,
                source: serverItem.source
            )
            let warnings = Self.evaluateNeedWarnings(
                for: definition.needs,
                isSimulator: isSimulator,
                isBackendReachable: true
            )
            let counts = serverItem.counts ?? QuestResultCounts()
            var status: QuestStatus
            if let rawBoardStatus = serverItem.boardStatus,
               let parsed = QuestStatus(rawValue: rawBoardStatus) {
                status = parsed
            } else if serverItem.passedOnCurrentVersion == true {
                status = .passed
            } else if counts.fail > 0 {
                status = .failed
            } else if counts.unsure > 0 {
                status = .unsure
            } else {
                status = .pending
            }
            if status == .failed, counts.fail == 0, counts.unsure > 0 {
                status = .unsure
            }
            return QuestBoardItem(
                id: normalizedServerId,
                version: serverItem.version,
                isVersionConfirmed: true,
                contentHash: serverItem.contentHash,
                definition: definition,
                status: status,
                questStatus: serverItem.status,
                counts: counts,
                latestRun: serverItem.latestRun,
                needWarnings: warnings
            )
        }
    }

    public func fetchPendingBoardItems(
        build: String,
        client: APIClient,
        definitions: [QuestDefinition] = [],
        isSimulator: Bool = Self.isRunningOnSimulator,
        persistToCache: Bool = false
    ) async throws -> [QuestBoardItem] {
        let pendingItems = try await client.fetchPendingQuests(build: build)
        let items = boardItems(
            from: pendingItems,
            definitions: definitions,
            isSimulator: isSimulator
        )
        if persistToCache {
            saveCachedBoardItems(items, forBuild: build)
        }
        return items
    }

    public func saveCachedBoardPayload(_ payload: QuestBoardCachePayload, forBuild build: String) {
        try? FileManager.default.createDirectory(
            at: cacheDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let deduplicatedPayload = QuestBoardCachePayload(
            items: Self.deduplicateBoardItems(payload.items),
            confirmedItems: Self.deduplicateBoardItems(payload.confirmedItems),
            optimisticRuns: payload.optimisticRuns
        )
        guard let data = try? encoder.encode(deduplicatedPayload) else { return }
        let fileURL = cacheFileURL(forBuild: build)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func loadCachedBoardPayload(forBuild build: String) -> QuestBoardCachePayload {
        let fileURL = cacheFileURL(forBuild: build)
        guard let data = try? Data(contentsOf: fileURL) else {
            return QuestBoardCachePayload()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let payload = try? decoder.decode(QuestBoardCachePayload.self, from: data) {
            return QuestBoardCachePayload(
                items: Self.deduplicateBoardItems(payload.items),
                confirmedItems: Self.deduplicateBoardItems(payload.confirmedItems),
                optimisticRuns: payload.optimisticRuns
            )
        }
        if let legacyItems = try? JSONDecoder().decode([QuestBoardItem].self, from: data) {
            let deduplicated = Self.deduplicateBoardItems(legacyItems)
            return QuestBoardCachePayload(
                items: deduplicated,
                confirmedItems: deduplicated,
                optimisticRuns: []
            )
        }
        return QuestBoardCachePayload()
    }

    public func saveCachedBoardItems(_ items: [QuestBoardItem], forBuild build: String) {
        let existing = loadCachedBoardPayload(forBuild: build)
        saveCachedBoardPayload(
            QuestBoardCachePayload(
                items: items,
                confirmedItems: items,
                optimisticRuns: existing.optimisticRuns
            ),
            forBuild: build
        )
    }

    public func loadCachedBoardItems(forBuild build: String) -> [QuestBoardItem] {
        loadCachedBoardPayload(forBuild: build).items
    }

    private static func deduplicateBoardItems(_ items: [QuestBoardItem]) -> [QuestBoardItem] {
        var seen: Set<String> = []
        var deduplicated: [QuestBoardItem] = []
        for item in items.reversed() {
            let key = "\(item.id.jsTrimmed):\(item.contentHash)"
            if seen.insert(key).inserted {
                deduplicated.append(item)
            }
        }
        return deduplicated.reversed()
    }

    private func cacheFileURL(forBuild build: String) -> URL {
        let safeBuild = build.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        if let serverIdentity, !serverIdentity.isEmpty {
            let normalizedServer = serverIdentity.replacingOccurrences(
                of: "/+$",
                with: "",
                options: .regularExpression
            )
            let digest = SHA256.hash(data: Data(normalizedServer.utf8))
            let serverPrefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
            return cacheDirectoryURL.appendingPathComponent("board-\(serverPrefix)-\(safeBuild).json", isDirectory: false)
        }
        return cacheDirectoryURL.appendingPathComponent("board-\(safeBuild).json", isDirectory: false)
    }
}

@Observable
@MainActor
public final class HollerKitQuestState {
    public private(set) var pendingCount: Int = 0
    public private(set) var quests: [QuestBoardItem] = []
    public private(set) var activeQuest: ActiveQuestSession?
    public private(set) var isSyncing: Bool = false
    public private(set) var isBackendReachable: Bool = true
    public private(set) var lastSyncError: String?

    @ObservationIgnored
    private var definitions: [QuestDefinition] = []
    @ObservationIgnored
    private var store = QuestStore()
    @ObservationIgnored
    private var currentBuild: String = "0"
    @ObservationIgnored
    private var confirmedBoardItemsByQuestKey: [String: QuestBoardItem] = [:]
    @ObservationIgnored
    private var optimisticRuns: [OptimisticQuestRunRecord] = []
    @ObservationIgnored
    private var localStatusOverrides: [String: QuestStatus] = [:]
    @ObservationIgnored
    private var localLatestRunOverrides: [String: QuestLatestRun] = [:]
    @ObservationIgnored
    private var configurationGeneration: UInt64 = 0

    public init() {}

    /// Quests that have not yet been tried (or whose prior failed/unsure runs were cleared by triage).
    public var untriedQuests: [QuestBoardItem] {
        quests.filter { $0.status == .pending }
    }

    /// Quests that have an open unsure or failed run (`unsure` ordered ahead of `failed`).
    public var needsAttentionQuests: [QuestBoardItem] {
        quests
            .filter { $0.status == .unsure || $0.status == .failed }
            .sorted { $0.status.pendingSortRank < $1.status.pendingSortRank }
    }

    /// All non-passed quests, ordered with untried (`pending`) quests first so failed/unsure runs never crowd out untried work.
    public var pendingQuests: [QuestBoardItem] {
        untriedQuests + needsAttentionQuests
    }

    public var completedQuests: [QuestBoardItem] {
        quests.filter { $0.status == .passed }
    }

    func reset() {
        configurationGeneration &+= 1
        pendingCount = 0
        quests = []
        activeQuest = nil
        isSyncing = false
        isBackendReachable = true
        lastSyncError = nil
        definitions = []
        confirmedBoardItemsByQuestKey = [:]
        optimisticRuns = []
        localStatusOverrides = [:]
        localLatestRunOverrides = [:]
        QuestOverlayWindowManager.shared.hide()
    }

    func configure(
        questsConfiguration: HollerKitQuestsConfiguration?,
        build: String,
        cacheDirectoryURL: URL? = nil,
        serverURL: URL? = nil
    ) {
        configurationGeneration &+= 1
        self.currentBuild = build
        self.store = QuestStore(
            cacheDirectoryURL: cacheDirectoryURL,
            serverIdentity: serverURL?.absoluteString
        )
        self.confirmedBoardItemsByQuestKey = [:]
        self.optimisticRuns = []
        self.localStatusOverrides = [:]
        self.localLatestRunOverrides = [:]
        guard let questsConfiguration else {
            reset()
            return
        }

        do {
            let loaded = try store.loadManifest(from: questsConfiguration)
            self.definitions = loaded
            self.lastSyncError = nil
            let cachedPayload = store.loadCachedBoardPayload(forBuild: build)
            self.optimisticRuns = cachedPayload.optimisticRuns
            let confirmedItems = store.buildConfirmedLocalBoardItems(
                from: loaded,
                build: build,
                isBackendReachable: isBackendReachable
            )
            for item in confirmedItems {
                let key = Self.questKey(build: build, questId: item.id, contentHash: item.contentHash)
                confirmedBoardItemsByQuestKey[key] = item
            }
            recomputeAndPersistBoardItems(forBuild: build, baseItems: confirmedItems)
        } catch {
            self.definitions = []
            self.quests = []
            self.pendingCount = 0
            self.lastSyncError = error.localizedDescription
        }
    }

    public func refresh(using configuration: HollerKitConfiguration? = nil) async {
        guard let config = configuration ?? HollerKit.currentConfiguration,
              config.isEnabled(),
              let questsConfig = config.quests else {
            return
        }

        let generation = configurationGeneration
        let metadata = MetadataCollector.collect(extra: config.metadata())
        let build = MetadataCollector.currentBuild(from: metadata)
        let appVersion = MetadataCollector.currentAppVersion(from: metadata)
        self.currentBuild = build

        if store.serverIdentity == nil {
            store.serverIdentity = config.server.absoluteString
        }

        if definitions.isEmpty {
            do {
                definitions = try store.loadManifest(from: questsConfig)
            } catch {
                guard configurationGeneration == generation else { return }
                lastSyncError = error.localizedDescription
                return
            }
        }
        guard !definitions.isEmpty else { return }

        let definitionsSnapshot = definitions
        let storeSnapshot = store
        isSyncing = true
        defer {
            if configurationGeneration == generation {
                isSyncing = false
            }
        }

        let client = APIClient(configuration: config)
        do {
            let syncedItems = try await storeSnapshot.syncWithServer(
                definitions: definitionsSnapshot,
                build: build,
                appVersion: appVersion,
                client: client,
                persistToCache: false
            )
            guard configurationGeneration == generation, HollerKit.isEnabled else {
                return
            }
            isBackendReachable = true
            lastSyncError = nil
            applyServerConfirmedBoardItems(syncedItems, build: build)
        } catch {
            guard configurationGeneration == generation, HollerKit.isEnabled else {
                return
            }
            isBackendReachable = false
            lastSyncError = error.localizedDescription
            let fallbackItems = store.buildConfirmedLocalBoardItems(
                from: definitionsSnapshot,
                build: build,
                isBackendReachable: false
            ).map { fallbackItem -> QuestBoardItem in
                let key = Self.questKey(build: build, questId: fallbackItem.id, contentHash: fallbackItem.contentHash)
                if var existingConfirmed = confirmedBoardItemsByQuestKey[key] {
                    existingConfirmed.needWarnings = fallbackItem.needWarnings
                    confirmedBoardItemsByQuestKey[key] = existingConfirmed
                    return existingConfirmed
                }
                confirmedBoardItemsByQuestKey[key] = fallbackItem
                return fallbackItem
            }
            recomputeAndPersistBoardItems(forBuild: build, baseItems: fallbackItems)
        }
    }

    public func startQuest(_ item: QuestBoardItem, startedAt: Date = Date()) {
        guard HollerKit.isEnabled, activeQuest == nil else { return }
        let session = ActiveQuestSession(
            quest: item,
            startedAt: startedAt
        )
        activeQuest = session
        HollerKit.beginQuestBreadcrumbs(startedAt: startedAt)
        HollerKit.breadcrumb(
            "Started quest \(item.id)",
            category: "quest",
            metadata: ["questId": item.id, "questVersion": String(item.version)],
            date: startedAt
        )

        HollerKit.presenterState.isQuestsPresented = false
        HollerKit.presenterState.isPresented = false

        if let startRoute = item.definition.start?.jsTrimmed,
           !startRoute.isEmpty {
            HollerKit.currentConfiguration?.quests?.routes?(startRoute)
        }

        QuestOverlayWindowManager.shared.show(questState: self)
    }

    /// Toggles the checked state of the active quest's step at `index` and records a breadcrumb.
    public func toggleStep(at index: Int) {
        guard var session = activeQuest,
              session.stepsChecked.indices.contains(index) else {
            return
        }
        session.stepsChecked[index].toggle()
        let isChecked = session.stepsChecked[index]
        activeQuest = session
        HollerKit.breadcrumb(
            "\(isChecked ? "Checked" : "Unchecked") step \(index + 1)",
            category: "quest_step",
            metadata: ["stepIndex": String(index), "checked": String(isChecked)]
        )
    }

    /// Marks every step of the active quest as checked and records a breadcrumb.
    public func checkAllSteps() {
        guard var session = activeQuest, !session.stepsChecked.isEmpty else {
            return
        }
        guard session.stepsChecked.contains(false) else { return }
        session.stepsChecked = Array(repeating: true, count: session.stepsChecked.count)
        activeQuest = session
        HollerKit.breadcrumb(
            "Checked all \(session.stepsChecked.count) steps",
            category: "quest_step",
            metadata: ["checkedAll": "true"]
        )
    }

    public func setOverlayExpanded(_ expanded: Bool) {
        guard var session = activeQuest else { return }
        session.isOverlayExpanded = expanded
        activeQuest = session
    }

    @discardableResult
    public func captureMark(
        label: String? = nil,
        imageData: Data? = nil,
        at date: Date = Date()
    ) -> QuestMarkCapture? {
        guard var session = activeQuest else { return nil }
        let offset = session.elapsedSeconds(at: date)
        let resolvedImageData = imageData ?? QuestOverlayWindowManager.shared.captureHostScreenExcludingOverlay() ?? Data()
        let markIndex = session.marks.count + 1
        let markLabel = label ?? "Mark \(markIndex)"
        let mark = QuestMarkCapture(
            offsetSeconds: offset,
            createdAt: date,
            label: markLabel,
            imageData: resolvedImageData
        )
        session.marks.append(mark)
        activeQuest = session

        HollerKit.breadcrumb(
            "Captured \(markLabel)",
            category: "mark",
            metadata: ["label": markLabel],
            date: date
        )
        return mark
    }

    public func replaceMarkImage(id: UUID, with imageData: Data) {
        guard var session = activeQuest,
              let idx = session.marks.firstIndex(where: { $0.id == id }) else {
            return
        }
        session.marks[idx].imageData = imageData
        activeQuest = session
    }

    public func presentResultSheet() {
        guard var session = activeQuest else { return }
        session.isPresentingResultSheet = true
        activeQuest = session
    }

    public func dismissResultSheet() {
        guard var session = activeQuest else { return }
        session.isPresentingResultSheet = false
        activeQuest = session
    }

    @discardableResult
    public func abandonActiveQuest(endedAt: Date = Date()) async -> OutboxSubmissionOutcome? {
        return try? await submitActiveQuest(
            result: .abandoned,
            comment: nil,
            transcript: nil,
            endedAt: endedAt
        )
    }

    @discardableResult
    public func submitActiveQuest(
        result: QuestResult,
        comment: String?,
        transcript: HollerKitTranscript?,
        additionalAttachments: [HollerKitAttachment] = [],
        additionalOutboxAttachments: [OutboxAttachmentPayload] = [],
        endedAt: Date = Date(),
        clearActiveSessionImmediately: Bool = true,
        onProgress: (@Sendable (SubmissionProgressStage) async -> Void)? = nil
    ) async throws -> OutboxSubmissionOutcome {
        guard HollerKit.reconcileEnablement(),
              let session = activeQuest,
              let config = HollerKit.currentConfiguration else {
            throw HollerKitAPIError.missingAuthToken
        }

        var metadata = MetadataCollector.collect(extra: config.metadata())
        if let transcript {
            metadata["transcriptLocale"] = transcript.locale
            metadata["transcriptEngine"] = transcript.engine.rawValue
            if let confidence = transcript.confidence {
                metadata["transcriptConfidence"] = String(confidence)
            }
            if let durationSeconds = transcript.durationSeconds {
                metadata["transcriptDurationSeconds"] = String(durationSeconds)
            }
        }
        let build = MetadataCollector.currentBuild(from: metadata)
        let appVersion = MetadataCollector.currentAppVersion(from: metadata)
        let device = metadata["deviceModel"]
        let os = metadata["osVersion"]

        let rawQuestEvents = HollerKit.currentBreadcrumbs.questEvents(since: session.startedAt)
        var markerDroppedCount = 0
        var normalQuestEvents: [FeedbackEventInput] = []
        normalQuestEvents.reserveCapacity(rawQuestEvents.count)
        for event in rawQuestEvents {
            if event.payload["message"] == "breadcrumbs.truncated" {
                if case .int(let dropped) = event.payload.fields?["dropped"] {
                    markerDroppedCount += max(0, dropped)
                } else if let rawDropped = event.payload["dropped"], let dropped = Int(rawDropped) {
                    markerDroppedCount += max(0, dropped)
                }
                continue
            }
            normalQuestEvents.append(event)
        }

        let markEvents: [FeedbackEventInput] = session.marks.prefix(20).map { mark in
            FeedbackEventInput(
                offsetSeconds: mark.offsetSeconds,
                kind: "mark",
                payload: ["label": mark.label, "markId": mark.id.uuidString.lowercased()]
            )
        }

        let maxTotalEvents = FeedbackSubmissionRequest.maxEvents
        let events: [FeedbackEventInput]
        if markerDroppedCount == 0 && (normalQuestEvents.count + markEvents.count) <= maxTotalEvents {
            var combined = normalQuestEvents + markEvents
            combined.sort { $0.offsetSeconds < $1.offsetSeconds }
            events = combined
        } else {
            let maxNormalBreadcrumbs = max(0, maxTotalEvents - markEvents.count - 1)
            let newlyDroppedCount = max(0, normalQuestEvents.count - maxNormalBreadcrumbs)
            let totalDroppedCount = markerDroppedCount + newlyDroppedCount
            let retainedBreadcrumbs = Array(normalQuestEvents.suffix(maxNormalBreadcrumbs))
            var combined = retainedBreadcrumbs + markEvents
            combined.sort { $0.offsetSeconds < $1.offsetSeconds }

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
            events = [markerEvent] + combined
        }

        var attachments: [OutboxAttachmentPayload] = session.marks.compactMap { mark in
            guard !mark.imageData.isEmpty else { return nil }
            return OutboxAttachmentPayload(
                kind: "mark",
                mimeType: "image/png",
                data: mark.imageData,
                offsetSeconds: mark.offsetSeconds
            )
        }
        for attachment in additionalAttachments {
            attachments.append(OutboxAttachmentPayload(
                kind: "image",
                mimeType: attachment.mimeType,
                data: attachment.data
            ))
        }
        attachments.append(contentsOf: additionalOutboxAttachments)

        let isoFormatter = ISO8601DateFormatter()
        let trimmedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = FeedbackSubmissionRequest(
            id: session.id,
            kind: "quest_run",
            questId: session.quest.id,
            questVersion: session.quest.version,
            result: result.rawValue,
            build: build,
            appVersion: appVersion,
            device: device,
            os: os,
            comment: (trimmedComment?.isEmpty == false) ? trimmedComment : nil,
            transcript: transcript?.text,
            metadata: metadata,
            stepsChecked: session.stepsChecked,
            startedAt: isoFormatter.string(from: session.startedAt),
            endedAt: isoFormatter.string(from: endedAt),
            events: events
        )
        request.clampToBudget()

        let client = APIClient(configuration: config)
        let unconfirmedManifestEntry = session.quest.isVersionConfirmed
            ? nil
            : session.quest.definition.toManifestEntry()

        recordLocalResult(
            result,
            forQuestId: session.quest.id,
            contentHash: session.quest.contentHash,
            build: build,
            comment: request.comment ?? request.transcript,
            endedAt: endedAt,
            feedbackId: session.id
        )

        let outcome: OutboxSubmissionOutcome
        do {
            outcome = try await HollerKit.currentOutboxStore.submit(
                request: request,
                attachments: attachments,
                questManifestEntry: unconfirmedManifestEntry,
                using: client,
                onProgress: onProgress
            )
        } catch {
            rollbackRejectedFeedbackIds([session.id])
            throw error
        }

        HollerKit.endQuestBreadcrumbs()
        if clearActiveSessionImmediately {
            completeSubmittedSession(id: session.id)
        }

        return outcome
    }

    /// Completes teardown of an active quest session after its result confirmation has been shown.
    public func completeSubmittedSession(id: UUID) {
        if activeQuest?.id == id {
            activeQuest = nil
        }
        HollerKit.endQuestBreadcrumbs()
        if activeQuest == nil {
            QuestOverlayWindowManager.shared.hide()
        }
    }

    /// Records a local quest run result optimistically so the board updates immediately (including when queued offline).
    public func recordLocalResult(
        _ result: QuestResult,
        forQuestId questId: String,
        contentHash: String? = nil,
        build: String,
        comment: String? = nil,
        endedAt: Date = Date(),
        feedbackId: UUID? = nil
    ) {
        self.currentBuild = build
        let normalizedId = questId.jsTrimmed
        guard let index = quests.firstIndex(where: { $0.id == normalizedId }) else { return }
        let item = quests[index]
        if let contentHash, item.contentHash != contentHash {
            return
        }
        let key = Self.questKey(build: build, questId: item.id, contentHash: item.contentHash)
        if confirmedBoardItemsByQuestKey[key] == nil {
            confirmedBoardItemsByQuestKey[key] = item
        }

        let latestRun: QuestLatestRun?
        if result != .abandoned {
            let isoFormatter = ISO8601DateFormatter()
            latestRun = QuestLatestRun(
                id: feedbackId?.uuidString.lowercased(),
                result: result,
                build: build,
                createdAt: isoFormatter.string(from: endedAt),
                comment: comment,
                triageStatus: (result == .fail || result == .unsure) ? "new" : nil
            )
            localLatestRunOverrides[key] = latestRun
        } else {
            latestRun = nil
        }

        let record = OptimisticQuestRunRecord(
            feedbackId: feedbackId,
            build: build,
            questKey: key,
            questId: item.id,
            contentHash: item.contentHash,
            result: result,
            latestRun: latestRun,
            createdAt: endedAt
        )
        if let feedbackId {
            optimisticRuns.removeAll { $0.feedbackId == feedbackId }
        }
        optimisticRuns.append(record)

        recomputeAndPersistBoardItems(forBuild: build)
    }

    /// Rolls back optimistic local quest board overrides whose queued outbox submissions were permanently rejected.
    public func rollbackRejectedFeedbackIds(_ rejectedIds: Set<UUID>) {
        guard !rejectedIds.isEmpty else { return }
        let rejectedLowerStrings = Set(rejectedIds.map { $0.uuidString.lowercased() })
        var affectedBuilds: Set<String> = [currentBuild]
        var affectedKeys: Set<String> = []

        optimisticRuns.removeAll { record in
            guard let fid = record.feedbackId, rejectedIds.contains(fid) else {
                return false
            }
            affectedBuilds.insert(record.build)
            affectedKeys.insert(record.questKey)
            return true
        }

        for (key, runOverride) in localLatestRunOverrides {
            if let runId = runOverride.id?.lowercased(), rejectedLowerStrings.contains(runId) {
                affectedKeys.insert(key)
            }
        }

        for key in affectedKeys {
            let remainingForKey = optimisticRuns.filter { $0.questKey == key }
            if let lastRun = remainingForKey.compactMap(\.latestRun).last {
                localLatestRunOverrides[key] = lastRun
            } else {
                localLatestRunOverrides.removeValue(forKey: key)
            }
            if remainingForKey.isEmpty {
                localStatusOverrides.removeValue(forKey: key)
            }
        }

        for build in affectedBuilds {
            let cachedPayload = store.loadCachedBoardPayload(forBuild: build)
            let filteredCachedRuns = cachedPayload.optimisticRuns.filter { record in
                guard let fid = record.feedbackId else { return true }
                return !rejectedIds.contains(fid)
            }
            if build == currentBuild && !quests.isEmpty {
                recomputeAndPersistBoardItems(forBuild: build)
            } else if !cachedPayload.confirmedItems.isEmpty || !cachedPayload.items.isEmpty {
                let baseItems = cachedPayload.confirmedItems.isEmpty ? cachedPayload.items : cachedPayload.confirmedItems
                let recomputed = baseItems.map { baseItem in
                    let key = Self.questKey(build: build, questId: baseItem.id, contentHash: baseItem.contentHash)
                    return Self.recomputeBoardItem(
                        baseline: baseItem,
                        questKey: key,
                        optimisticRuns: filteredCachedRuns,
                        legacyStatusOverride: nil,
                        legacyLatestRunOverride: nil
                    )
                }
                store.saveCachedBoardPayload(
                    QuestBoardCachePayload(
                        items: recomputed,
                        confirmedItems: baseItems,
                        optimisticRuns: filteredCachedRuns
                    ),
                    forBuild: build
                )
            }
        }
    }

    private static func questKey(build: String, questId: String, contentHash: String) -> String {
        "\(build):\(questId.jsTrimmed):\(contentHash)"
    }

    private func applyServerConfirmedBoardItems(_ syncedItems: [QuestBoardItem], build: String) {
        let clearedTriageStatuses: Set<String> = ["resolved", "wontfix", "duplicate"]

        for serverItem in syncedItems {
            let key = Self.questKey(build: build, questId: serverItem.id, contentHash: serverItem.contentHash)
            confirmedBoardItemsByQuestKey[key] = serverItem

            let serverRun = serverItem.latestRun
            let serverRunIdLower = serverRun?.id?.lowercased()
            let serverDate = serverRun?.createdAtDate

            optimisticRuns.removeAll { run in
                guard run.questKey == key else { return false }
                if let fid = run.feedbackId?.uuidString.lowercased(),
                   let serverRunIdLower,
                   fid == serverRunIdLower {
                    return true
                }
                if let serverDate, serverDate >= run.createdAt {
                    return true
                }
                return false
            }

            let isServerClearedByTriage = serverRun?.triageStatus.map { clearedTriageStatuses.contains($0) } ?? false
            if isServerClearedByTriage {
                let hasNewerOptimistic = optimisticRuns.contains { $0.questKey == key }
                if !hasNewerOptimistic {
                    localStatusOverrides.removeValue(forKey: key)
                    localLatestRunOverrides.removeValue(forKey: key)
                }
            }
        }

        recomputeAndPersistBoardItems(forBuild: build, baseItems: syncedItems)
    }

    private func recomputeAndPersistBoardItems(
        forBuild build: String,
        baseItems: [QuestBoardItem]? = nil
    ) {
        let sourceItems = baseItems ?? quests
        var confirmedList: [QuestBoardItem] = []
        confirmedList.reserveCapacity(sourceItems.count)

        let merged = sourceItems.map { rawItem -> QuestBoardItem in
            let key = Self.questKey(build: build, questId: rawItem.id, contentHash: rawItem.contentHash)
            let baseline = confirmedBoardItemsByQuestKey[key] ?? rawItem
            confirmedBoardItemsByQuestKey[key] = baseline
            confirmedList.append(baseline)

            let recomputed = Self.recomputeBoardItem(
                baseline: baseline,
                questKey: key,
                optimisticRuns: optimisticRuns,
                legacyStatusOverride: localStatusOverrides[key],
                legacyLatestRunOverride: localLatestRunOverrides[key]
            )
            if recomputed.status == .passed || recomputed.status == .failed || recomputed.status == .unsure {
                localStatusOverrides[key] = recomputed.status
            } else {
                localStatusOverrides.removeValue(forKey: key)
            }
            return recomputed
        }

        self.quests = merged
        self.pendingCount = merged.filter { $0.status != .passed }.count
        let runsForBuild = optimisticRuns.filter { $0.build == build }
        store.saveCachedBoardPayload(
            QuestBoardCachePayload(
                items: merged,
                confirmedItems: confirmedList,
                optimisticRuns: runsForBuild
            ),
            forBuild: build
        )
    }

    private static func recomputeBoardItem(
        baseline: QuestBoardItem,
        questKey: String,
        optimisticRuns: [OptimisticQuestRunRecord],
        legacyStatusOverride: QuestStatus?,
        legacyLatestRunOverride: QuestLatestRun?
    ) -> QuestBoardItem {
        var item = baseline
        let matchingRuns = optimisticRuns.enumerated()
            .filter { $0.element.questKey == questKey }
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        if !matchingRuns.isEmpty {
            for run in matchingRuns {
                switch run.result {
                case .pass:
                    item.counts.pass += 1
                    item.status = .passed
                case .fail:
                    item.counts.fail += 1
                    if item.status != .passed {
                        item.status = .failed
                    }
                case .unsure:
                    item.counts.unsure += 1
                    if item.status != .passed && item.status != .failed {
                        item.status = .unsure
                    }
                case .abandoned:
                    item.counts.abandoned += 1
                }
                if let runLatest = run.latestRun {
                    if let existingLatest = item.latestRun,
                       let existingDate = existingLatest.createdAtDate,
                       let runDate = runLatest.createdAtDate,
                       existingDate > runDate {
                        // Keep newer existing run
                    } else {
                        item.latestRun = runLatest
                    }
                }
            }
            return item
        }

        // Legacy fallback when no OptimisticQuestRunRecord entries exist for this questKey
        if let legacyStatusOverride {
            if legacyStatusOverride == .passed {
                item.status = .passed
            } else if legacyStatusOverride == .failed, (item.status == .pending || item.status == .unsure) {
                item.status = .failed
            } else if legacyStatusOverride == .unsure, item.status == .pending {
                item.status = .unsure
            }
        }
        if let legacyLatestRunOverride {
            if let serverRun = item.latestRun,
               let localDate = legacyLatestRunOverride.createdAtDate,
               let serverDate = serverRun.createdAtDate {
                if localDate > serverDate {
                    item.latestRun = legacyLatestRunOverride
                }
            } else if item.latestRun == nil {
                item.latestRun = legacyLatestRunOverride
            }
        }
        return item
    }
}
