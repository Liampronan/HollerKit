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

    public init(cacheDirectoryURL: URL? = nil) {
        if let cacheDirectoryURL {
            self.cacheDirectoryURL = cacheDirectoryURL
        } else {
            self.cacheDirectoryURL = Self.defaultCacheDirectoryURL()
        }
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
            let need = rawNeed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
                warnings.append("Requires \(rawNeed.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return warnings
    }

    public func loadManifest(from configuration: HollerKitQuestsConfiguration) throws -> [QuestDefinition] {
        switch configuration.manifestSource {
        case .definitions(let definitions):
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
            return manifest.quests
        }
        if let array = try? decoder.decode([QuestDefinition].self, from: data) {
            return array
        }
        throw QuestStoreError.invalidManifestData("Expected a QuestManifest object or array of QuestDefinitions.")
    }

    public func buildLocalBoardItems(
        from definitions: [QuestDefinition],
        build: String,
        isSimulator: Bool = Self.isRunningOnSimulator,
        isBackendReachable: Bool = true
    ) -> [QuestBoardItem] {
        let cached = loadCachedBoardItems(forBuild: build)
        let cachedByHash = Dictionary(
            uniqueKeysWithValues: cached.map { ("\($0.id):\($0.contentHash)", $0) }
        )

        return definitions.map { definition in
            let hash = definition.contentHash
            let key = "\(definition.id):\(hash)"
            let cachedItem = cachedByHash[key]
            let warnings = Self.evaluateNeedWarnings(
                for: definition.needs,
                isSimulator: isSimulator,
                isBackendReachable: isBackendReachable
            )
            return QuestBoardItem(
                id: definition.id,
                version: cachedItem?.version ?? 1,
                contentHash: hash,
                definition: definition,
                status: cachedItem?.status ?? .pending,
                questStatus: cachedItem?.questStatus ?? "active",
                counts: cachedItem?.counts ?? QuestResultCounts(),
                needWarnings: warnings
            )
        }
    }

    public func syncWithServer(
        definitions: [QuestDefinition],
        build: String,
        appVersion: String?,
        client: APIClient,
        isSimulator: Bool = Self.isRunningOnSimulator
    ) async throws -> [QuestBoardItem] {
        let entries = definitions.map { $0.toManifestEntry() }
        let response = try await client.syncBuildManifest(
            build: build,
            appVersion: appVersion,
            quests: entries
        )

        let definitionsById = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let items: [QuestBoardItem] = response.quests.map { serverItem in
            let definition = definitionsById[serverItem.id] ?? QuestDefinition(
                id: serverItem.id,
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
            let status = QuestStatus(rawValue: serverItem.boardStatus) ?? .pending
            return QuestBoardItem(
                id: serverItem.id,
                version: serverItem.version,
                contentHash: serverItem.contentHash,
                definition: definition,
                status: status,
                questStatus: serverItem.questStatus,
                counts: serverItem.counts ?? QuestResultCounts(),
                needWarnings: warnings
            )
        }

        saveCachedBoardItems(items, forBuild: build)
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
        return items
    }

    private func cacheFileURL(forBuild build: String) -> URL {
        let safeBuild = build.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
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

    public init() {}

    public var pendingQuests: [QuestBoardItem] {
        quests.filter { $0.status != .passed }
    }

    public var completedQuests: [QuestBoardItem] {
        quests.filter { $0.status == .passed }
    }

    func reset() {
        pendingCount = 0
        quests = []
        activeQuest = nil
        isSyncing = false
        isBackendReachable = true
        lastSyncError = nil
        definitions = []
        localStatusOverrides = [:]
        QuestOverlayWindowManager.shared.hide()
    }

    func configure(
        questsConfiguration: HollerKitQuestsConfiguration?,
        build: String,
        cacheDirectoryURL: URL? = nil
    ) {
        self.store = QuestStore(cacheDirectoryURL: cacheDirectoryURL)
        self.localStatusOverrides = [:]
        guard let questsConfiguration else {
            reset()
            return
        }

        do {
            let loaded = try store.loadManifest(from: questsConfiguration)
            self.definitions = loaded
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
              config.quests != nil else {
            return
        }

        let metadata = MetadataCollector.collect(extra: config.metadata())
        let build = MetadataCollector.currentBuild(from: metadata)
        let appVersion = MetadataCollector.currentAppVersion(from: metadata)

        if definitions.isEmpty, let questsConfig = config.quests {
            if let loaded = try? store.loadManifest(from: questsConfig) {
                definitions = loaded
            }
        }
        guard !definitions.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }

        let client = APIClient(configuration: config)
        do {
            let syncedItems = try await store.syncWithServer(
                definitions: definitions,
                build: build,
                appVersion: appVersion,
                client: client
            )
            isBackendReachable = true
            lastSyncError = nil
            applyBoardItems(syncedItems, build: build)
        } catch {
            isBackendReachable = false
            lastSyncError = error.localizedDescription
            let fallbackItems = store.buildLocalBoardItems(
                from: definitions,
                build: build,
                isBackendReachable: false
            )
            applyBoardItems(fallbackItems, build: build)
        }
    }

    public func startQuest(_ item: QuestBoardItem, startedAt: Date = Date()) {
        guard HollerKit.isEnabled else { return }
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

        if let startRoute = item.definition.start?.trimmingCharacters(in: .whitespacesAndNewlines),
           !startRoute.isEmpty {
            HollerKit.currentConfiguration?.quests?.routes?(startRoute)
        }

        QuestOverlayWindowManager.shared.show(questState: self)
    }

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
        endedAt: Date = Date()
    ) async throws -> OutboxSubmissionOutcome {
        guard let session = activeQuest,
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

        recordLocalResult(result, forQuestId: session.quest.id, build: build)
        activeQuest = nil
        HollerKit.endQuestBreadcrumbs()
        QuestOverlayWindowManager.shared.hide()

        let client = APIClient(configuration: config)
        return try await HollerKit.currentOutboxStore.submit(
            request: request,
            attachments: attachments,
            using: client
        )
    }

    public func recordLocalResult(_ result: QuestResult, forQuestId questId: String, build: String) {
        guard let index = quests.firstIndex(where: { $0.id == questId }) else { return }
        var item = quests[index]
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
            if item.status != .passed {
                item.status = .failed
            }
        case .abandoned:
            item.counts.abandoned += 1
        }
        let key = "\(build):\(item.id):\(item.contentHash)"
        if item.status == .passed || item.status == .failed {
            localStatusOverrides[key] = item.status
        }
        quests[index] = item
        applyBoardItems(quests, build: build)
    }

    private func applyBoardItems(_ items: [QuestBoardItem], build: String) {
        let merged = items.map { rawItem -> QuestBoardItem in
            var item = rawItem
            let key = "\(build):\(item.id):\(item.contentHash)"
            if let overrideStatus = localStatusOverrides[key] {
                if overrideStatus == .passed {
                    item.status = .passed
                } else if overrideStatus == .failed, item.status == .pending {
                    item.status = .failed
                }
            }
            return item
        }
        self.quests = merged
        self.pendingCount = merged.filter { $0.status != .passed }.count
        store.saveCachedBoardItems(merged, forBuild: build)
    }
}
