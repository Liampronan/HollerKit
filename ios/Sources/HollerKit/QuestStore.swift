import CryptoKit
import Foundation
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

    public func saveCachedBoardItems(_ items: [QuestBoardItem], forBuild build: String) {
        try? FileManager.default.createDirectory(
            at: cacheDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        let fileURL = cacheFileURL(forBuild: build)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func loadCachedBoardItems(forBuild build: String) -> [QuestBoardItem] {
        let fileURL = cacheFileURL(forBuild: build)
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([QuestBoardItem].self, from: data) else {
            return []
        }
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

@MainActor
public final class HollerKitQuestState: ObservableObject {
    @Published public private(set) var pendingCount: Int = 0
    @Published public private(set) var quests: [QuestBoardItem] = []
    @Published public private(set) var activeQuest: ActiveQuestSession?
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var isBackendReachable: Bool = true
    @Published public private(set) var lastSyncError: String?

    private var definitions: [QuestDefinition] = []
    private var store = QuestStore()
    private var localStatusOverrides: [String: QuestStatus] = [:]
    private var localLatestRunOverrides: [String: QuestLatestRun] = [:]
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
        self.store = QuestStore(
            cacheDirectoryURL: cacheDirectoryURL,
            serverIdentity: serverURL?.absoluteString
        )
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
            let localItems = store.buildLocalBoardItems(
                from: loaded,
                build: build,
                isBackendReachable: isBackendReachable
            )
            applyBoardItems(localItems, build: build)
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
            applyBoardItems(syncedItems, build: build)
        } catch {
            guard configurationGeneration == generation, HollerKit.isEnabled else {
                return
            }
            isBackendReachable = false
            lastSyncError = error.localizedDescription
            let fallbackItems = store.buildLocalBoardItems(
                from: definitionsSnapshot,
                build: build,
                isBackendReachable: false
            )
            applyBoardItems(fallbackItems, build: build)
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
        endedAt: Date = Date(),
        clearActiveSessionImmediately: Bool = true,
        onProgress: (@Sendable (SubmissionProgressStage) async -> Void)? = nil
    ) async throws -> OutboxSubmissionOutcome {
        guard HollerKit.reconcileEnablement(),
              let session = activeQuest,
              let config = HollerKit.currentConfiguration else {
            throw HollerKitAPIError.missingAuthToken
        }

        let metadata = MetadataCollector.collect(extra: config.metadata())
        let build = MetadataCollector.currentBuild(from: metadata)
        let appVersion = MetadataCollector.currentAppVersion(from: metadata)
        let device = metadata["deviceModel"]
        let os = metadata["osVersion"]

        var events = HollerKit.currentBreadcrumbs.questEvents(since: session.startedAt)
        for mark in session.marks {
            events.append(FeedbackEventInput(
                offsetSeconds: mark.offsetSeconds,
                kind: "mark",
                payload: ["label": mark.label, "markId": mark.id.uuidString.lowercased()]
            ))
        }
        events.sort { $0.offsetSeconds < $1.offsetSeconds }

        let attachments: [OutboxAttachmentPayload] = session.marks.compactMap { mark in
            guard !mark.imageData.isEmpty else { return nil }
            return OutboxAttachmentPayload(
                kind: "mark",
                mimeType: "image/png",
                data: mark.imageData,
                offsetSeconds: mark.offsetSeconds
            )
        }

        let isoFormatter = ISO8601DateFormatter()
        let trimmedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)

        let request = FeedbackSubmissionRequest(
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

        let client = APIClient(configuration: config)
        let unconfirmedManifestEntry = session.quest.isVersionConfirmed
            ? nil
            : session.quest.definition.toManifestEntry()

        let outcome = try await HollerKit.currentOutboxStore.submit(
            request: request,
            attachments: attachments,
            questManifestEntry: unconfirmedManifestEntry,
            using: client,
            onProgress: onProgress
        )

        recordLocalResult(
            result,
            forQuestId: session.quest.id,
            contentHash: session.quest.contentHash,
            build: build,
            comment: request.comment ?? request.transcript,
            endedAt: endedAt
        )
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

    public func recordLocalResult(
        _ result: QuestResult,
        forQuestId questId: String,
        contentHash: String? = nil,
        build: String,
        comment: String? = nil,
        endedAt: Date = Date()
    ) {
        let normalizedId = questId.jsTrimmed
        guard let index = quests.firstIndex(where: { $0.id == normalizedId }) else { return }
        var item = quests[index]
        if let contentHash, item.contentHash != contentHash {
            return
        }
        switch result {
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
            if item.status != .passed, item.status != .failed {
                item.status = .unsure
            }
        case .abandoned:
            item.counts.abandoned += 1
        }
        let key = "\(build):\(item.id):\(item.contentHash)"
        if result != .abandoned {
            let isoFormatter = ISO8601DateFormatter()
            let latestRun = QuestLatestRun(
                result: result,
                build: build,
                createdAt: isoFormatter.string(from: endedAt),
                comment: comment,
                triageStatus: (result == .fail || result == .unsure) ? "new" : nil
            )
            item.latestRun = latestRun
            localLatestRunOverrides[key] = latestRun
        }
        if item.status == .passed || item.status == .failed || item.status == .unsure {
            localStatusOverrides[key] = item.status
        }
        quests[index] = item
        applyBoardItems(quests, build: build)
    }

    private func applyBoardItems(_ items: [QuestBoardItem], build: String) {
        let clearedTriageStatuses: Set<String> = ["resolved", "wontfix", "duplicate"]
        let merged = items.map { rawItem -> QuestBoardItem in
            var item = rawItem
            let key = "\(build):\(item.id):\(item.contentHash)"
            let isServerClearedByTriage = item.latestRun?.triageStatus.map { clearedTriageStatuses.contains($0) } ?? false
            if isServerClearedByTriage {
                localStatusOverrides.removeValue(forKey: key)
            } else if let overrideStatus = localStatusOverrides[key] {
                if overrideStatus == .passed {
                    item.status = .passed
                } else if overrideStatus == .failed, (item.status == .pending || item.status == .unsure) {
                    item.status = .failed
                } else if overrideStatus == .unsure, item.status == .pending {
                    item.status = .unsure
                }
            }
            if item.latestRun == nil, let overrideRun = localLatestRunOverrides[key] {
                item.latestRun = overrideRun
            }
            return item
        }
        self.quests = merged
        self.pendingCount = merged.filter { $0.status != .passed }.count
        store.saveCachedBoardItems(merged, forBuild: build)
    }
}
