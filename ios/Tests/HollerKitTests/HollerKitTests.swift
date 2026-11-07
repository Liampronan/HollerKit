import Foundation
import XCTest
@testable import HollerKit

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

private final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)
    private static let handlerBox = LockedBox<Handler?>(nil)

    static func setHandler(_ handler: Handler?) {
        handlerBox.withLock { $0 = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.handlerBox.withLock { $0 }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let bodyData = Self.readBody(from: request)
        do {
            let (response, data) = try handler(request, bodyData)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount > 0 {
                data.append(buffer, count: readCount)
            } else {
                break
            }
        }
        return data
    }
}

final class HollerKitTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testBreadcrumbStoreKeepsNewestEntries() {
        var store = BreadcrumbStore(capacity: 2)
        store.append(.init(message: "one"))
        store.append(.init(message: "two"))
        store.append(.init(message: "three"))

        XCTAssertEqual(store.snapshot().map(\.message), ["two", "three"])
    }

    func testBreadcrumbStoreTracksOffsetSecondsDuringActiveQuest() {
        var store = BreadcrumbStore(capacity: 10)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        store.append(.init(timestamp: t0.addingTimeInterval(-5), message: "Before quest"))
        XCTAssertNil(store.snapshot().last?.offsetSeconds)

        store.beginQuestRun(startedAt: t0)
        store.append(.init(timestamp: t0.addingTimeInterval(3.5), category: "ui", message: "Tapped card"))
        store.append(.init(timestamp: t0.addingTimeInterval(9.25), category: "nav", message: "Returned to feed"))

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot[1].offsetSeconds ?? -1, 3.5, accuracy: 0.001)
        XCTAssertEqual(snapshot[2].offsetSeconds ?? -1, 9.25, accuracy: 0.001)

        let events = store.questEvents(since: t0)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, "breadcrumb")
        XCTAssertEqual(events[0].offsetSeconds, 3.5, accuracy: 0.001)
        XCTAssertEqual(events[0].payload["message"], "Tapped card")
        XCTAssertEqual(events[1].offsetSeconds, 9.25, accuracy: 0.001)

        store.endQuestRun()
        store.append(.init(timestamp: t0.addingTimeInterval(15), message: "After quest"))
        XCTAssertNil(store.snapshot().last?.offsetSeconds)
    }

    func testCanonicalQuestContentHashMatchesProtocolServerVectors() {
        let questAlpha = QuestDefinition(
            id: "feed-detail-zoom",
            title: "  Open a feed card and come back  ",
            area: " feed ",
            setup: [" Settings -> Experiments -> Feed on "],
            steps: ["Scroll to the third card", "Tap it; the zoom transition plays", "Go back"],
            expect: ["Back returns to the same card at the same scroll position"],
            needs: ["device", "backend"],
            record: .suggested,
            start: "trashapp://feed",
            source: QuestManifestSource(pr: 55, added: "2026-11-07")
        )

        let expectedAlphaJSON = #"{"area":"feed","expect":["Back returns to the same card at the same scroll position"],"needs":["device","backend"],"record":"suggested","setup":["Settings -> Experiments -> Feed on"],"start":"trashapp://feed","steps":["Scroll to the third card","Tap it; the zoom transition plays","Go back"],"title":"Open a feed card and come back"}"#
        XCTAssertEqual(canonicalQuestJSON(questAlpha), expectedAlphaJSON)
        XCTAssertEqual(
            computeQuestContentHash(questAlpha),
            "2b07ae4a0b23655760ad5bc9fc4c63fccce974368679975dc9996893a1b6e742"
        )

        // Changing non-functional id or source fields must not alter contentHash
        var questAlphaDifferentProvenance = questAlpha
        questAlphaDifferentProvenance.id = "renamed-id"
        questAlphaDifferentProvenance.source = QuestManifestSource(pr: 999, sha: "deadbeef", added: "2027-01-01")
        XCTAssertEqual(questAlphaDifferentProvenance.contentHash, questAlpha.contentHash)

        let questBeta = QuestDefinition(
            id: "profile-avatar-crop",
            title: "Crop a new avatar photo",
            area: "profile",
            steps: ["Open Profile", "Tap avatar", "Pinch to zoom and save"],
            expect: ["Updated avatar persists after reload"],
            source: QuestManifestSource(pr: 56, added: "2026-11-07")
        )

        let expectedBetaJSON = #"{"area":"profile","expect":["Updated avatar persists after reload"],"needs":[],"record":"optional","setup":[],"start":null,"steps":["Open Profile","Tap avatar","Pinch to zoom and save"],"title":"Crop a new avatar photo"}"#
        XCTAssertEqual(canonicalQuestJSON(questBeta), expectedBetaJSON)
        XCTAssertEqual(
            computeQuestContentHash(questBeta),
            "0bfdcddc41b204e0e20dbe05257e54a5a71c32bc82409cca75358dce22c8cd61"
        )
    }

    func testQuestStoreLoadsManifestEvaluatesNeedsAndCachesOfflineState() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-queststore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestFileURL = tempDir.appendingPathComponent("hollerkit-quests.json")
        let manifestJSON = """
        {
          "version": 1,
          "quests": [
            {
              "id": "feed-detail-zoom",
              "title": "Open a feed card and come back",
              "area": "feed",
              "setup": ["Settings -> Experiments -> Feed on"],
              "steps": ["Scroll to the third card", "Tap it; the zoom transition plays", "Go back"],
              "expect": ["Back returns to the same card at the same scroll position"],
              "needs": ["device", "backend"],
              "record": "suggested",
              "start": "trashapp://feed"
            }
          ]
        }
        """
        try Data(manifestJSON.utf8).write(to: manifestFileURL)

        let store = QuestStore(cacheDirectoryURL: tempDir.appendingPathComponent("Cache", isDirectory: true))
        let config = HollerKitQuestsConfiguration.fileURL(manifestFileURL)
        let definitions = try store.loadManifest(from: config)
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(definitions.first?.id, "feed-detail-zoom")
        XCTAssertEqual(
            definitions.first?.contentHash,
            "2b07ae4a0b23655760ad5bc9fc4c63fccce974368679975dc9996893a1b6e742"
        )

        let simulatorOfflineWarnings = QuestStore.evaluateNeedWarnings(
            for: ["device", "backend"],
            isSimulator: true,
            isBackendReachable: false
        )
        XCTAssertEqual(simulatorOfflineWarnings, ["Requires physical device", "Requires reachable backend"])

        let deviceOnlineWarnings = QuestStore.evaluateNeedWarnings(
            for: ["device", "backend"],
            isSimulator: false,
            isBackendReachable: true
        )
        XCTAssertTrue(deviceOnlineWarnings.isEmpty)

        // Sync with stubbed server and verify local cache persistence
        let session = makeStubSession()
        StubURLProtocol.setHandler { request, _ in
            let url = request.url!
            let json = """
            {
              "ok": true,
              "build": "200",
              "pendingCount": 0,
              "quests": [
                {
                  "id": "feed-detail-zoom",
                  "version": 2,
                  "contentHash": "2b07ae4a0b23655760ad5bc9fc4c63fccce974368679975dc9996893a1b6e742",
                  "questStatus": "active",
                  "boardStatus": "passed",
                  "title": "Open a feed card and come back",
                  "area": "feed",
                  "setup": ["Settings -> Experiments -> Feed on"],
                  "steps": ["Scroll to the third card", "Tap it; the zoom transition plays", "Go back"],
                  "expect": ["Back returns to the same card at the same scroll position"],
                  "needs": ["device", "backend"],
                  "record": "suggested",
                  "start": "trashapp://feed",
                  "counts": { "pass": 1, "fail": 0, "unsure": 0, "abandoned": 0 }
                }
              ]
            }
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["hollerkit-protocol": "1"]
            )!
            return (response, Data(json.utf8))
        }

        let client = APIClient(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            session: session
        )

        let synced = try await store.syncWithServer(
            definitions: definitions,
            build: "200",
            appVersion: "1.0.0",
            client: client,
            isSimulator: true
        )
        XCTAssertEqual(synced.count, 1)
        XCTAssertEqual(synced.first?.status, .passed)
        XCTAssertEqual(synced.first?.version, 2)

        // Offline load from cache preserves `.passed` status and version 2
        let cachedFallback = store.buildLocalBoardItems(
            from: definitions,
            build: "200",
            isSimulator: true,
            isBackendReachable: false
        )
        XCTAssertEqual(cachedFallback.first?.status, .passed)
        XCTAssertEqual(cachedFallback.first?.version, 2)
        XCTAssertEqual(cachedFallback.first?.needWarnings, ["Requires physical device", "Requires reachable backend"])
    }

    @MainActor
    func testHollerKitQuestStateLifecycleRouteMarkAndSubmission() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-queststate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let navigatedRoutes = LockedBox<[String]>([])
        let submittedFeedbackBox = LockedBox<[String: Any]?>(nil)
        let uploadedMarksCountBox = LockedBox<Int>(0)
        let session = makeStubSession()

        StubURLProtocol.setHandler { request, bodyData in
            let url = request.url!

            if url.path.hasSuffix("/manifest") {
                let json = """
                {
                  "ok": true,
                  "build": "300",
                  "pendingCount": 1,
                  "quests": [
                    {
                      "id": "feed-detail-zoom",
                      "version": 1,
                      "contentHash": "2b07ae4a0b23655760ad5bc9fc4c63fccce974368679975dc9996893a1b6e742",
                      "questStatus": "active",
                      "boardStatus": "pending",
                      "title": "Open a feed card and come back",
                      "area": "feed",
                      "setup": ["Settings -> Experiments -> Feed on"],
                      "steps": ["Scroll to the third card", "Tap it; the zoom transition plays", "Go back"],
                      "expect": ["Back returns to the same card at the same scroll position"],
                      "needs": ["device", "backend"],
                      "record": "suggested",
                      "start": "trashapp://feed",
                      "counts": { "pass": 0, "fail": 0, "unsure": 0, "abandoned": 0 }
                    }
                  ]
                }
                """
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["hollerkit-protocol": "1"])!
                return (response, Data(json.utf8))
            }

            if url.path.hasSuffix("/v1/uploads") {
                let payload = try JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]
                let feedbackId = payload?["feedbackId"] as? String ?? "id"
                let json = """
                {
                  "ok": true,
                  "key": "\(feedbackId)/mark-0.png",
                  "url": "https://storage.hollerkit.test/upload/\(feedbackId)/mark-0.png",
                  "expiresAt": "2026-11-07T01:00:00Z"
                }
                """
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["hollerkit-protocol": "1"])!
                return (response, Data(json.utf8))
            }

            if url.host == "storage.hollerkit.test" {
                uploadedMarksCountBox.withLock { $0 += 1 }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data())
            }

            if url.path.hasSuffix("/v1/feedback") {
                let payload = try JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]
                submittedFeedbackBox.withLock { $0 = payload }
                let id = payload?["id"] as? String ?? UUID().uuidString.lowercased()
                let json = """
                {
                  "ok": true,
                  "idempotent": false,
                  "feedback": {
                    "id": "\(id)",
                    "kind": "quest_run",
                    "questId": "feed-detail-zoom",
                    "questVersion": 1,
                    "result": "pass",
                    "build": "300",
                    "submitterId": "tester-1",
                    "createdAt": "2026-11-07T00:00:00Z",
                    "updatedAt": "2026-11-07T00:00:00Z"
                  }
                }
                """
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["hollerkit-protocol": "1"])!
                return (response, Data(json.utf8))
            }

            throw URLError(.badURL)
        }

        let questDef = QuestDefinition(
            id: "feed-detail-zoom",
            title: "Open a feed card and come back",
            area: "feed",
            setup: ["Settings -> Experiments -> Feed on"],
            steps: ["Scroll to the third card", "Tap it; the zoom transition plays", "Go back"],
            expect: ["Back returns to the same card at the same scroll position"],
            needs: ["device", "backend"],
            record: .suggested,
            start: "trashapp://feed"
        )

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            metadata: { ["appBuild": "300", "appVersion": "1.0.0"] },
            quests: .definitions([questDef]) { route in
                navigatedRoutes.withLock { $0.append(route) }
            },
            urlSession: session,
            outboxDirectoryURL: tempDir.appendingPathComponent("Outbox", isDirectory: true)
        ))

        await HollerKit.quests.refresh()
        XCTAssertEqual(HollerKit.quests.pendingCount, 1)
        XCTAssertEqual(HollerKit.quests.quests.count, 1)

        guard let item = HollerKit.quests.quests.first else {
            XCTFail("Expected quest board item")
            return
        }

        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        HollerKit.quests.startQuest(item, startedAt: startDate)
        XCTAssertEqual(navigatedRoutes.withLock { $0 }, ["trashapp://feed"])
        XCTAssertNotNil(HollerKit.quests.activeQuest)

        HollerKit.quests.toggleStep(at: 0)
        HollerKit.quests.toggleStep(at: 2)
        XCTAssertEqual(HollerKit.quests.activeQuest?.stepsChecked, [true, false, true])

        let mark = HollerKit.quests.captureMark(
            label: "Zoom transition glitch",
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            at: startDate.addingTimeInterval(4.2)
        )
        XCTAssertNotNil(mark)
        XCTAssertEqual(mark?.offsetSeconds ?? -1, 4.2, accuracy: 0.001)

        let outcome = try await HollerKit.quests.submitActiveQuest(
            result: .pass,
            comment: "Smooth transition verified",
            transcript: nil,
            endedAt: startDate.addingTimeInterval(10.0)
        )

        if case .sent(let response) = outcome {
            XCTAssertEqual(response.feedback.kind, "quest_run")
            XCTAssertEqual(response.feedback.result, "pass")
        } else {
            XCTFail("Expected quest submission to be sent immediately")
        }

        XCTAssertNil(HollerKit.quests.activeQuest)
        XCTAssertEqual(HollerKit.quests.pendingCount, 0)
        XCTAssertEqual(HollerKit.quests.completedQuests.count, 1)
        XCTAssertEqual(uploadedMarksCountBox.withLock { $0 }, 1)

        let submitted = submittedFeedbackBox.withLock { $0 }
        XCTAssertEqual(submitted?["kind"] as? String, "quest_run")
        XCTAssertEqual(submitted?["questId"] as? String, "feed-detail-zoom")
        XCTAssertEqual(submitted?["questVersion"] as? Int, 1)
        XCTAssertEqual(submitted?["result"] as? String, "pass")
        XCTAssertEqual(submitted?["stepsChecked"] as? [Bool], [true, false, true])
    }

    func testInputModeWireValues() {
        XCTAssertEqual(HollerKitInputMode.textAndAudio.wireValue, "text-and-audio")
        XCTAssertEqual(HollerKitInputMode.textOnly.wireValue, "text-only")
        XCTAssertEqual(HollerKitInputMode.audioOnly().wireValue, "audio-only")
    }

    func testDefaultAudioModeIsTranscriptOnly() {
        let configuration = HollerKitConfiguration(
            server: URL(string: "https://example.com")!,
            auth: { "token" }
        )

        switch configuration.audio {
        case .transcriptOnly(let maxDuration, let requireOnDeviceTranscription):
            XCTAssertEqual(maxDuration, 60)
            XCTAssertFalse(requireOnDeviceTranscription)
        default:
            XCTFail("Default audio mode should avoid raw audio upload.")
        }
    }

    func testEnvironmentEvaluatesDebugSimulatorAndTestFlightReceipts() {
        XCTAssertTrue(HollerKitEnvironment.evaluateIsDebugOrTestFlight(
            isDebugBuild: true,
            isSimulator: false,
            receiptURL: nil
        ))
        XCTAssertTrue(HollerKitEnvironment.evaluateIsDebugOrTestFlight(
            isDebugBuild: false,
            isSimulator: true,
            receiptURL: nil
        ))
        XCTAssertTrue(HollerKitEnvironment.evaluateIsDebugOrTestFlight(
            isDebugBuild: false,
            isSimulator: false,
            receiptURL: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/UUID/StoreKit/sandboxReceipt"),
            fileExists: { _ in true }
        ))
        XCTAssertFalse(HollerKitEnvironment.evaluateIsDebugOrTestFlight(
            isDebugBuild: false,
            isSimulator: false,
            receiptURL: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/UUID/StoreKit/sandboxReceipt"),
            fileExists: { _ in false }
        ))
        XCTAssertTrue(HollerKitEnvironment.evaluateIsDebugOrTestFlight(
            isDebugBuild: false,
            isSimulator: false,
            receiptURL: nil,
            mobileProvisionURL: URL(fileURLWithPath: "/private/var/containers/Bundle/Application/UUID/App.app/embedded.mobileprovision"),
            fileExists: { $0.lastPathComponent == "embedded.mobileprovision" }
        ))
        XCTAssertFalse(HollerKitEnvironment.evaluateIsDebugOrTestFlight(
            isDebugBuild: false,
            isSimulator: false,
            receiptURL: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/UUID/StoreKit/receipt")
        ))
        XCTAssertFalse(HollerKitEnvironment.evaluateIsDebugOrTestFlight(
            isDebugBuild: false,
            isSimulator: false,
            receiptURL: nil
        ))
    }

    @MainActor
    func testConfigureStoresInvocationTriggersWhenEnabled() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://example.com")!,
            auth: { nil },
            isEnabled: { true },
            invocation: [.shake, .screenshot],
            outboxDirectoryURL: tempDir
        ))

        XCTAssertTrue(HollerKit.isEnabled)
        XCTAssertTrue(HollerKit.currentInvocation.contains(.shake))
        XCTAssertTrue(HollerKit.currentInvocation.contains(.screenshot))
    }

    @MainActor
    func testIsEnabledFalseSuppressesInvocationsBreadcrumbsAndPresentation() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://example.com")!,
            auth: { "token" },
            isEnabled: { false },
            invocation: [.shake, .screenshot],
            outboxDirectoryURL: tempDir
        ))

        XCTAssertFalse(HollerKit.isEnabled)
        XCTAssertTrue(HollerKit.currentInvocation.isEmpty)

        HollerKit.breadcrumb("Should not be recorded", category: "test")
        XCTAssertTrue(HollerKit.currentBreadcrumbs.snapshot().isEmpty)

        HollerKit.presentBugReport()
        XCTAssertFalse(HollerKit.isPresentationRequested)

        HollerKit.present()
        XCTAssertFalse(HollerKit.isPresentationRequested)

        HollerKit.presentQuests()
        XCTAssertFalse(HollerKit.isQuestsPresentationRequested)
    }

    @MainActor
    func testManualPresentationRequestsSheetAndCarriesAttachments() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://example.com")!,
            auth: { nil },
            isEnabled: { true },
            outboxDirectoryURL: tempDir
        ))
        HollerKit.presenterState.isPresented = false
        HollerKit.clearPresentationAttachments()

        let attachment = HollerKitAttachment(
            filename: "screenshot.png",
            mimeType: "image/png",
            data: Data([1, 2, 3])
        )

        HollerKit.present(attachments: [attachment])

        XCTAssertTrue(HollerKit.isPresentationRequested)
        XCTAssertEqual(HollerKit.pendingPresentationAttachments.first?.filename, "screenshot.png")

        HollerKit.clearPresentationAttachments()
        HollerKit.presenterState.isPresented = false
    }

    func testAPIClientSendsProtocolHeaderBearerTokenAndDecodesV1Responses() async throws {
        let session = makeStubSession()
        let recordedRequests = LockedBox<[(URLRequest, Data?)]>([])

        StubURLProtocol.setHandler { request, bodyData in
            recordedRequests.withLock { $0.append((request, bodyData)) }
            let url = request.url!
            let path = url.path

            if path.hasSuffix("/v1/builds/42/manifest") {
                let json = """
                {
                  "ok": true,
                  "build": "42",
                  "pendingCount": 1,
                  "quests": [
                    {
                      "id": "feed-zoom",
                      "version": 1,
                      "contentHash": "abc123",
                      "questStatus": "active",
                      "boardStatus": "pending",
                      "title": "Zoom feed card",
                      "area": "feed",
                      "setup": [],
                      "steps": ["Tap card"],
                      "expect": ["Zooms smoothly"],
                      "needs": [],
                      "record": "optional"
                    }
                  ]
                }
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["hollerkit-protocol": "1", "Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }

            if path.hasSuffix("/v1/builds/42/pending") {
                let json = """
                {
                  "ok": true,
                  "build": "42",
                  "pendingCount": 1,
                  "quests": [
                    {
                      "id": "feed-zoom",
                      "version": 1,
                      "contentHash": "abc123",
                      "title": "Zoom feed card",
                      "area": "feed",
                      "setup": [],
                      "steps": ["Tap card"],
                      "expect": ["Zooms smoothly"],
                      "needs": [],
                      "record": "optional",
                      "status": "active",
                      "createdAt": "2026-11-07T00:00:00Z"
                    }
                  ]
                }
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["hollerkit-protocol": "1", "Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }

            throw URLError(.unsupportedURL)
        }

        let client = APIClient(
            server: URL(string: "https://api.hollerkit.test/functions/v1/hollerkit")!,
            auth: { "jwt-token-123" },
            session: session
        )

        let manifestResponse = try await client.syncBuildManifest(
            build: "42",
            appVersion: "1.2.0",
            quests: [
                QuestManifestEntry(
                    id: "feed-zoom",
                    title: "Zoom feed card",
                    area: "feed",
                    steps: ["Tap card"],
                    expect: ["Zooms smoothly"]
                )
            ]
        )
        XCTAssertEqual(manifestResponse.build, "42")
        XCTAssertEqual(manifestResponse.pendingCount, 1)
        XCTAssertEqual(manifestResponse.quests.first?.id, "feed-zoom")

        let pending = try await client.fetchPendingQuests(build: "42")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, "feed-zoom")

        let captured = recordedRequests.withLock { $0 }
        XCTAssertEqual(captured.count, 2)
        for (req, _) in captured {
            XCTAssertEqual(req.value(forHTTPHeaderField: "hollerkit-protocol"), "1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token-123")
        }
        let manifestBody = try XCTUnwrap(captured.first?.1)
        let manifestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestBody) as? [String: Any])
        XCTAssertEqual(manifestJSON["appVersion"] as? String, "1.2.0")
        let manifestQuests = try XCTUnwrap(manifestJSON["quests"] as? [[String: Any]])
        XCTAssertEqual(manifestQuests.first?["id"] as? String, "feed-zoom")
    }

    func testOutboxStorePersistsWhenSignedOutAndFlushesWhenAuthBecomesAvailable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-outbox-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let currentTokenBox = LockedBox<String?>(nil)
        let uploadedBytesBox = LockedBox<Data?>(nil)
        let submittedFeedbackBox = LockedBox<[String: Any]?>(nil)
        let session = makeStubSession()

        StubURLProtocol.setHandler { request, bodyData in
            let url = request.url!

            if url.host == "storage.hollerkit.test" {
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                uploadedBytesBox.withLock { $0 = bodyData }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data())
            }

            if url.path.hasSuffix("/v1/uploads") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "hollerkit-protocol"), "1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-session-jwt")
                let payload = try JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]
                let feedbackId = payload?["feedbackId"] as? String ?? "unknown"
                let json = """
                {
                  "ok": true,
                  "key": "\(feedbackId)/att-0.png",
                  "url": "https://storage.hollerkit.test/upload/\(feedbackId)/att-0.png",
                  "expiresAt": "2026-11-07T01:00:00Z"
                }
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["hollerkit-protocol": "1"]
                )!
                return (response, Data(json.utf8))
            }

            if url.path.hasSuffix("/v1/feedback") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "hollerkit-protocol"), "1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-session-jwt")
                let jsonObj = try JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]
                submittedFeedbackBox.withLock { $0 = jsonObj }
                let feedbackId = jsonObj?["id"] as? String ?? UUID().uuidString.lowercased()
                let responseJson = """
                {
                  "ok": true,
                  "idempotent": false,
                  "feedback": {
                    "id": "\(feedbackId)",
                    "kind": "report",
                    "build": "100",
                    "submitterId": "user-1",
                    "comment": "Sign out button overlaps footer",
                    "createdAt": "2026-11-07T00:00:00Z",
                    "updatedAt": "2026-11-07T00:00:00Z"
                  }
                }
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["hollerkit-protocol": "1"]
                )!
                return (response, Data(responseJson.utf8))
            }

            throw URLError(.badURL)
        }

        let client = APIClient(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { currentTokenBox.withLock { $0 } },
            session: session
        )
        let outbox = OutboxStore(rootDirectoryURL: tempDir)

        let reportPayload = HollerKitReportPayload(
            inputMode: .textAndAudio,
            comment: "Sign out button overlaps footer",
            transcript: HollerKitTranscript(
                text: "Dictated note while signed out",
                locale: "en-US",
                engine: .manual
            ),
            metadata: ["appBuild": "100", "appVersion": "2.0.0"],
            breadcrumbs: [
                HollerKitBreadcrumb(category: "auth", message: "Tapped sign out")
            ],
            images: [
                HollerKitAttachment(
                    filename: "screen.png",
                    mimeType: "image/png",
                    data: Data([0x89, 0x50, 0x4E, 0x47])
                )
            ]
        )

        let (submissionRequest, submissionAttachments) = reportPayload.toFeedbackSubmission()

        // 1. Submit while signed out (auth() returns nil)
        let initialOutcome = try await outbox.submit(
            request: submissionRequest,
            attachments: submissionAttachments,
            using: client
        )

        guard case .queued(let queuedId, _) = initialOutcome else {
            XCTFail("Expected submission to remain queued in outbox when auth() returns nil")
            return
        }

        let pendingCountWhileSignedOut = await outbox.pendingCount()
        XCTAssertEqual(pendingCountWhileSignedOut, 1)

        // Verify disk contents & that no auth token is cached in envelope.json
        let itemDir = await outbox.directoryURL(for: queuedId)
        let envelopeData = try Data(contentsOf: itemDir.appendingPathComponent("envelope.json"))
        let envelopeString = String(decoding: envelopeData, as: UTF8.self)
        XCTAssertFalse(envelopeString.contains("Bearer"))
        XCTAssertFalse(envelopeString.contains("fresh-session-jwt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemDir.appendingPathComponent("0.png").path))

        // 2. Sign back in (auth() now returns a token) and flush using a fresh OutboxStore instance
        currentTokenBox.withLock { $0 = "fresh-session-jwt" }
        let reloadedOutbox = OutboxStore(rootDirectoryURL: tempDir)
        let flushResult = await reloadedOutbox.flush(using: client)

        XCTAssertEqual(flushResult.flushedIds, [queuedId])
        XCTAssertEqual(flushResult.remainingCount, 0)
        let pendingCountAfterFlush = await reloadedOutbox.pendingCount()
        XCTAssertEqual(pendingCountAfterFlush, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDir.path))

        // Verify uploaded attachment bytes and feedback payload
        XCTAssertEqual(uploadedBytesBox.withLock { $0 }, Data([0x89, 0x50, 0x4E, 0x47]))
        let submittedJSON = submittedFeedbackBox.withLock { $0 }
        XCTAssertEqual(submittedJSON?["id"] as? String, queuedId.uuidString.lowercased())
        XCTAssertEqual(submittedJSON?["kind"] as? String, "report")
        XCTAssertEqual(submittedJSON?["build"] as? String, "100")
        XCTAssertEqual(submittedJSON?["comment"] as? String, "Sign out button overlaps footer")
        XCTAssertEqual(submittedJSON?["transcript"] as? String, "Dictated note while signed out")

        let attachments = submittedJSON?["attachments"] as? [[String: Any]]
        XCTAssertEqual(attachments?.count, 1)
        XCTAssertEqual(attachments?.first?["key"] as? String, "\(queuedId.uuidString.lowercased())/att-0.png")
        XCTAssertEqual(attachments?.first?["kind"] as? String, "image")
    }
}
