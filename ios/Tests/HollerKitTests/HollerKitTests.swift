import AVFoundation
import Foundation
import Observation
#if canImport(PhotosUI)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
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
        var store = BreadcrumbStore(capacity: 3)
        store.append(.init(message: "one"))
        store.append(.init(message: "two"))
        store.append(.init(message: "three"))
        XCTAssertEqual(store.snapshot().map(\.message), ["one", "two", "three"])
        XCTAssertEqual(store.snapshot().count, 3)

        store.append(.init(message: "four"))
        XCTAssertEqual(store.snapshot().map(\.message), ["breadcrumbs.truncated", "three", "four"])
        XCTAssertEqual(store.snapshot().count, 3)
        XCTAssertEqual(store.truncatedCount, 2)

        store.append(.init(message: "five"))
        XCTAssertEqual(store.snapshot().map(\.message), ["breadcrumbs.truncated", "four", "five"])
        XCTAssertEqual(store.snapshot().count, 3)
        XCTAssertEqual(store.truncatedCount, 3)

        var store0 = BreadcrumbStore(capacity: 0)
        store0.append(.init(message: "never"))
        XCTAssertEqual(store0.snapshot().count, 0)
    }

    func testBreadcrumbStoreTypedFieldsAndPayloadCap() {
        var store = BreadcrumbStore(capacity: 10)
        let crumb = HollerKitBreadcrumb(
            message: "share.render",
            fields: [
                "cached": false,
                "retryCount": 2,
                "ratio": 0.85,
                "format": "mp4",
            ],
            durationMs: 142.5
        )
        store.append(crumb)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].fields["cached"], .bool(false))
        XCTAssertEqual(snapshot[0].fields["retryCount"], .int(2))
        XCTAssertEqual(snapshot[0].fields["ratio"], .double(0.85))
        XCTAssertEqual(snapshot[0].fields["format"], .string("mp4"))
        XCTAssertEqual(snapshot[0].durationMs, 142.5)

        let events = store.questEvents(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload.fields?["cached"], .bool(false))
        XCTAssertEqual(events[0].payload.durationMs, 142.5)

        var largePayload = FeedbackEventPayload(
            strings: ["huge": String(repeating: "A", count: 3000)],
            fields: ["data": .string(String(repeating: "B", count: 3000))]
        )
        largePayload.clampToSize(maxBytes: 2048)
        let encodedData = try! JSONEncoder().encode(largePayload)
        XCTAssertLessThanOrEqual(encodedData.count, 2048)
    }

    func testFeedbackEventPayloadClampsManyShortEntriesToUnderLimit() {
        var manyEntriesPayload = FeedbackEventPayload()
        for i in 0..<200 {
            manyEntriesPayload["key_\(i)"] = "short_value_\(i)"
        }
        let dataBefore = try? JSONEncoder().encode(manyEntriesPayload)
        XCTAssertGreaterThan(dataBefore?.count ?? 0, 2048)
        manyEntriesPayload.clampToSize(maxBytes: 2048)
        let dataAfter = try? JSONEncoder().encode(manyEntriesPayload)
        XCTAssertLessThanOrEqual(dataAfter?.count ?? 0, 2048)
    }

    @MainActor
    func testHollerKitSpanRecordsDurationMsAndFields() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-span-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let serverURL = URL(string: "http://127.0.0.1:8080")!
        let config = HollerKitConfiguration(
            server: serverURL,
            auth: { "token" },
            isEnabled: { true },
            captureBreadcrumbs: true,
            urlSession: URLSession(configuration: .ephemeral),
            outboxDirectoryURL: tempDir
        )
        HollerKit.configure(config)

        let t0 = Date()
        let span = HollerKit.begin("share.render", fields: ["cached": false], startDate: t0)
        let t1 = t0.addingTimeInterval(0.25)
        span.end(fields: ["items": 3], endDate: t1)

        let snapshot = HollerKit.currentBreadcrumbs.snapshot()
        let spanCrumb = snapshot.first { $0.message == "share.render" }
        XCTAssertNotNil(spanCrumb)
        XCTAssertEqual(spanCrumb?.fields["cached"], .bool(false))
        XCTAssertEqual(spanCrumb?.fields["items"], .int(3))
        XCTAssertEqual(spanCrumb?.durationMs ?? 0, 250, accuracy: 1.0)
    }

    @MainActor
    func testHollerKitSpanGatingWhenDisabled() {
        let serverURL = URL(string: "http://127.0.0.1:8080")!
        HollerKit.configure(
            server: serverURL,
            auth: { "token" },
            isEnabled: { false }
        )

        let span = HollerKit.begin("dormant.span", fields: ["ignored": true])
        span.end(fields: ["still_ignored": true])

        let snapshot = HollerKit.currentBreadcrumbs.snapshot()
        XCTAssertFalse(snapshot.contains { $0.message == "dormant.span" })
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

        let questGamma = QuestDefinition(
            id: "share-video-time-to-send",
            title: "Share video time to send",
            area: "share",
            steps: ["Tap Share", "Wait for video to be ready"],
            expect: ["Video renders in reasonable time"],
            capture: [
                QuestCaptureDefinition(
                    event: "share.render",
                    value: "durationMs",
                    unit: "ms",
                    label: "First render",
                    whereClause: ["cached": .bool(false)]
                )
            ]
        )
        let expectedGammaJSON = #"{"area":"share","capture":[{"event":"share.render","label":"First render","max":null,"min":null,"unit":"ms","value":"durationMs","where":{"cached":false}}],"expect":["Video renders in reasonable time"],"needs":[],"record":"optional","setup":[],"start":null,"steps":["Tap Share","Wait for video to be ready"],"title":"Share video time to send"}"#
        XCTAssertEqual(canonicalQuestJSON(questGamma), expectedGammaJSON)
        XCTAssertEqual(
            computeQuestContentHash(questGamma),
            "cf0bdb6e1f189112213c6cbb38232e7c12102abd2040953b01ce4509f9bb7b4a"
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

        let events = try XCTUnwrap(submitted?["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains(where: { ($0["kind"] as? String) == "breadcrumb" }))
        let markEvent = try XCTUnwrap(events.first(where: { ($0["kind"] as? String) == "mark" }))
        XCTAssertEqual(markEvent["offsetSeconds"] as? Double ?? -1, 4.2, accuracy: 0.001)
        let markPayload = try XCTUnwrap(markEvent["payload"] as? [String: String])
        XCTAssertEqual(markPayload["markId"], mark?.id.uuidString.lowercased())

        let attachments = try XCTUnwrap(submitted?["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["kind"] as? String, "mark")
        XCTAssertEqual(attachments.first?["offsetSeconds"] as? Double ?? -1, 4.2, accuracy: 0.001)
        XCTAssertNotNil(attachments.first?["key"] as? String)
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

        guard case .queued(let queuedId, _, let isAuthError) = initialOutcome else {
            XCTFail("Expected submission to remain queued in outbox when auth() returns nil")
            return
        }
        XCTAssertTrue(isAuthError)

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

    func testOverlayHitPolicyCapturesTouchesOnlyWithinInteractiveFramePlusSlop() {
        // 1. A zero frame always passes through, even at origin or within the slop radius
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: .zero, interactiveFrame: .zero))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 5, y: 5), interactiveFrame: .zero))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 200, y: 780), interactiveFrame: .zero))

        let pillFrame = CGRect(x: 32, y: 760, width: 326, height: 44)

        // 2. A point inside the frame is captured
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 195, y: 782), interactiveFrame: pillFrame))
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 32, y: 760), interactiveFrame: pillFrame))
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 357, y: 803), interactiveFrame: pillFrame))

        // 3. A point inside the 12pt slop margin is captured
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 20, y: 782), interactiveFrame: pillFrame))
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 369, y: 782), interactiveFrame: pillFrame))
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 195, y: 748), interactiveFrame: pillFrame))
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 195, y: 815), interactiveFrame: pillFrame))

        // 4. A point outside the frame (beyond the 12pt slop margin) passes through
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 19, y: 782), interactiveFrame: pillFrame))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 371, y: 782), interactiveFrame: pillFrame))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 195, y: 747), interactiveFrame: pillFrame))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 195, y: 817), interactiveFrame: pillFrame))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 195, y: 400), interactiveFrame: pillFrame))

        // 5. A frame after a drag offset captures at the new location and passes through at the old one
        let dragDelta = CGSize(width: -12, height: -320)
        let draggedFrame = pillFrame.offsetBy(dx: dragDelta.width, dy: dragDelta.height)
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 183, y: 462), interactiveFrame: draggedFrame))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: 195, y: 782), interactiveFrame: draggedFrame))
    }

    #if canImport(UIKit)
    @MainActor
    func testQuestOverlayHostingViewMatchesWindowBoundsAndUpdatesInteractiveFrameWhenExpanded() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-overlay-frame-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let questDef = QuestDefinition(
            id: "checkout-promo-math",
            title: "Apply promo RUN2026 and verify total",
            area: "checkout",
            steps: [
                "Inspect Subtotal ($79.00) and Promo RUN2026 (-$12.00)",
                "Verify Tax ($7.43) and Total calculation",
                "Tap Pay button"
            ],
            expect: ["Total equals $74.43"]
        )

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { nil },
            isEnabled: { true },
            quests: .definitions([questDef]),
            outboxDirectoryURL: tempDir
        ))

        let questState = HollerKit.quests
        guard let item = questState.quests.first else {
            XCTFail("Expected configured quest item")
            return
        }
        questState.startQuest(item)
        defer { QuestOverlayWindowManager.shared.hide() }

        let windowBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        var reportedFrame: CGRect = .zero

        let rootView = ZStack(alignment: .bottom) {
            Color.clear
                .ignoresSafeArea()
                .allowsHitTesting(false)

            QuestOverlayView(
                questState: questState,
                viewportSize: windowBounds.size,
                onFrameChange: { frame in
                    reportedFrame = frame
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }

        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear
        let window = UIWindow(frame: windowBounds)
        window.rootViewController = hostingController
        window.isHidden = false
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(hostingController.view.frame, window.bounds)
        let collapsedFrame = reportedFrame
        XCTAssertNotEqual(collapsedFrame, .zero)
        XCTAssertTrue(window.bounds.contains(collapsedFrame), "Collapsed frame \(collapsedFrame) should lie inside window bounds \(window.bounds)")
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: CGPoint(x: collapsedFrame.midX, y: collapsedFrame.midY), interactiveFrame: collapsedFrame))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: CGPoint(x: windowBounds.midX, y: 120), interactiveFrame: collapsedFrame))

        // Expand the overlay card and verify onFrameChange reports the larger expanded card frame
        questState.setOverlayExpanded(true)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        let expandedFrame = reportedFrame
        XCTAssertGreaterThan(expandedFrame.height, collapsedFrame.height + 80)
        XCTAssertLessThan(expandedFrame.minY, collapsedFrame.minY)
        XCTAssertTrue(window.bounds.contains(expandedFrame), "Expanded frame \(expandedFrame) should lie inside window bounds \(window.bounds)")
        // Top of the expanded card (above the old collapsed pill) must now capture touches
        let expandedHeaderPoint = CGPoint(x: expandedFrame.midX, y: expandedFrame.minY + 20)
        XCTAssertTrue(OverlayHitPolicy.capturesTouch(at: expandedHeaderPoint, interactiveFrame: expandedFrame))
        XCTAssertFalse(OverlayHitPolicy.capturesTouch(at: expandedHeaderPoint, interactiveFrame: collapsedFrame))
    }

    @MainActor
    func testHollerKitPresenterPreservesHostViewStateAcrossEnablementChanges() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-presenter-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let enabledBox = LockedBox(false)
        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { nil },
            isEnabled: { enabledBox.withLock { $0 } },
            invocation: [.shake, .screenshot],
            outboxDirectoryURL: tempDir
        ))

        let observedCounters = LockedBox<[Int]>([])
        var incrementTrigger: (() -> Void)?

        struct StatefulHostView: View {
            @State private var counter = 0
            let onRender: (Int, @escaping () -> Void) -> Void

            var body: some View {
                let _ = onRender(counter) {
                    counter += 1
                }
                Text("Count: \(counter)")
            }
        }

        let rootView = StatefulHostView { current, increment in
            observedCounters.withLock { $0.append(current) }
            incrementTrigger = increment
        }
        .hollerKitPresenter()

        let hostingController = UIHostingController(rootView: rootView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostingController
        window.isHidden = false
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(observedCounters.withLock { $0.last }, 0)

        // Mutate @State while HollerKit is disabled
        incrementTrigger?()
        incrementTrigger?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(observedCounters.withLock { $0.last }, 2)

        // Flip enablement false -> true and verify @State is preserved
        enabledBox.withLock { $0 = true }
        XCTAssertTrue(HollerKit.reconcileEnablement())
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(observedCounters.withLock { $0.last }, 2)

        // Flip enablement true -> false and verify @State is still preserved
        enabledBox.withLock { $0 = false }
        XCTAssertFalse(HollerKit.reconcileEnablement())
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(observedCounters.withLock { $0.last }, 2)
    }
    #endif

    @MainActor
    func testConfigureLoadsQuestsWhenEnablementFlipsFromFalseToTrue() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-deferred-enable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let enabledBox = LockedBox(false)
        let manifestSyncCount = LockedBox(0)
        let manifestSynced = expectation(description: "manifest synced after deferred enablement")
        manifestSynced.assertForOverFulfill = false
        let session = makeStubSession()

        StubURLProtocol.setHandler { request, _ in
            let url = request.url!
            if url.path.hasSuffix("/manifest") {
                manifestSyncCount.withLock { $0 += 1 }
                manifestSynced.fulfill()
                let json = """
                {
                  "ok": true,
                  "build": "400",
                  "pendingCount": 1,
                  "quests": [
                    {
                      "id": "deferred-quest",
                      "version": 1,
                      "contentHash": "abc123",
                      "questStatus": "active",
                      "boardStatus": "pending",
                      "title": "Verify deferred enablement",
                      "area": "auth",
                      "setup": [],
                      "steps": ["Sign in"],
                      "expect": ["Quests appear"],
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
                    headerFields: ["hollerkit-protocol": "1"]
                )!
                return (response, Data(json.utf8))
            }
            throw URLError(.badURL)
        }

        let questDef = QuestDefinition(
            id: "deferred-quest",
            title: "Verify deferred enablement",
            area: "auth",
            steps: ["Sign in"],
            expect: ["Quests appear"]
        )

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { enabledBox.withLock { $0 } },
            metadata: { ["appBuild": "400", "appVersion": "1.0.0"] },
            quests: .definitions([questDef]),
            urlSession: session,
            outboxDirectoryURL: tempDir.appendingPathComponent("Outbox", isDirectory: true)
        ))

        // While disabled at configure() time, quests remain empty
        XCTAssertFalse(HollerKit.isEnabled)
        XCTAssertTrue(HollerKit.quests.quests.isEmpty)
        XCTAssertEqual(HollerKit.quests.pendingCount, 0)

        // Async TestFlight / tester check resolves to true
        enabledBox.withLock { $0 = true }
        XCTAssertTrue(HollerKit.reconcileEnablement())

        // Local quest manifest is loaded immediately on false -> true transition
        XCTAssertEqual(HollerKit.quests.quests.count, 1)
        XCTAssertEqual(HollerKit.quests.quests.first?.id, "deferred-quest")
        XCTAssertEqual(HollerKit.quests.pendingCount, 1)

        // And the background refresh syncs with the server
        await fulfillment(of: [manifestSynced], timeout: 2.0)
        XCTAssertGreaterThanOrEqual(manifestSyncCount.withLock { $0 }, 1)
    }

    func testSpeechNoteCaptureErrorDescribesNSErrorDomainCodeAndUnderlyingError() {
        let genericSpeechError = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1101,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn’t be completed."
            ]
        )
        let formattedGeneric = SpeechNoteCaptureError.describeError(genericSpeechError)
        XCTAssertTrue(formattedGeneric.contains("The operation couldn’t be completed."))
        XCTAssertTrue(formattedGeneric.contains("[kAFAssistantErrorDomain code 1101]"))

        let underlyingOSStatus = NSError(
            domain: NSOSStatusErrorDomain,
            code: 561015905,
            userInfo: [NSLocalizedDescriptionKey: "Session activation failed"]
        )
        let wrappedAudioError = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: -10868,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn’t be completed.",
                NSLocalizedFailureReasonErrorKey: "Format not supported.",
                NSUnderlyingErrorKey: underlyingOSStatus
            ]
        )
        let formattedWrapped = SpeechNoteCaptureError.describeError(wrappedAudioError)
        XCTAssertTrue(formattedWrapped.contains("Format not supported."))
        XCTAssertTrue(formattedWrapped.contains("[com.apple.coreaudio.avfaudio code -10868]"))
        XCTAssertTrue(formattedWrapped.contains("NSOSStatusErrorDomain code 561015905"))

        let audioSessionCaptureError = SpeechNoteCaptureError.audioSessionFailed(formattedGeneric)
        XCTAssertEqual(
            SpeechNoteCaptureError.describeError(audioSessionCaptureError),
            "Audio session setup failed: \(formattedGeneric)"
        )

        let transcriberError = SpeechTranscriberError.transcriptionFailed(formattedGeneric)
        XCTAssertEqual(
            SpeechNoteCaptureError.describeError(transcriberError),
            "Speech transcription failed: \(formattedGeneric)"
        )
    }

    func testLiveRecognitionStatePreservesPartialTranscriptAcrossCancelError() {
        let state = LiveRecognitionState()
        state.recordResult(text: "Outcome rows work across the whole width", confidence: 0.92, isFinal: false)
        state.recordError(NSError(
            domain: "kAFAssistantErrorDomain",
            code: 216,
            userInfo: [NSLocalizedDescriptionKey: "Request was canceled"]
        ))

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.text, "Outcome rows work across the whole width")
        XCTAssertEqual(snapshot.confidence ?? -1, 0.92, accuracy: 0.001)
        XCTAssertFalse(snapshot.isFinal)
        XCTAssertTrue(snapshot.errorDescription?.contains("kAFAssistantErrorDomain code 216") == true)
    }

    #if canImport(AVFoundation) && canImport(Speech) && os(iOS)
    @MainActor
    func testStopAsyncWaitsForDelayedTranscriptDelivery() async throws {
        let capture = SpeechNoteCapture()
        let state = LiveRecognitionState()
        capture.startForTesting(
            state: state,
            options: SpeechTranscriberOptions(locale: Locale(identifier: "en_US"))
        )
        XCTAssertTrue(capture.isCapturing)

        let stopTask = Task { @MainActor in
            try await capture.stopAsync()
        }

        // Wait until stopAsync() enters its stopping state before delivering the final transcript
        let stoppingDeadline = Date().addingTimeInterval(2)
        while !capture.isStopping {
            if Date() >= stoppingDeadline {
                stopTask.cancel()
                _ = try? await stopTask.value
                XCTFail("stopAsync() did not enter its stopping state")
                return
            }
            await Task.yield()
        }
        state.recordResult(text: "Delayed final transcript after endAudio", confidence: 0.95, isFinal: true)

        let transcript = try await stopTask.value
        XCTAssertEqual(transcript.text, "Delayed final transcript after endAudio")
        XCTAssertEqual(transcript.locale, "en_US")
        XCTAssertEqual(transcript.confidence ?? -1, 0.95, accuracy: 0.001)
        XCTAssertFalse(capture.isCapturing)
        XCTAssertFalse(capture.isStopping)
    }

    @MainActor
    func testStopAsyncPreservesSessionMetadataAndReportsMidCaptureOrTimeoutErrors() async throws {
        let capture = SpeechNoteCapture()
        let stateA = LiveRecognitionState()
        capture.startForTesting(
            state: stateA,
            options: SpeechTranscriberOptions(
                locale: Locale(identifier: "fr_FR"),
                requireOnDeviceRecognition: false
            )
        )
        stateA.recordResult(text: "Texte en français", confidence: 0.91, isFinal: false)

        let stopTaskA = Task { @MainActor in
            try await capture.stopAsync()
        }

        let stoppingDeadline = Date().addingTimeInterval(2)
        while !capture.isStopping {
            if Date() >= stoppingDeadline {
                stopTaskA.cancel()
                _ = try? await stopTaskA.value
                XCTFail("stopAsync() did not enter its stopping state")
                return
            }
            await Task.yield()
        }

        // Start session B with different locale and engine while session A is still stopping
        let stateB = LiveRecognitionState()
        capture.startForTesting(
            state: stateB,
            options: SpeechTranscriberOptions(
                locale: Locale(identifier: "en_US"),
                requireOnDeviceRecognition: true
            )
        )
        stateA.recordResult(text: "Texte en français complet", confidence: 0.94, isFinal: true)

        let transcriptA = try await stopTaskA.value
        XCTAssertEqual(transcriptA.text, "Texte en français complet")
        XCTAssertEqual(transcriptA.locale, "fr_FR")
        XCTAssertEqual(transcriptA.engine, .appleNetwork)

        // Mid-capture failure after partial text stops capture while preserving partial transcriptText
        stateB.recordResult(text: "Partial English text", confidence: 0.88, isFinal: false)
        stateB.recordError(NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1101,
            userInfo: [NSLocalizedDescriptionKey: "Speech service interrupted"]
        ))
        capture.handleRecognitionCallbackError(for: stateB)
        XCTAssertFalse(capture.isCapturing)
        XCTAssertEqual(capture.transcriptText, "Partial English text")
        XCTAssertTrue(capture.lastError?.contains("kAFAssistantErrorDomain code 1101") == true)

        // Timeout before final result throws recognitionFailed instead of returning partial text as final
        let stateC = LiveRecognitionState()
        capture.startForTesting(
            state: stateC,
            options: SpeechTranscriberOptions(locale: Locale(identifier: "en_US"))
        )
        stateC.recordResult(text: "Unfinished partial text", confidence: 0.75, isFinal: false)
        do {
            _ = try await capture.stopAsync(timeout: 0.03)
            XCTFail("Expected stopAsync() timeout to throw recognitionFailed")
        } catch let error as SpeechNoteCaptureError {
            guard case .recognitionFailed = error else {
                XCTFail("Expected .recognitionFailed, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testSpeechCaptureControllerWaitsForInFlightStopAndCancelsPendingPermissionStart() async {
        // 1. matchesRequestedLanguage allows same-language region fallback and rejects cross-language fallback
        XCTAssertTrue(SpeechNoteCapture.matchesRequestedLanguage(
            Locale(identifier: "en_US"),
            requestedLocale: Locale(identifier: "en-AU")
        ))
        XCTAssertFalse(SpeechNoteCapture.matchesRequestedLanguage(
            Locale(identifier: "en_US"),
            requestedLocale: Locale(identifier: "fr-FR")
        ))

        // 2. finalizeIfCapturing waits for an already-running stop operation
        let controller = SpeechCaptureController()
        let state = LiveRecognitionState()
        controller.capture.startForTesting(
            state: state,
            options: SpeechTranscriberOptions(locale: Locale(identifier: "en_US"))
        )
        controller.isCapturing = true

        let toggleStopTask = Task { @MainActor in
            await controller.toggle(
                configuration: .transcriptOnly(maxDuration: 60, requireOnDeviceTranscription: false)
            )
        }
        let stoppingDeadline = Date().addingTimeInterval(2)
        while !controller.isStopping {
            if Date() >= stoppingDeadline {
                toggleStopTask.cancel()
                await toggleStopTask.value
                XCTFail("Controller did not enter stopping state")
                return
            }
            await Task.yield()
        }

        let finalizeTask = Task { @MainActor in
            await controller.finalizeIfCapturing()
        }
        await Task.yield()
        state.recordResult(text: "Transcript completed during in-flight stop", confidence: 0.96, isFinal: true)

        await finalizeTask.value
        await toggleStopTask.value
        XCTAssertEqual(controller.transcript?.text, "Transcript completed during in-flight stop")
        XCTAssertFalse(controller.isStopping)
        XCTAssertFalse(controller.isCapturing)

        // 3. cancelCapture invalidates a pending start while permission prompt is awaiting
        var resumePermission: CheckedContinuation<SpeechTranscriberAuthorizationStatus, Never>?
        controller.capture.speechAuthorizationProvider = {
            await withCheckedContinuation { continuation in
                resumePermission = continuation
            }
        }
        controller.capture.microphonePermissionProvider = { true }

        let startTask = Task { @MainActor in
            await controller.toggle(
                configuration: .transcriptOnly(maxDuration: 60, requireOnDeviceTranscription: false)
            )
        }
        let permissionDeadline = Date().addingTimeInterval(2)
        while resumePermission == nil {
            if Date() >= permissionDeadline {
                startTask.cancel()
                await startTask.value
                XCTFail("Pending start did not reach permission await")
                return
            }
            await Task.yield()
        }

        // Sheet dismisses while permission alert is still visible
        controller.cancelCapture()
        resumePermission?.resume(returning: .authorized)
        await startTask.value

        XCTAssertFalse(controller.isCapturing)
        XCTAssertFalse(controller.capture.isCapturing)
        XCTAssertNil(controller.errorMessage)
    }
    #endif

    @MainActor
    func testSpeechCaptureControllerMergeTranscriptFillsAndAppendsWithoutDuplicating() {
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript("Dictated quest note", into: ""),
            "Dictated quest note"
        )
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript("   Dictated quest note  ", into: "   "),
            "Dictated quest note"
        )
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript("Second sentence", into: "First sentence"),
            "First sentence\nSecond sentence"
        )
        // Idempotent when the same transcript is merged again (e.g. onChange + submit)
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript("Second sentence", into: "First sentence\nSecond sentence"),
            "First sentence\nSecond sentence"
        )
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript("   ", into: "Existing note"),
            "Existing note"
        )

        // Preserves existingComment when combined length exceeds 20,000 characters
        let longComment = String(repeating: "a", count: 19_995)
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript("123456", into: longComment),
            longComment
        )

        // Counts UTF-16 code units so surrogate-pair emoji cannot exceed the 20,000 UTF-16 server limit
        let emojiComment = String(repeating: "😀", count: 10_000)
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript("x", into: emojiComment),
            emojiComment
        )
        let oversizedEmojiTranscript = String(repeating: "😀", count: 10_001)
        XCTAssertEqual(
            SpeechCaptureController.mergeTranscript(oversizedEmojiTranscript, into: ""),
            ""
        )

        // consumeTranscriptForCommentMerge merges each completed transcript once so later user edits are preserved
        let controller = SpeechCaptureController()
        controller.transcript = HollerKitTranscript(
            text: "Original dictated note",
            locale: "en-US",
            engine: .appleNetwork
        )
        var comment = controller.consumeTranscriptForCommentMerge(into: "")
        XCTAssertEqual(comment, "Original dictated note")

        // User edits the comment before submitting
        comment = "Original dictated note (edited by tester)"
        let commentOnSubmit = controller.consumeTranscriptForCommentMerge(into: comment)
        XCTAssertEqual(commentOnSubmit, "Original dictated note (edited by tester)")
    }

    @MainActor
    func testCheckAllStepsMarksAllQuestStepsAndRecordsBreadcrumb() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-check-all-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let questDef = QuestDefinition(
            id: "hollerkit-shake-report",
            title: "Shake to report and run quest",
            area: "qa",
            steps: ["Shake device", "Record voice note", "Submit quest run"],
            expect: ["Transcript fills comment"]
        )

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            quests: .definitions([questDef]),
            outboxDirectoryURL: tempDir
        ))

        guard let item = HollerKit.quests.quests.first else {
            XCTFail("Expected quest item")
            return
        }

        HollerKit.quests.startQuest(item)
        defer { QuestOverlayWindowManager.shared.hide() }

        XCTAssertEqual(HollerKit.quests.activeQuest?.stepsChecked, [false, false, false])

        HollerKit.quests.checkAllSteps()
        XCTAssertEqual(HollerKit.quests.activeQuest?.stepsChecked, [true, true, true])

        // Uncheck one step and verify checkAllSteps() marks the mixed state back to all-checked
        HollerKit.quests.toggleStep(at: 1)
        XCTAssertEqual(HollerKit.quests.activeQuest?.stepsChecked, [true, false, true])
        HollerKit.quests.checkAllSteps()
        XCTAssertEqual(HollerKit.quests.activeQuest?.stepsChecked, [true, true, true])

        let breadcrumbs = HollerKit.currentBreadcrumbs.snapshot()
        XCTAssertTrue(breadcrumbs.contains(where: {
            $0.category == "quest_step" && $0.metadata["checkedAll"] == "true"
        }))
    }

    @MainActor
    func testBugReportDraftResetsAcrossRePresentationSendAnotherAndSwipeToDismiss() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-draft-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let receivedRequestsBox = LockedBox<[[String: Any]]>([])
        StubURLProtocol.setHandler { request, bodyData in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.path == "/v1/feedback", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                receivedRequestsBox.withLock { $0.append(body) }
                let id = (body["id"] as? String) ?? UUID().uuidString.lowercased()
                let comment = body["comment"] as? String
                let build = (body["build"] as? String) ?? "1"
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "idempotent": false,
                    "feedback": [
                        "id": id,
                        "kind": "report",
                        "build": build,
                        "submitterId": "tester-1",
                        "createdAt": "2026-11-08T20:00:00Z",
                        "updatedAt": "2026-11-08T20:00:00Z",
                        "comment": comment as Any
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let session = makeStubSession()
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            urlSession: session,
            outboxDirectoryURL: tempDir
        )
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(config)

        // 1. First shake presentation & submit
        HollerKit.presentBugReport()
        let firstPresentationId = HollerKit.currentPresentationId
        let firstDraft = HollerKit.currentBugReportDraft
        firstDraft.autoDismissDelaySeconds = 0
        XCTAssertEqual(firstDraft.comment, "")
        XCTAssertNil(firstDraft.submissionOutcome)
        XCTAssertFalse(firstDraft.canSubmit(configuration: config))

        firstDraft.comment = "First report comment"
        XCTAssertTrue(firstDraft.canSubmit(configuration: config))

        await firstDraft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore
        )

        // Inputs are cleared immediately after submit so stale text never remains in the comment box
        XCTAssertEqual(firstDraft.comment, "")
        guard case .sent = firstDraft.submissionOutcome else {
            XCTFail("Expected first submission outcome to be .sent, got \(String(describing: firstDraft.submissionOutcome))")
            return
        }
        XCTAssertFalse(firstDraft.canSubmit(configuration: config))

        // 2. Second shake presentation creates a fresh empty draft and new presentationId
        HollerKit.presentBugReport()
        let secondPresentationId = HollerKit.currentPresentationId
        let secondDraft = HollerKit.currentBugReportDraft
        secondDraft.autoDismissDelaySeconds = 0
        XCTAssertNotEqual(secondPresentationId, firstPresentationId)
        XCTAssertNotEqual(secondDraft.id, firstDraft.id)
        XCTAssertEqual(secondDraft.comment, "")
        XCTAssertNil(secondDraft.submissionOutcome)

        secondDraft.comment = "Second report after re-present"
        await secondDraft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore
        )
        XCTAssertEqual(secondDraft.comment, "")
        guard case .sent = secondDraft.submissionOutcome else {
            XCTFail("Expected second submission outcome to be .sent, got \(String(describing: secondDraft.submissionOutcome))")
            return
        }

        // 3. "Send Another" within the same sheet resets the draft and sends a third distinct report
        secondDraft.resetForAnotherReport(configuration: config)
        XCTAssertEqual(secondDraft.comment, "")
        XCTAssertNil(secondDraft.submissionOutcome)
        secondDraft.comment = "Third report via Send Another"
        await secondDraft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore
        )
        XCTAssertEqual(secondDraft.comment, "")
        guard case .sent = secondDraft.submissionOutcome else {
            XCTFail("Expected third submission outcome to be .sent, got \(String(describing: secondDraft.submissionOutcome))")
            return
        }

        // 4. Swipe-to-dismiss on a populated unsent draft clears the draft before presenting again
        secondDraft.resetForAnotherReport(configuration: config)
        secondDraft.comment = "Unsent text before swipe dismiss"
        XCTAssertEqual(HollerKit.currentBugReportDraft.comment, "Unsent text before swipe dismiss")
        HollerKit.presenterState.isPresented = false
        HollerKit.clearPresentationAttachments()
        XCTAssertFalse(HollerKit.presenterState.isPresented)
        XCTAssertEqual(HollerKit.currentBugReportDraft.comment, "")

        HollerKit.presentBugReport()
        let fourthDraft = HollerKit.currentBugReportDraft
        fourthDraft.autoDismissDelaySeconds = 0
        XCTAssertEqual(fourthDraft.comment, "")
        XCTAssertNil(fourthDraft.submissionOutcome)
        fourthDraft.comment = "Fourth report after swipe dismiss"
        await fourthDraft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore
        )
        XCTAssertEqual(fourthDraft.comment, "")
        guard case .sent = fourthDraft.submissionOutcome else {
            XCTFail("Expected fourth submission outcome to be .sent, got \(String(describing: fourthDraft.submissionOutcome))")
            return
        }

        let submittedRequests = receivedRequestsBox.withLock { $0 }
        XCTAssertEqual(submittedRequests.count, 4)
        let comments = submittedRequests.compactMap { $0["comment"] as? String }
        XCTAssertEqual(comments, [
            "First report comment",
            "Second report after re-present",
            "Third report via Send Another",
            "Fourth report after swipe dismiss"
        ])
        let ids = Set(submittedRequests.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids.count, 4, "Each submitted report must have a distinct feedback UUID")

        // 5. Speech finalization failure during submit preserves partialTranscript and comment without sending
        let failedSpeechDraft = BugReportDraft(configuration: config)
        failedSpeechDraft.comment = "Typed note before dictation failed"
        let speechState = LiveRecognitionState()
        failedSpeechDraft.speechCapture.capture.startForTesting(
            state: speechState,
            options: SpeechTranscriberOptions(locale: Locale(identifier: "en_US"))
        )
        failedSpeechDraft.speechCapture.isCapturing = true
        speechState.recordResult(text: "Partial dictated words", confidence: 0.85, isFinal: false)
        speechState.recordError(NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1101,
            userInfo: [NSLocalizedDescriptionKey: "Speech recognition failed on stop"]
        ))

        await failedSpeechDraft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore
        )
        XCTAssertEqual(failedSpeechDraft.comment, "Typed note before dictation failed")
        XCTAssertEqual(failedSpeechDraft.speechCapture.partialTranscript, "Partial dictated words")
        XCTAssertNotNil(failedSpeechDraft.speechCapture.errorMessage)
        XCTAssertNil(failedSpeechDraft.submissionOutcome)
        XCTAssertEqual(receivedRequestsBox.withLock { $0.count }, 4)
    }

    @MainActor
    func testBugReportSheetStaysOpenAfterSendAndResetsToBlankReportForSubsequentSend() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-stay-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let receivedRequestsBox = LockedBox<[[String: Any]]>([])
        StubURLProtocol.setHandler { request, bodyData in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.path == "/v1/feedback", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                receivedRequestsBox.withLock { $0.append(body) }
                let id = (body["id"] as? String) ?? UUID().uuidString.lowercased()
                let comment = body["comment"] as? String
                let build = (body["build"] as? String) ?? "1"
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "idempotent": false,
                    "feedback": [
                        "id": id,
                        "kind": "report",
                        "build": build,
                        "submitterId": "tester-stayopen",
                        "createdAt": "2026-11-11T20:00:00Z",
                        "updatedAt": "2026-11-11T20:00:00Z",
                        "comment": comment as Any
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let session = makeStubSession()
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            urlSession: session,
            outboxDirectoryURL: tempDir
        )
        XCTAssertEqual(config.afterSend, .stayOpen)
        XCTAssertTrue(config.afterSend.isStayOpen)
        XCTAssertEqual(config.afterSend.delay, 1.2)
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(config)

        // 1. Present bug report sheet
        HollerKit.presentBugReport()
        XCTAssertTrue(HollerKit.isPresentationRequested)
        let draft = HollerKit.currentBugReportDraft
        XCTAssertEqual(draft.comment, "")
        XCTAssertNil(draft.submissionOutcome)
        XCTAssertFalse(draft.canSubmit(configuration: config))

        // Configure a fast auto-reset delay for unit testing
        draft.autoDismissDelaySeconds = 0.05
        draft.comment = "First bug report: profile button broken"
        XCTAssertTrue(draft.canSubmit(configuration: config))

        // Submit first report
        let resetCalledBox = LockedBox<Bool>(false)
        await draft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore,
            onAutoReset: {
                resetCalledBox.withLock { $0 = true }
            }
        )

        // Immediately after submit returns, comment is cleared, outcome is .sent, and sheet is still open
        XCTAssertEqual(draft.comment, "")
        guard case .sent(let firstResponse) = draft.submissionOutcome else {
            XCTFail("Expected first submission outcome to be .sent, got \(String(describing: draft.submissionOutcome))")
            return
        }
        XCTAssertEqual(firstResponse.feedback.comment, "First bug report: profile button broken")
        XCTAssertTrue(HollerKit.isPresentationRequested, "Sheet must remain presented after first send succeeds")

        // Wait for auto-reset delay to trigger
        for _ in 0..<20 {
            if resetCalledBox.withLock({ $0 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(resetCalledBox.withLock { $0 }, "onAutoReset must be called after reset delay")

        // Sheet is still open, but draft has been blanked out
        XCTAssertTrue(HollerKit.isPresentationRequested, "Sheet must remain presented after draft auto-resets")
        XCTAssertNil(draft.submissionOutcome, "submissionOutcome must be cleared to dismiss overlay")
        XCTAssertEqual(draft.comment, "", "Comment must be empty for subsequent report")
        XCTAssertEqual(draft.images.count, 0, "Images must be empty for subsequent report")
        XCTAssertFalse(draft.isSubmitting)
        XCTAssertFalse(draft.canSubmit(configuration: config))

        // 2. Submit second report from the exact same sheet without dismissing or shaking again
        draft.autoDismissDelaySeconds = 0.05
        draft.comment = "Second bug report: dark mode colors inverted"
        XCTAssertTrue(draft.canSubmit(configuration: config))

        let secondResetCalledBox = LockedBox<Bool>(false)
        await draft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore,
            onAutoReset: {
                secondResetCalledBox.withLock { $0 = true }
            }
        )

        XCTAssertEqual(draft.comment, "")
        guard case .sent(let secondResponse) = draft.submissionOutcome else {
            XCTFail("Expected second submission outcome to be .sent, got \(String(describing: draft.submissionOutcome))")
            return
        }
        XCTAssertEqual(secondResponse.feedback.comment, "Second bug report: dark mode colors inverted")
        XCTAssertNotEqual(firstResponse.feedback.id, secondResponse.feedback.id)
        XCTAssertTrue(HollerKit.isPresentationRequested, "Sheet remains open after second report")

        for _ in 0..<20 {
            if secondResetCalledBox.withLock({ $0 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(secondResetCalledBox.withLock { $0 })
        XCTAssertNil(draft.submissionOutcome)

        // 3. Close the sheet via dismiss / clearPresentationAttachments
        HollerKit.presenterState.isPresented = false
        HollerKit.clearPresentationAttachments()
        XCTAssertFalse(HollerKit.isPresentationRequested)

        // Verify both reports were sent to server
        let requests = receivedRequestsBox.withLock { $0 }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["comment"] as? String, "First bug report: profile button broken")
        XCTAssertEqual(requests[1]["comment"] as? String, "Second bug report: dark mode colors inverted")

        // 4. Verify afterSend: .close auto-dismisses instead of staying open
        let closeDismissedBox = LockedBox<Bool>(false)
        let closeConfig = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            afterSend: .close(delay: 0.05),
            urlSession: session,
            outboxDirectoryURL: tempDir
        )
        XCTAssertEqual(closeConfig.afterSend, .close(delay: 0.05))
        XCTAssertFalse(closeConfig.afterSend.isStayOpen)
        XCTAssertEqual(closeConfig.afterSend.delay, 0.05)
        HollerKit.configure(closeConfig)

        HollerKit.presentBugReport()
        XCTAssertTrue(HollerKit.isPresentationRequested)
        let closeDraft = HollerKit.currentBugReportDraft
        closeDraft.autoDismissDelaySeconds = 0.05
        closeDraft.comment = "Third report expecting auto-close"

        await closeDraft.submit(
            configuration: closeConfig,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore,
            onAutoDismiss: {
                closeDismissedBox.withLock { $0 = true }
                HollerKit.presenterState.isPresented = false
                HollerKit.clearPresentationAttachments()
            }
        )

        for _ in 0..<20 {
            if closeDismissedBox.withLock({ $0 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(closeDismissedBox.withLock { $0 }, "onAutoDismiss must be called when afterSend is .close")
        XCTAssertFalse(HollerKit.isPresentationRequested)

        // 5. Verify configured afterSend: .stayOpen(resetDelay: 0) immediately resets without timer
        let immediateStayOpenConfig = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            afterSend: .stayOpen(resetDelay: 0),
            urlSession: session,
            outboxDirectoryURL: tempDir
        )
        HollerKit.configure(immediateStayOpenConfig)
        HollerKit.presentBugReport()
        let immediateDraft = HollerKit.currentBugReportDraft
        immediateDraft.comment = "Immediate reset test"
        let immediateResetBox = LockedBox<Bool>(false)
        await immediateDraft.submit(
            configuration: immediateStayOpenConfig,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore,
            onAutoReset: {
                immediateResetBox.withLock { $0 = true }
            }
        )
        XCTAssertTrue(immediateResetBox.withLock { $0 }, "Immediate reset must execute synchronously when resetDelay is 0")
        XCTAssertNil(immediateDraft.submissionOutcome)
        XCTAssertEqual(immediateDraft.comment, "")
        XCTAssertTrue(HollerKit.isPresentationRequested)
        HollerKit.presenterState.isPresented = false
        HollerKit.clearPresentationAttachments()

        // 6. Verify configured afterSend: .close(delay: 0) immediately calls onAutoDismiss
        let immediateCloseConfig = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            afterSend: .close(delay: 0),
            urlSession: session,
            outboxDirectoryURL: tempDir
        )
        HollerKit.configure(immediateCloseConfig)
        HollerKit.presentBugReport()
        let immediateCloseDraft = HollerKit.currentBugReportDraft
        immediateCloseDraft.comment = "Immediate close test"
        let immediateCloseBox = LockedBox<Bool>(false)
        await immediateCloseDraft.submit(
            configuration: immediateCloseConfig,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore,
            onAutoDismiss: {
                immediateCloseBox.withLock { $0 = true }
                HollerKit.presenterState.isPresented = false
                HollerKit.clearPresentationAttachments()
            }
        )
        XCTAssertTrue(immediateCloseBox.withLock { $0 }, "Immediate close must execute synchronously when delay is 0")
        XCTAssertFalse(HollerKit.isPresentationRequested)
    }

    #if canImport(UIKit)
    @MainActor
    /// Verifies attaching photos, pasting from the clipboard, removing attachments, downsampling/JPEG compression,
    /// and automatic upload-grant refresh when submitting an image-only report.
    func testBugReportDraftAttachPasteRemoveAndCompressImages() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HollerKitTests-PhotoAttach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let uploadedMimeTypesBox = LockedBox<[String]>([])
        let uploadedPutSizesBox = LockedBox<[Int]>([])
        let issuedGrantKeysBox = LockedBox<[String]>([])
        let submittedAttachmentsBox = LockedBox<[[String: Any]]>([])
        let simulateExpiredGrantOnceBox = LockedBox<Bool>(true)

        StubURLProtocol.setHandler { request, bodyData in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.path == "/v1/uploads" {
                let json = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                if let mimeType = json["mimeType"] as? String {
                    uploadedMimeTypesBox.withLock { $0.append(mimeType) }
                }
                let grantKey = "uploads/image-\(UUID().uuidString)"
                issuedGrantKeysBox.withLock { $0.append(grantKey) }
                let grantJSON: [String: Any] = [
                    "ok": true,
                    "url": "https://upload.hollerkit.test/put/\(UUID().uuidString)",
                    "key": grantKey,
                    "expiresAt": "2099-01-01T00:00:00Z"
                ]
                let data = try JSONSerialization.data(withJSONObject: grantJSON)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            if url.host == "upload.hollerkit.test" {
                uploadedPutSizesBox.withLock { $0.append(bodyData?.count ?? 0) }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            if url.path == "/v1/feedback" {
                let shouldRejectWithExpiredGrant = simulateExpiredGrantOnceBox.withLock { value -> Bool in
                    if value {
                        value = false
                        return true
                    }
                    return false
                }
                if shouldRejectWithExpiredGrant {
                    let errorJSON: [String: Any] = [
                        "ok": false,
                        "error": [
                            "code": "expired_or_consumed_grant",
                            "message": "Attachment grant has expired."
                        ]
                    ]
                    let data = try JSONSerialization.data(withJSONObject: errorJSON)
                    let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
                    return (response, data)
                }

                let json = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                let feedbackId = (json["id"] as? String) ?? UUID().uuidString.lowercased()
                let build = (json["build"] as? String) ?? "1"
                let attachments = (json["attachments"] as? [[String: Any]]) ?? []
                submittedAttachmentsBox.withLock { $0 = attachments }
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "idempotent": false,
                    "feedback": [
                        "id": feedbackId,
                        "kind": "report",
                        "build": build,
                        "submitterId": "tester-1",
                        "createdAt": "2026-11-08T20:00:00Z",
                        "updatedAt": "2026-11-08T20:00:00Z"
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let session = makeStubSession()
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            urlSession: session,
            outboxDirectoryURL: tempDir
        )

        let draft = BugReportDraft(configuration: config)
        draft.autoDismissDelaySeconds = 0
        XCTAssertTrue(draft.images.isEmpty)
        XCTAssertTrue(draft.canAddMoreImages)
        XCTAssertEqual(draft.remainingImageSlots, 12)
        XCTAssertFalse(draft.canSubmit(configuration: config))

        // 1. Add Photo via Data enables submission even with an empty comment
        let smallImage = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let smallPNGData = try XCTUnwrap(smallImage.pngData())
        XCTAssertTrue(draft.addImageData(smallPNGData))
        XCTAssertEqual(draft.images.count, 1)
        XCTAssertEqual(draft.images[0].title, "Photo 1")
        XCTAssertTrue(draft.canSubmit(configuration: config))

        // 2. Paste images from clipboard joins the list and can be annotated or removed
        let pastedImage = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        let pastedCount = draft.pasteImagesFromClipboard(images: [pastedImage])
        XCTAssertEqual(pastedCount, 1)
        XCTAssertEqual(draft.images.count, 2)
        XCTAssertEqual(draft.images[1].title, "Pasted Image 2")

        // Annotating replaces the image in-place
        let annotatedImage = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        draft.replaceImage(id: draft.images[1].id, with: annotatedImage)
        XCTAssertEqual(draft.images[1].image.size.width, 80)

        // Removing the first image leaves only the pasted/annotated image
        let firstId = draft.images[0].id
        draft.selectedImage = draft.images[0]
        draft.removeImage(id: firstId)
        XCTAssertNil(draft.selectedImage)
        XCTAssertEqual(draft.images.count, 1)
        XCTAssertEqual(draft.images[0].title, "Pasted Image 2")

        // 3. Oversized images are downscaled to maxPixelDimension and compressed to JPEG when PNG exceeds threshold
        let oversizedFormat = UIGraphicsImageRendererFormat.default()
        oversizedFormat.scale = 1.0
        let oversizedImage = UIGraphicsImageRenderer(
            size: CGSize(width: 3600, height: 2700),
            format: oversizedFormat
        ).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3600, height: 2700))
        }
        let normalized = BugReportImage.normalizedImage(oversizedImage)
        XCTAssertEqual(normalized.size.width * normalized.scale, 2400, accuracy: 1.0)
        XCTAssertEqual(normalized.size.height * normalized.scale, 1800, accuracy: 1.0)

        let bugImage = BugReportImage(title: "Camera Photo", image: oversizedImage)
        let jpegAttachment = try XCTUnwrap(bugImage.encodedAttachment(
            index: 0,
            maxBytes: 250_000,
            preferredPNGMaxBytes: 100
        ))
        XCTAssertEqual(jpegAttachment.mimeType, "image/jpeg")
        XCTAssertEqual(jpegAttachment.filename, "Camera Photo.jpg")
        XCTAssertLessThanOrEqual(jpegAttachment.data.count, 250_000)

        // 4. Cap at 12 images per report
        let extraImages = (0..<15).map { _ in smallImage }
        let addedFromBatch = draft.pasteImagesFromClipboard(images: extraImages)
        XCTAssertEqual(addedFromBatch, 11)
        XCTAssertEqual(draft.images.count, BugReportDraft.maxAttachments)
        XCTAssertFalse(draft.canAddMoreImages)
        XCTAssertEqual(draft.remainingImageSlots, 0)
        XCTAssertNotNil(draft.attachmentStatusMessage)
        XCTAssertFalse(draft.addImage(smallImage))

        // Remove 10 images so we submit 2 distinct attached images (annotated 80x80 + small 40x40)
        while draft.images.count > 2 {
            draft.removeImage(id: draft.images.last!.id)
        }
        XCTAssertEqual(draft.images.count, 2)
        XCTAssertTrue(draft.canAddMoreImages)
        XCTAssertNil(draft.attachmentStatusMessage)

        // 5. Submit image-only report through OutboxStore (including automatic retry when an upload grant expires)
        let outbox = OutboxStore(rootDirectoryURL: tempDir)
        await draft.submit(
            configuration: config,
            breadcrumbs: BreadcrumbStore(),
            outboxStore: outbox
        )
        guard case .sent = draft.submissionOutcome else {
            XCTFail("Expected image-only report submission to succeed, got \(String(describing: draft.submissionOutcome))")
            return
        }
        XCTAssertTrue(draft.images.isEmpty)
        // 2 initial uploads + 2 refreshed-grant uploads after expired_or_consumed_grant = 4 uploads
        XCTAssertEqual(uploadedMimeTypesBox.withLock { $0 }, ["image/png", "image/png", "image/png", "image/png"])
        let uploadedSizes = uploadedPutSizesBox.withLock { $0 }
        XCTAssertEqual(uploadedSizes.count, 4)
        XCTAssertTrue(uploadedSizes.allSatisfy { $0 > 0 })
        XCTAssertNotEqual(uploadedSizes[0], uploadedSizes[1], "Distinct images should produce distinct upload payloads")
        let issuedGrantKeys = issuedGrantKeysBox.withLock { $0 }
        XCTAssertEqual(issuedGrantKeys.count, 4)
        let submittedAttachments = submittedAttachmentsBox.withLock { $0 }
        XCTAssertEqual(submittedAttachments.count, 2)
        let submittedKeys = submittedAttachments.compactMap { $0["key"] as? String }
        XCTAssertEqual(submittedKeys, Array(issuedGrantKeys.suffix(2)))
        XCTAssertNotEqual(submittedKeys, Array(issuedGrantKeys.prefix(2)))
        XCTAssertNotEqual(submittedAttachments[0]["key"] as? String, submittedAttachments[1]["key"] as? String)
    }

    #if canImport(UIKit)
    @MainActor
    /// Verifies attaching photos, pasting from the clipboard, removing attachments, downsampling/JPEG compression,
    /// and submitting user-attached photos alongside marks in an active quest run.
    func testQuestResultDraftAttachPasteRemoveAndCompressImages() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HollerKitTests-QuestPhotoAttach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let uploadedMimeTypesBox = LockedBox<[String]>([])
        let uploadedPutSizesBox = LockedBox<[Int]>([])
        let issuedGrantKeysBox = LockedBox<[String]>([])
        let submittedAttachmentsBox = LockedBox<[[String: Any]]>([])
        let submittedFeedbackBox = LockedBox<[String: Any]?>([:])
        let simulateExpiredGrantOnceBox = LockedBox<Bool>(true)

        StubURLProtocol.setHandler { request, bodyData in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.path.hasSuffix("/manifest") {
                let json = """
                {
                  "ok": true,
                  "build": "1",
                  "pendingCount": 1,
                  "quests": [
                    {
                      "id": "camera-mode-switch",
                      "version": 1,
                      "contentHash": "test-hash",
                      "questStatus": "active",
                      "boardStatus": "pending",
                      "title": "Switch between wide and ultra-wide cameras",
                      "area": "camera",
                      "setup": ["Camera permission granted"],
                      "steps": ["Tap 0.5x button", "Verify zoom level", "Tap 1x button"],
                      "expect": ["Smooth transition between lenses"],
                      "needs": ["device"],
                      "record": "suggested",
                      "start": "trashapp://camera",
                      "counts": { "pass": 0, "fail": 0, "unsure": 0, "abandoned": 0 }
                    }
                  ]
                }
                """
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["hollerkit-protocol": "1"])!
                return (response, Data(json.utf8))
            }
            if url.path == "/v1/uploads" {
                let json = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                if let mimeType = json["mimeType"] as? String {
                    uploadedMimeTypesBox.withLock { $0.append(mimeType) }
                }
                let grantKey = "uploads/quest-attachment-\(UUID().uuidString)"
                issuedGrantKeysBox.withLock { $0.append(grantKey) }
                let grantJSON: [String: Any] = [
                    "ok": true,
                    "url": "https://upload.hollerkit.test/put/\(UUID().uuidString)",
                    "key": grantKey,
                    "expiresAt": "2099-01-01T00:00:00Z"
                ]
                let data = try JSONSerialization.data(withJSONObject: grantJSON)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            if url.host == "upload.hollerkit.test" {
                uploadedPutSizesBox.withLock { $0.append(bodyData?.count ?? 0) }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            if url.path == "/v1/feedback" {
                let shouldRejectWithExpiredGrant = simulateExpiredGrantOnceBox.withLock { value -> Bool in
                    if value {
                        value = false
                        return true
                    }
                    return false
                }
                if shouldRejectWithExpiredGrant {
                    let errorJSON: [String: Any] = [
                        "ok": false,
                        "error": [
                            "code": "expired_or_consumed_grant",
                            "message": "Attachment grant has expired."
                        ]
                    ]
                    let data = try JSONSerialization.data(withJSONObject: errorJSON)
                    let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
                    return (response, data)
                }

                let json = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                submittedFeedbackBox.withLock { $0 = json }
                let feedbackId = (json["id"] as? String) ?? UUID().uuidString.lowercased()
                let build = (json["build"] as? String) ?? "1"
                let attachments = (json["attachments"] as? [[String: Any]]) ?? []
                submittedAttachmentsBox.withLock { $0 = attachments }
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "idempotent": false,
                    "feedback": [
                        "id": feedbackId,
                        "kind": "quest_run",
                        "build": build,
                        "submitterId": "tester-1",
                        "createdAt": "2026-11-08T20:00:00Z",
                        "updatedAt": "2026-11-08T20:00:00Z"
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let session = makeStubSession()
        let questDef = QuestDefinition(
            id: "camera-mode-switch",
            title: "Switch between wide and ultra-wide cameras",
            area: "camera",
            setup: ["Camera permission granted"],
            steps: ["Tap 0.5x button", "Verify zoom level", "Tap 1x button"],
            expect: ["Smooth transition between lenses"],
            needs: ["device"],
            start: "trashapp://camera"
        )
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            quests: .definitions([questDef]),
            urlSession: session,
            outboxDirectoryURL: tempDir
        )
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(config)
        await HollerKit.quests.refresh()
        guard let questItem = HollerKit.quests.quests.first else {
            XCTFail("Expected loaded quest item")
            return
        }

        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        HollerKit.quests.startQuest(questItem, startedAt: startDate)
        defer {
            if let active = HollerKit.quests.activeQuest {
                HollerKit.quests.completeSubmittedSession(id: active.id)
            }
        }
        XCTAssertNotNil(HollerKit.quests.activeQuest)

        // Capture an automatic mark during the quest run
        let markPNGData = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { ctx in
            UIColor.systemPurple.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }.pngData()!
        let mark = HollerKit.quests.captureMark(
            label: "Glitch on 0.5x toggle",
            imageData: markPNGData,
            at: startDate.addingTimeInterval(3.0)
        )
        XCTAssertNotNil(mark)

        // 1. Initial draft state
        let draft = QuestResultDraft(initialResult: .fail, initialComment: "Lens stuck for a second")
        draft.autoDismissDelaySeconds = 0
        XCTAssertTrue(draft.images.isEmpty)
        XCTAssertTrue(draft.canAddMoreImages)
        XCTAssertEqual(draft.remainingImageSlots, QuestResultDraft.maxAttachments)
        XCTAssertEqual(draft.selectedResult, .fail)
        XCTAssertEqual(draft.comment, "Lens stuck for a second")

        // 2. Add Photo via Data
        let smallImage = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let smallPNGData = try XCTUnwrap(smallImage.pngData())
        XCTAssertTrue(draft.addImageData(smallPNGData))
        XCTAssertEqual(draft.images.count, 1)
        XCTAssertEqual(draft.images[0].title, "Photo 1")

        // 3. Add photo off-main-actor
        let offMainActorAdded = await draft.addImageDataOffMainActor(smallPNGData, title: "Detached Photo")
        XCTAssertTrue(offMainActorAdded)
        XCTAssertEqual(draft.images.count, 2)
        XCTAssertEqual(draft.images[1].title, "Detached Photo")

        // 4. Paste images from clipboard
        let pastedImage = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        let pastedCount = draft.pasteImagesFromClipboard(images: [pastedImage])
        XCTAssertEqual(pastedCount, 1)
        XCTAssertEqual(draft.images.count, 3)
        XCTAssertEqual(draft.images[2].title, "Pasted Image 3")

        // 5. Annotating replaces the image in-place
        let annotatedImage = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        draft.replaceImage(id: draft.images[2].id, with: annotatedImage)
        XCTAssertEqual(draft.images[2].image.size.width, 80)

        // 6. Removing an image
        let firstId = draft.images[0].id
        draft.selectedImage = draft.images[0]
        draft.removeImage(id: firstId)
        XCTAssertNil(draft.selectedImage)
        XCTAssertEqual(draft.images.count, 2)
        XCTAssertEqual(draft.images[0].title, "Detached Photo")
        XCTAssertEqual(draft.images[1].title, "Pasted Image 3")

        // 7. Oversized images are downscaled within maxPixelDimension
        let oversizedFormat = UIGraphicsImageRendererFormat.default()
        oversizedFormat.scale = 1.0
        let oversizedImage = UIGraphicsImageRenderer(
            size: CGSize(width: 3200, height: 2400),
            format: oversizedFormat
        ).image { ctx in
            UIColor.systemYellow.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3200, height: 2400))
        }
        let normalized = BugReportImage.normalizedImage(oversizedImage, maxPixelDimension: QuestResultDraft.maxPixelDimension)
        XCTAssertEqual(normalized.size.width * normalized.scale, 2400, accuracy: 1.0)
        XCTAssertEqual(normalized.size.height * normalized.scale, 1800, accuracy: 1.0)

        // 8. Cap at 12 attachments
        let extraImages = (0..<15).map { _ in smallImage }
        let addedFromBatch = draft.pasteImagesFromClipboard(images: extraImages)
        XCTAssertEqual(addedFromBatch, 10)
        XCTAssertEqual(draft.images.count, QuestResultDraft.maxAttachments)
        XCTAssertFalse(draft.canAddMoreImages)
        XCTAssertEqual(draft.remainingImageSlots, 0)
        XCTAssertNotNil(draft.attachmentStatusMessage)
        XCTAssertFalse(draft.addImage(smallImage))

        // Remove extra images so we submit 2 user-attached photos
        while draft.images.count > 2 {
            draft.removeImage(id: draft.images.last!.id)
        }
        XCTAssertEqual(draft.images.count, 2)
        XCTAssertTrue(draft.canAddMoreImages)
        XCTAssertNil(draft.attachmentStatusMessage)

        // 9. Submit quest run through QuestResultDraft (including retry on expired upload grant)
        await draft.submit(questState: HollerKit.quests)
        guard case .sent(let response) = draft.submissionOutcome else {
            XCTFail("Expected quest run submission to succeed, got \(String(describing: draft.submissionOutcome))")
            return
        }
        XCTAssertEqual(response.feedback.kind, "quest_run")
        XCTAssertTrue(draft.images.isEmpty, "Draft images should be cleared after successful submission")

        // Verify uploads: 1 mark + 2 user photos = 3 uploads, and with 1 grant expired retry = 6 uploads
        let uploadedMimeTypes = uploadedMimeTypesBox.withLock { $0 }
        XCTAssertEqual(uploadedMimeTypes.count, 6)
        XCTAssertTrue(uploadedMimeTypes.allSatisfy { $0 == "image/png" })

        // Verify submitted payload
        let submitted = submittedFeedbackBox.withLock { $0 }
        XCTAssertEqual(submitted?["kind"] as? String, "quest_run")
        XCTAssertEqual(submitted?["questId"] as? String, "camera-mode-switch")
        XCTAssertEqual(submitted?["result"] as? String, "fail")
        XCTAssertEqual(submitted?["comment"] as? String, "Lens stuck for a second")

        // Attachments on the quest run: 1 mark + 2 user photos = 3 attachments
        let submittedAttachments = submittedAttachmentsBox.withLock { $0 }
        XCTAssertEqual(submittedAttachments.count, 3)
        let markAttachments = submittedAttachments.filter { ($0["kind"] as? String) == "mark" }
        let imageAttachments = submittedAttachments.filter { ($0["kind"] as? String) == "image" }
        XCTAssertEqual(markAttachments.count, 1)
        XCTAssertEqual(imageAttachments.count, 2)
        XCTAssertEqual(markAttachments[0]["offsetSeconds"] as? Double ?? -1, 3.0, accuracy: 0.001)

        // 10. Verify QuestResultSheet view instantiation with custom draft
        let freshDraft = QuestResultDraft()
        let sheet = QuestResultSheet(questState: HollerKit.quests, draft: freshDraft)
        XCTAssertNotNil(sheet)
    }
    #endif

    @MainActor
    /// Verifies that `QuestCardView` renders its `Start Quest` button (including a visible `play.fill` icon
    /// and balanced capsule padding) and its start route row (`link` icon + route text with compact spacing)
    /// without `List` row `Label` icon-column distortion.
    func testQuestCardViewButtonAndRouteLayoutInsideList() throws {
        let definition = QuestDefinition(
            id: "map-route-quest",
            title: "Verify map pin clustering",
            area: "map",
            setup: ["Enable location permissions"],
            steps: ["Open the map tab", "Zoom out to city level"],
            expect: ["Pins cluster smoothly"],
            needs: ["logged_in"],
            start: "trashapp://map"
        )

        let pendingItem = QuestBoardItem(
            id: definition.id,
            version: 1,
            definition: definition,
            status: .pending,
            needWarnings: ["Needs condition 'logged_in' (not registered)"]
        )
        let passedItem = QuestBoardItem(
            id: definition.id,
            version: 1,
            definition: definition,
            status: .passed
        )
        let failedItem = QuestBoardItem(
            id: definition.id,
            version: 1,
            definition: definition,
            status: .failed
        )

        let pendingCard = QuestCardView(item: pendingItem, isActive: false, onStart: {})
        XCTAssertEqual(pendingCard.buttonTitle, "Start Quest")
        XCTAssertEqual(pendingCard.buttonSystemImage, "play.fill")

        let passedCard = QuestCardView(item: passedItem, isActive: false, onStart: {})
        XCTAssertEqual(passedCard.buttonTitle, "Re-run Quest")
        XCTAssertEqual(passedCard.buttonSystemImage, "play.fill")

        let failedCard = QuestCardView(item: failedItem, isActive: false, onStart: {})
        XCTAssertEqual(failedCard.buttonTitle, "Start Quest")
        XCTAssertEqual(failedCard.buttonSystemImage, "play.fill")

        let activeCard = QuestCardView(item: pendingItem, isActive: true, onStart: {})
        XCTAssertEqual(activeCard.buttonTitle, "Running...")
        XCTAssertEqual(activeCard.buttonSystemImage, "play.circle.fill")

        // Render QuestCardView inside a List (as QuestBoardView does) and inspect the rendered pixels
        // to ensure List row Label icon-column alignment does not distort the Start Quest button or route row.
        let listHostedView = List {
            QuestCardView(item: pendingItem, isActive: false, onStart: {})
        }
        .listStyle(.insetGrouped)
        .tint(.blue)
        .environment(\.colorScheme, .light)

        let controller = UIHostingController(rootView: listHostedView)
        let viewportSize = CGSize(width: 390, height: 500)
        let window = UIWindow(frame: CGRect(origin: .zero, size: viewportSize))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        controller.view.layoutIfNeeded()

        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 2.0
        let snapshot = UIGraphicsImageRenderer(size: viewportSize, format: rendererFormat).image { rendererContext in
            controller.view.layer.render(in: rendererContext.cgContext)
        }
        window.isHidden = true

        let cgImage = try XCTUnwrap(snapshot.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            XCTFail("Failed to create bitmap context")
            return
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Locate the prominent blue Start Quest button capsule in the right half of the card.
        var minBlueX = width
        var maxBlueX = 0
        var minBlueY = height
        var maxBlueY = 0
        for y in 0..<height {
            for x in (width / 2)..<width {
                let offset = y * bytesPerRow + x * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                // System blue capsule fill has strong blue dominance over red.
                if b > 180 && r < 80 && (b - r) > 120 {
                    if x < minBlueX { minBlueX = x }
                    if x > maxBlueX { maxBlueX = x }
                    if y < minBlueY { minBlueY = y }
                    if y > maxBlueY { maxBlueY = y }
                }
            }
        }

        XCTAssertLessThan(minBlueX, maxBlueX, "Expected to find blue Start Quest button capsule in List snapshot")
        XCTAssertLessThan(minBlueY, maxBlueY, "Expected non-empty vertical bounds for Start Quest button capsule")
        guard minBlueX < maxBlueX, minBlueY < maxBlueY else {
            return
        }

        // Within the vertical band of the button capsule, find white foreground pixels (icon + title)
        // that lie strictly inside each scanline's blue capsule span [rowMinBlueX, rowMaxBlueX].
        let midBandMinY = minBlueY + (maxBlueY - minBlueY) / 4
        let midBandMaxY = maxBlueY - (maxBlueY - minBlueY) / 4
        var minWhiteX = maxBlueX
        var maxWhiteX = minBlueX
        var whiteColumnMinY = [Int](repeating: height, count: width)
        var whiteColumnMaxY = [Int](repeating: 0, count: width)
        for y in midBandMinY...midBandMaxY {
            var rowMinBlueX = maxBlueX
            var rowMaxBlueX = minBlueX
            for x in minBlueX...maxBlueX {
                let offset = y * bytesPerRow + x * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                if b > 180 && r < 80 && (b - r) > 120 {
                    if x < rowMinBlueX { rowMinBlueX = x }
                    if x > rowMaxBlueX { rowMaxBlueX = x }
                }
            }
            guard rowMinBlueX < rowMaxBlueX else { continue }
            for x in rowMinBlueX...rowMaxBlueX {
                let offset = y * bytesPerRow + x * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                if r > 220 && g > 220 && b > 220 {
                    if x < minWhiteX { minWhiteX = x }
                    if x > maxWhiteX { maxWhiteX = x }
                    if y < whiteColumnMinY[x] { whiteColumnMinY[x] = y }
                    if y > whiteColumnMaxY[x] { whiteColumnMaxY[x] = y }
                }
            }
        }

        XCTAssertLessThan(minWhiteX, maxWhiteX, "Expected white icon and label pixels inside the Start Quest button")
        guard minWhiteX < maxWhiteX else {
            return
        }
        let scale = rendererFormat.scale
        let leadingPaddingPt = CGFloat(minWhiteX - minBlueX) / scale
        let trailingPaddingPt = CGFloat(maxBlueX - maxWhiteX) / scale

        // Group white columns inside the button capsule into contiguous horizontal clusters
        // so we can separately verify the leading play.fill icon and the Start Quest title text.
        var buttonWhiteClusters: [(start: Int, end: Int)] = []
        var currentWhiteStart: Int?
        for x in minBlueX...maxBlueX {
            if whiteColumnMinY[x] <= whiteColumnMaxY[x] {
                if currentWhiteStart == nil {
                    currentWhiteStart = x
                }
            } else if let start = currentWhiteStart {
                buttonWhiteClusters.append((start: start, end: x - 1))
                currentWhiteStart = nil
            }
        }
        if let start = currentWhiteStart {
            buttonWhiteClusters.append((start: start, end: maxBlueX))
        }

        XCTAssertGreaterThanOrEqual(
            buttonWhiteClusters.count,
            2,
            "Expected separate white pixel clusters for the play.fill icon and the Start Quest button title"
        )
        if buttonWhiteClusters.count >= 2 {
            let playIconCluster = buttonWhiteClusters[0]
            let playIconWidthPt = CGFloat(playIconCluster.end - playIconCluster.start + 1) / scale
            XCTAssertGreaterThan(playIconWidthPt, 5, "Expected visible play.fill icon width inside Start Quest button")
            XCTAssertLessThan(playIconWidthPt, 18, "Expected play.fill icon cluster to be distinct from title text")

            // Verify the leading cluster has the right-pointing triangle profile of play.fill
            // (taller vertical white span near its leading edge than near its trailing tip).
            let iconSpan = max(1, playIconCluster.end - playIconCluster.start)
            let leadingSampleX = playIconCluster.start + iconSpan / 4
            let trailingSampleX = playIconCluster.end - iconSpan / 5
            let leadingHeight = whiteColumnMaxY[leadingSampleX] - whiteColumnMinY[leadingSampleX]
            let trailingHeight = whiteColumnMaxY[trailingSampleX] - whiteColumnMinY[trailingSampleX]
            XCTAssertGreaterThan(
                leadingHeight,
                trailingHeight,
                "Expected play.fill icon cluster to taper from left (\(leadingHeight)px) to right (\(trailingHeight)px)"
            )

            let iconToTitleGapPt = CGFloat(buttonWhiteClusters[1].start - playIconCluster.end - 1) / scale
            XCTAssertGreaterThan(iconToTitleGapPt, 2, "Expected visible spacing between play.fill icon and button title")
            XCTAssertLessThan(iconToTitleGapPt, 10, "Expected compact HStack spacing between play.fill icon and button title")

            let buttonTitleWidthPt = CGFloat(buttonWhiteClusters.last!.end - buttonWhiteClusters[1].start + 1) / scale
            XCTAssertGreaterThan(buttonTitleWidthPt, 55, "Expected 'Start Quest' title text to render to the right of play.fill")
        }

        // Regression assertions for #26:
        // 1. The play.fill icon must appear near the leading edge (no huge empty slot on the left).
        XCTAssertLessThan(
            leadingPaddingPt,
            20,
            "Start Quest button has an unexpectedly wide leading empty area (\(leadingPaddingPt)pt); play icon may be missing"
        )
        // 2. The title must not sit flush against the trailing edge of the capsule.
        XCTAssertGreaterThan(
            trailingPaddingPt,
            6,
            "Start Quest button label is too close to the right edge (\(trailingPaddingPt)pt)"
        )
        // 3. Leading and trailing padding should be reasonably balanced.
        XCTAssertLessThan(
            abs(leadingPaddingPt - trailingPaddingPt),
            8,
            "Expected balanced horizontal padding in Start Quest button, got leading=\(leadingPaddingPt)pt trailing=\(trailingPaddingPt)pt"
        )

        // 4. Verify the start route ("trashapp://map") on the left side of the bottom row renders
        // both the link icon and the route text separately, with compact spacing between them.
        var routeForegroundColumns = [Bool](repeating: false, count: minBlueX)
        for x in 0..<minBlueX {
            for y in minBlueY...maxBlueY {
                let offset = y * bytesPerRow + x * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                // Secondary text/icon on white card row background (255, 255, 255)
                if r < 210 && g < 210 && b < 210 {
                    routeForegroundColumns[x] = true
                    break
                }
            }
        }
        var rawClusters: [(start: Int, end: Int)] = []
        var currentStart: Int?
        for x in 0..<minBlueX {
            if routeForegroundColumns[x] {
                if currentStart == nil {
                    currentStart = x
                }
            } else if let start = currentStart {
                rawClusters.append((start: start, end: x - 1))
                currentStart = nil
            }
        }
        if let start = currentStart {
            rawClusters.append((start: start, end: minBlueX - 1))
        }

        // Merge tiny 1px intra-symbol gaps so multi-stroke symbols stay a single cluster while preserving
        // inter-glyph and icon-to-text separation.
        var clusters: [(start: Int, end: Int)] = []
        for cluster in rawClusters {
            if let last = clusters.last, (cluster.start - last.end - 1) <= 1 {
                clusters[clusters.count - 1] = (start: last.start, end: cluster.end)
            } else {
                clusters.append(cluster)
            }
        }

        XCTAssertGreaterThanOrEqual(
            clusters.count,
            2,
            "Expected link icon and route text clusters on the left side of the bottom row"
        )
        if clusters.count >= 2 {
            let linkIconCluster = clusters[0]
            let linkIconWidthPt = CGFloat(linkIconCluster.end - linkIconCluster.start + 1) / scale
            // The SF Symbol 'link' glyph is wider than a single caption2.monospaced() character (~5pt),
            // ensuring clusters[0] is the link icon rather than the first character of "trashapp://map".
            XCTAssertGreaterThan(
                linkIconWidthPt,
                7.5,
                "Expected leading route cluster to be the 'link' icon (got width \(linkIconWidthPt)pt, which looks like a single text glyph)"
            )
            XCTAssertLessThan(
                linkIconWidthPt,
                18,
                "Expected leading route cluster to be a single 'link' icon, got width \(linkIconWidthPt)pt"
            )

            let routeTextWidthPt = CGFloat(clusters.last!.end - clusters[1].start + 1) / scale
            XCTAssertGreaterThan(
                routeTextWidthPt,
                65,
                "Expected 'trashapp://map' route text to render to the right of the link icon (got width \(routeTextWidthPt)pt)"
            )

            let iconToRouteGapPt = CGFloat(clusters[1].start - linkIconCluster.end - 1) / scale
            XCTAssertGreaterThan(
                iconToRouteGapPt,
                1.5,
                "Expected a distinct gap between the link icon and route text, got \(iconToRouteGapPt)pt"
            )
            XCTAssertLessThan(
                iconToRouteGapPt,
                12,
                "Expected compact spacing between link icon and start route text, got \(iconToRouteGapPt)pt"
            )
        }
    }
    @MainActor
    func testInvocationOptionSetAndDictionaryLiteralEquivalenceAndActions() {
        // 1. Backwards-compatibility OptionSet syntax [.shake, .screenshot]
        let legacyOptionSet: HollerKitInvocation = [.shake, .screenshot]
        XCTAssertEqual(legacyOptionSet.rawValue, 3)
        XCTAssertTrue(legacyOptionSet.contains(.shake))
        XCTAssertTrue(legacyOptionSet.contains(.screenshot))
        XCTAssertEqual(legacyOptionSet.action(for: .shake), .bugReport)
        XCTAssertEqual(legacyOptionSet.action(for: .screenshot), .bugReport)

        // 2. Factory methods combining gestures
        let combined: HollerKitInvocation = [
            .shake,
            .stroke(.leftToCenter, action: .bugReport),
            .stroke(.rightToCenter, action: .quests)
        ]
        XCTAssertTrue(combined.contains(.shake))
        XCTAssertEqual(combined.action(for: .stroke(.leftToCenter)), .bugReport)
        XCTAssertEqual(combined.action(for: .stroke(.rightToCenter)), .quests)

        // 3. Dictionary literal syntax mapping triggers to destination actions
        let mapped: HollerKitInvocation = [
            .shake: .bugReport,
            .stroke(.leftToCenter): .bugReport,
            .stroke(.rightToCenter): .quests,
            .twoFingerLongPress: .quests,
            .threeFingerLongPress: .bugReport,
            .threeFingerDoubleTap: .quests,
            .floatingButton: .bugReport
        ]
        XCTAssertEqual(mapped.action(for: .shake), .bugReport)
        XCTAssertEqual(mapped.action(for: .stroke(.leftToCenter)), .bugReport)
        XCTAssertEqual(mapped.action(for: .stroke(.rightToCenter)), .quests)
        XCTAssertEqual(mapped.action(for: .twoFingerLongPress), .quests)
        XCTAssertEqual(mapped.action(for: .threeFingerLongPress), .bugReport)
        XCTAssertEqual(mapped.action(for: .threeFingerDoubleTap), .quests)
        XCTAssertEqual(mapped.action(for: .floatingButton), .bugReport)
        XCTAssertTrue(mapped.contains(.stroke(.leftToCenter)))
        XCTAssertTrue(mapped.contains(.twoFingerLongPress))

        // 4. Subscript manipulation
        var mutable = mapped
        mutable[.stroke(.leftToCenter)] = nil
        XCTAssertFalse(mutable.contains(.stroke(.leftToCenter)))
        mutable[.stroke(.leftToCenter)] = .quests
        XCTAssertEqual(mutable.action(for: .stroke(.leftToCenter)), .quests)
    }

    @MainActor
    func testRuntimeInvocationReconfigurationUpdatesPresenterState() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-invocation-reconfig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "token" },
            isEnabled: { true },
            invocation: [.shake],
            outboxDirectoryURL: tempDir
        ))

        XCTAssertTrue(HollerKit.currentInvocation.contains(.shake))
        XCTAssertFalse(HollerKit.currentInvocation.contains(.stroke(.leftToCenter)))
        XCTAssertEqual(HollerKit.presenterState.currentInvocation.actions.keys.contains(.shake), true)

        // Reconfigure at runtime via setInvocation
        HollerKit.setInvocation([
            .stroke(.leftToCenter): .bugReport,
            .stroke(.rightToCenter): .quests
        ])

        XCTAssertEqual(HollerKit.currentInvocation.action(for: .stroke(.leftToCenter)), .bugReport)
        XCTAssertEqual(HollerKit.currentInvocation.action(for: .stroke(.rightToCenter)), .quests)
        XCTAssertEqual(HollerKit.presenterState.currentInvocation.action(for: .stroke(.rightToCenter)), .quests)

        // Dynamic provider re-evaluation
        let flagBox = LockedBox("quests")
        HollerKit.setInvocationProvider {
            if flagBox.withLock({ $0 }) == "quests" {
                return [.stroke(.rightToCenter): .quests]
            } else {
                return [.shake: .bugReport]
            }
        }

        XCTAssertEqual(HollerKit.currentInvocation.action(for: .stroke(.rightToCenter)), .quests)
        flagBox.withLock { $0 = "shake" }
        HollerKit.reconcileEnablement()
        XCTAssertEqual(HollerKit.currentInvocation.action(for: .shake), .bugReport)

        // setInvocation override does not overwrite active invocationProvider
        HollerKit.setInvocation([.screenshot: .bugReport])
        XCTAssertEqual(HollerKit.currentInvocation.action(for: .shake), .bugReport)
        XCTAssertEqual(HollerKit.presenterState.currentInvocation.action(for: .shake), .bugReport)

        // Resetting provider restores the override
        HollerKit.setInvocationProvider(nil)
        XCTAssertEqual(HollerKit.currentInvocation.action(for: .screenshot), .bugReport)
        XCTAssertEqual(HollerKit.presenterState.currentInvocation.action(for: .screenshot), .bugReport)
    }

    @MainActor
    func testReportDraftRecordsInvokingTriggerMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-invocation-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let receivedRequestsBox = LockedBox<[[String: Any]]>([])
        StubURLProtocol.setHandler { request, bodyData in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.path == "/v1/feedback", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                receivedRequestsBox.withLock { $0.append(body) }
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "idempotent": false,
                    "feedback": [
                        "id": (body["id"] as? String) ?? UUID().uuidString.lowercased(),
                        "kind": "report",
                        "build": "1",
                        "submitterId": "tester-1",
                        "createdAt": "2026-11-08T20:00:00Z",
                        "updatedAt": "2026-11-08T20:00:00Z",
                        "comment": body["comment"] as Any
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let session = makeStubSession()
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "token" },
            isEnabled: { true },
            invocation: [
                .shake: .bugReport,
                .stroke(.leftToCenter): .bugReport
            ],
            urlSession: session,
            outboxDirectoryURL: tempDir
        )
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(config)

        // Invoked via leftToCenter stroke
        HollerKit.presentBugReport(trigger: .stroke(.leftToCenter))
        let strokeDraft = HollerKit.currentBugReportDraft
        XCTAssertEqual(strokeDraft.invokingTrigger, "stroke.leftToCenter")

        strokeDraft.autoDismissDelaySeconds = 0
        strokeDraft.comment = "Stroke triggered report"
        await strokeDraft.submit(
            configuration: config,
            breadcrumbs: HollerKit.currentBreadcrumbs,
            outboxStore: HollerKit.currentOutboxStore
        )

        let requests = receivedRequestsBox.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        let metadata = requests.first?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["invocation"] as? String, "stroke.leftToCenter")

        // Invoked via shake
        HollerKit.presentBugReport(trigger: .shake)
        XCTAssertEqual(HollerKit.currentBugReportDraft.invokingTrigger, "shake")

        // Invoked programmatically without trigger argument
        HollerKit.presentBugReport()
        XCTAssertEqual(HollerKit.currentBugReportDraft.invokingTrigger, "manual")

        // Invocations via presentQuests log breadcrumb
        HollerKit.presentQuests(trigger: .stroke(.rightToCenter))
        let snapshot = HollerKit.currentBreadcrumbs.snapshot()
        XCTAssertTrue(snapshot.contains(where: { $0.message.contains("Invoked quests via stroke.rightToCenter") }))
    }

    func testStrokeGestureClassifierDirectionAndEdgeAvoidance() {
        let screen = CGRect(x: 0, y: 0, width: 393, height: 852)

        // 1. Valid left-to-center stroke (e.g. from x=45, y=320 to x=200, y=330)
        let leftStrokePoints = [
            CGPoint(x: 45, y: 320),
            CGPoint(x: 95, y: 324),
            CGPoint(x: 145, y: 328),
            CGPoint(x: 200, y: 330)
        ]
        let leftResult = StrokeGestureClassifier.classify(
            points: leftStrokePoints,
            bounds: screen,
            allowedDirections: [.leftToCenter, .rightToCenter]
        )
        XCTAssertEqual(leftResult, .leftToCenter)

        // 2. Interactive pop edge avoidance: stroke starting directly on the edge (x < 24pt) is rejected
        let edgeInteractivePopPoints = [
            CGPoint(x: 12, y: 320),
            CGPoint(x: 80, y: 325),
            CGPoint(x: 160, y: 330)
        ]
        let edgeResult = StrokeGestureClassifier.classify(
            points: edgeInteractivePopPoints,
            bounds: screen,
            allowedDirections: [.leftToCenter]
        )
        XCTAssertNil(edgeResult, "Stroke starting within minEdgeInset must be rejected to preserve UINavigationController interactive pop")

        // 3. Valid right-to-center stroke (from x=350, y=340 to x=190, y=335)
        let rightStrokePoints = [
            CGPoint(x: 350, y: 340),
            CGPoint(x: 290, y: 338),
            CGPoint(x: 230, y: 336),
            CGPoint(x: 190, y: 335)
        ]
        let rightResult = StrokeGestureClassifier.classify(
            points: rightStrokePoints,
            bounds: screen,
            allowedDirections: [.leftToCenter, .rightToCenter]
        )
        XCTAssertEqual(rightResult, .rightToCenter)

        // 4. Right edge avoidance: stroke starting directly on right screen edge is rejected
        let rightEdgePoints = [
            CGPoint(x: 382, y: 340),
            CGPoint(x: 280, y: 338),
            CGPoint(x: 190, y: 335)
        ]
        let rightEdgeResult = StrokeGestureClassifier.classify(
            points: rightEdgePoints,
            bounds: screen,
            allowedDirections: [.rightToCenter]
        )
        XCTAssertNil(rightEdgeResult, "Stroke starting within right screen edge inset must be rejected")

        // 5. Vertical scroll non-interference: vertical swipe down a scroll view is rejected
        let verticalScrollPoints = [
            CGPoint(x: 80, y: 220),
            CGPoint(x: 82, y: 300),
            CGPoint(x: 84, y: 400),
            CGPoint(x: 85, y: 510)
        ]
        let verticalResult = StrokeGestureClassifier.classify(
            points: verticalScrollPoints,
            bounds: screen,
            allowedDirections: [.leftToCenter, .rightToCenter]
        )
        XCTAssertNil(verticalResult, "Vertical scroll motion must not trigger stroke gestures")

        // 6. Diagonal map pan rejection: steep angle (>35 deg) is rejected
        let diagonalPanPoints = [
            CGPoint(x: 50, y: 200),
            CGPoint(x: 100, y: 300),
            CGPoint(x: 150, y: 410)
        ]
        let diagonalResult = StrokeGestureClassifier.classify(
            points: diagonalPanPoints,
            bounds: screen,
            allowedDirections: [.leftToCenter, .rightToCenter]
        )
        XCTAssertNil(diagonalResult, "Diagonal map panning must not trigger stroke gestures")

        // 7. Wandering path / scribble rejection (wander ratio > 1.35)
        let wanderingPoints = [
            CGPoint(x: 50, y: 300),
            CGPoint(x: 80, y: 360),
            CGPoint(x: 110, y: 240),
            CGPoint(x: 150, y: 350),
            CGPoint(x: 180, y: 305)
        ]
        let wanderingResult = StrokeGestureClassifier.classify(
            points: wanderingPoints,
            bounds: screen,
            allowedDirections: [.leftToCenter]
        )
        XCTAssertNil(wanderingResult, "Wandering / scribbling gestures must be rejected")

        // 8. Short nudge (< 70pt minDistance) is rejected
        let shortNudgePoints = [
            CGPoint(x: 50, y: 300),
            CGPoint(x: 75, y: 305)
        ]
        let shortResult = StrokeGestureClassifier.classify(
            points: shortNudgePoints,
            bounds: screen,
            allowedDirections: [.leftToCenter]
        )
        XCTAssertNil(shortResult, "Short touch movement below minDistance must be rejected")

        // 9. Margin avoidance at top (status bar / dynamic island) and bottom (home bar)
        let topBarPoints = [
            CGPoint(x: 50, y: 35),
            CGPoint(x: 150, y: 38),
            CGPoint(x: 200, y: 40)
        ]
        let topResult = StrokeGestureClassifier.classify(
            points: topBarPoints,
            bounds: screen,
            allowedDirections: [.leftToCenter]
        )
        XCTAssertNil(topResult, "Stroke starting within top margin must be rejected")
    }
    #endif

    func testQuestLatestRunFormattingAndFirstCommentLine() {
        let run = QuestLatestRun(
            id: "fb-1",
            result: .fail,
            build: "42",
            createdAt: "2026-11-08T10:00:00Z",
            comment: "\n  Coupon spinner hangs forever  \nSecond line details",
            triageStatus: "triaged"
        )
        XCTAssertEqual(run.firstCommentLine, "Coupon spinner hangs forever")

        let referenceDate = ISO8601DateFormatter().date(from: "2026-11-10T10:00:00Z")!
        let summary = run.formattedSummary(relativeTo: referenceDate)
        XCTAssertTrue(summary.hasPrefix("Failed · build 42 · "), "Unexpected summary: \(summary)")
        XCTAssertTrue(summary.hasSuffix(" · Triaged"), "Expected Triaged suffix in summary: \(summary)")
    }

    @MainActor
    func testQuestBoardOrdersUntriedBeforeUnsureAndFailedAndClearsOnTriage() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-board-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let questFail = QuestDefinition(
            id: "q-fail",
            title: "Failed quest",
            area: "checkout",
            steps: ["Step 1"],
            expect: ["Expect 1"]
        )
        let questUnsure = QuestDefinition(
            id: "q-unsure",
            title: "Unsure quest",
            area: "checkout",
            steps: ["Step 1"],
            expect: ["Expect 1"]
        )
        let questUntried = QuestDefinition(
            id: "q-untried",
            title: "Untried quest",
            area: "checkout",
            steps: ["Step 1"],
            expect: ["Expect 1"]
        )

        let state = HollerKitQuestState()
        state.configure(
            questsConfiguration: .definitions([questFail, questUnsure, questUntried]),
            build: "100",
            cacheDirectoryURL: tempDir
        )

        // Initially all 3 are untried (.pending)
        XCTAssertEqual(state.untriedQuests.map(\.id), ["q-fail", "q-unsure", "q-untried"])
        XCTAssertTrue(state.needsAttentionQuests.isEmpty)

        // Record a local fail on q-fail and unsure on q-unsure
        let failDate = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!
        state.recordLocalResult(
            .fail,
            forQuestId: "q-fail",
            build: "100",
            comment: "Button did not respond",
            endedAt: failDate
        )
        state.recordLocalResult(
            .unsure,
            forQuestId: "q-unsure",
            build: "100",
            comment: "Animation looked slightly off",
            endedAt: failDate
        )

        // Untried quest must come first in pendingQuests, followed by unsure, then failed
        XCTAssertEqual(state.untriedQuests.map(\.id), ["q-untried"])
        XCTAssertEqual(state.needsAttentionQuests.map(\.id), ["q-unsure", "q-fail"])
        XCTAssertEqual(state.pendingQuests.map(\.id), ["q-untried", "q-unsure", "q-fail"])

        let unsureItem = state.quests.first(where: { $0.id == "q-unsure" })
        XCTAssertEqual(unsureItem?.status, .unsure)
        XCTAssertEqual(unsureItem?.latestRun?.result, .unsure)
        XCTAssertEqual(unsureItem?.latestRun?.firstCommentLine, "Animation looked slightly off")

        // Sync with server where q-fail was triaged 'resolved' -> returns to untried (.pending)
        let session = makeStubSession()
        StubURLProtocol.setHandler { request, _ in
            let url = request.url!
            let json = """
            {
              "ok": true,
              "build": "100",
              "pendingCount": 2,
              "quests": [
                {
                  "id": "q-fail",
                  "version": 1,
                  "contentHash": "\(questFail.contentHash)",
                  "questStatus": "active",
                  "boardStatus": "pending",
                  "title": "Failed quest",
                  "area": "checkout",
                  "setup": [],
                  "steps": ["Step 1"],
                  "expect": ["Expect 1"],
                  "needs": [],
                  "record": "optional",
                  "counts": { "pass": 0, "fail": 1, "unsure": 0, "abandoned": 0 },
                  "latestRun": {
                    "id": "run-fail-1",
                    "result": "fail",
                    "build": "100",
                    "createdAt": "2026-11-09T12:00:00Z",
                    "comment": "Button did not respond",
                    "triageStatus": "resolved"
                  }
                },
                {
                  "id": "q-unsure",
                  "version": 1,
                  "contentHash": "\(questUnsure.contentHash)",
                  "questStatus": "active",
                  "boardStatus": "unsure",
                  "title": "Unsure quest",
                  "area": "checkout",
                  "setup": [],
                  "steps": ["Step 1"],
                  "expect": ["Expect 1"],
                  "needs": [],
                  "record": "optional",
                  "counts": { "pass": 0, "fail": 0, "unsure": 1, "abandoned": 0 },
                  "latestRun": {
                    "id": "run-unsure-1",
                    "result": "unsure",
                    "build": "100",
                    "createdAt": "2026-11-09T12:00:00Z",
                    "comment": "Animation looked slightly off",
                    "triageStatus": "new"
                  }
                },
                {
                  "id": "q-untried",
                  "version": 1,
                  "contentHash": "\(questUntried.contentHash)",
                  "questStatus": "active",
                  "boardStatus": "pending",
                  "title": "Untried quest",
                  "area": "checkout",
                  "setup": [],
                  "steps": ["Step 1"],
                  "expect": ["Expect 1"],
                  "needs": [],
                  "record": "optional",
                  "counts": { "pass": 0, "fail": 0, "unsure": 0, "abandoned": 0 },
                  "latestRun": null
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

        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            metadata: { ["appBuild": "100", "appVersion": "1.0.0"] },
            quests: .definitions([questFail, questUnsure, questUntried]),
            urlSession: session,
            outboxDirectoryURL: tempDir.appendingPathComponent("Outbox", isDirectory: true)
        )
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(config)
        await state.refresh(using: config)

        XCTAssertEqual(state.untriedQuests.map(\.id), ["q-fail", "q-untried"])
        XCTAssertEqual(state.needsAttentionQuests.map(\.id), ["q-unsure"])
        let clearedItem = state.quests.first(where: { $0.id == "q-fail" })
        XCTAssertEqual(clearedItem?.status, .pending)
        XCTAssertEqual(clearedItem?.latestRun?.triageStatus, "resolved")

        // A newer queued local result must not be wiped out by an older triage-cleared server latestRun
        let newerLocalDate = ISO8601DateFormatter().date(from: "2026-11-09T13:30:00Z")!
        state.recordLocalResult(
            .fail,
            forQuestId: "q-fail",
            build: "100",
            comment: "New regression after fix",
            endedAt: newerLocalDate
        )
        await state.refresh(using: config)
        let afterNewerLocal = state.quests.first(where: { $0.id == "q-fail" })
        XCTAssertEqual(afterNewerLocal?.status, .failed)
        XCTAssertEqual(afterNewerLocal?.latestRun?.firstCommentLine, "New regression after fix")
    }

    /// Verifies that `QuestOverlayView` renders visible green checkmarks, teal `sparkles` guidance icons,
    /// and dark neutral unchecked circles/setup icons when hosted in a transparent overlay window.
    @MainActor
    func testQuestOverlayCheckmarksAndGuidanceIconsMaintainContrastInTransparentWindow() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HollerKitTests-OverlayContrast-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let definition = QuestDefinition(
            id: "checkout-promo-math",
            title: "Apply promo RUN2026 and verify total",
            area: "checkout",
            setup: ["Ensure cart has Run Club Pro ($79.00)"],
            steps: [
                "Inspect Subtotal ($79.00) and Promo RUN2026 (-$12.00)",
                "Verify Tax ($7.43) and Total calculation",
                "Tap Pay button"
            ],
            expect: [
                "Total equals $74.43 (currently shows $91.42 bug in mock)"
            ]
        )
        let item = QuestBoardItem(
            id: definition.id,
            version: 1,
            definition: definition,
            status: .pending
        )
        HollerKit.configure(
            HollerKitConfiguration(
                server: URL(string: "https://api.hollerkit.test")!,
                auth: { "tester-jwt" },
                isEnabled: { true },
                inputMode: .textAndAudio,
                outboxDirectoryURL: tempDir.appendingPathComponent("Outbox", isDirectory: true)
            )
        )
        let state = HollerKitQuestState()
        state.startQuest(item, startedAt: Date().addingTimeInterval(-8))
        defer {
            state.reset()
            QuestOverlayWindowManager.shared.hide()
        }
        state.setOverlayExpanded(true)
        state.toggleStep(at: 0)

        let size = CGSize(width: 393, height: 600)
        var measuredCardFrame: CGRect = .zero
        let rootView = ZStack(alignment: .bottom) {
            Color.clear.ignoresSafeArea()
            QuestOverlayView(
                questState: state,
                viewportSize: size,
                onFrameChange: { frame in
                    measuredCardFrame = frame
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .environment(\.colorScheme, .light)

        let controller = UIHostingController(rootView: rootView)
        controller.view.backgroundColor = .clear
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .clear
        window.isOpaque = false
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        controller.view.layoutIfNeeded()

        let scale: CGFloat = 2.0
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        let bpp = 4
        let bpr = pixelWidth * bpp
        var rawBytes = [UInt8](repeating: 255, count: pixelHeight * bpr)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: &rawBytes,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        controller.view.layer.render(in: context)
        window.isHidden = true

        XCTAssertFalse(measuredCardFrame.isEmpty, "QuestOverlayView must report a non-empty card frame")
        let minX = max(0, Int((measuredCardFrame.minX + 12) * scale))
        let maxX = min(pixelWidth, Int((measuredCardFrame.minX + 32) * scale))
        let minY = max(0, Int((measuredCardFrame.minY + 54) * scale))
        let maxY = min(pixelHeight, Int((measuredCardFrame.maxY - 42) * scale))

        var greenCheckmarkPixels = 0
        var tealSparklesPixels = 0
        var darkLeadingIconPixels = 0

        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bpr + x * bpp
                let r = Int(rawBytes[offset])
                let g = Int(rawBytes[offset + 1])
                let b = Int(rawBytes[offset + 2])
                let maxChannel = max(r, max(g, b))
                let minChannel = min(r, min(g, b))

                if g > r + 40 && g > b + 20 {
                    greenCheckmarkPixels += 1
                } else if b > r + 40 && g > r + 25 {
                    tealSparklesPixels += 1
                } else if maxChannel < 180 && (maxChannel - minChannel) <= 20 {
                    darkLeadingIconPixels += 1
                }
            }
        }

        XCTAssertGreaterThan(
            greenCheckmarkPixels,
            20,
            "Checked step checkmark.circle.fill must render visible green pixels"
        )
        XCTAssertGreaterThan(
            tealSparklesPixels,
            10,
            "Expect guidance sparkles icon must render visible teal pixels"
        )
        XCTAssertGreaterThan(
            darkLeadingIconPixels,
            25,
            "Unchecked step circles and setup gearshape icon must maintain dark contrast against light overlay card"
        )
    }

    @MainActor
    func testSpanInvalidatedOnEnablementToggle() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-span-invalid-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        final class FlagBox: @unchecked Sendable {
            var value: Bool = true
        }
        let flag = FlagBox()
        let config = HollerKitConfiguration(
            server: URL(string: "https://example.com")!,
            auth: { "token" },
            isEnabled: { flag.value },
            captureBreadcrumbs: true,
            maxBreadcrumbs: 50,
            urlSession: URLSession(configuration: .ephemeral),
            outboxDirectoryURL: tempDir
        )
        HollerKit.configure(config)

        let span = HollerKit.begin("operation.to.cancel")

        // Disable HollerKit
        flag.value = false
        HollerKit.reconcileEnablement()

        // Re-enable HollerKit
        flag.value = true
        HollerKit.reconcileEnablement()

        // Now end the old span
        span.end()

        // The old span must NOT be recorded because it was started in an earlier enablement generation
        let recorded = HollerKit.currentBreadcrumbs.snapshot().filter { $0.message == "operation.to.cancel" }
        XCTAssertTrue(recorded.isEmpty, "Span started before disablement must not be recorded after re-enablement")
    }

    func testFeedbackEventPayloadReservedKeyFallback() throws {
        let json = #"{"message":"test","durationMs":"not-a-number","fields":"not-a-dict","startOffsetSeconds":"zero"}"#
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(FeedbackEventPayload.self, from: data)

        XCTAssertNil(payload.durationMs)
        XCTAssertNil(payload.fields)
        XCTAssertNil(payload.startOffsetSeconds)
        XCTAssertEqual(payload.strings["durationMs"], "not-a-number")
        XCTAssertEqual(payload.strings["fields"], "not-a-dict")
        XCTAssertEqual(payload.strings["startOffsetSeconds"], "zero")
    }

    func testFeedbackEventPayloadClampingAndNonFiniteValidation() throws {
        var payload = FeedbackEventPayload()
        payload["message"] = "test message"
        payload.durationMs = Double.nan
        payload.startOffsetSeconds = Double.infinity
        payload.fields = [
            "valid": .double(42.0),
            "invalid": .double(Double.nan)
        ]

        payload.clampToSize(maxBytes: 2048)

        XCTAssertNil(payload.durationMs)
        XCTAssertNil(payload.startOffsetSeconds)
        XCTAssertEqual(payload.fields?["valid"], .double(42.0))
        XCTAssertNil(payload.fields?["invalid"])

        let encoded = try JSONEncoder().encode(payload)
        XCTAssertLessThanOrEqual(encoded.count, 2048)

        // Huge payload that exceeds 2048 bytes even with many keys
        var hugePayload = FeedbackEventPayload()
        hugePayload["message"] = String(repeating: "M", count: 3000)
        var fields: [String: HollerKitFieldValue] = [:]
        for i in 0..<100 {
            fields["key_\(i)"] = .string(String(repeating: "F", count: 50))
        }
        hugePayload.fields = fields

        hugePayload.clampToSize(maxBytes: 2048)
        let hugeEncoded = try JSONEncoder().encode(hugePayload)
        XCTAssertLessThanOrEqual(hugeEncoded.count, 2048)

        let input = FeedbackEventInput(offsetSeconds: Double.nan, kind: "breadcrumb", payload: payload)
        XCTAssertEqual(input.offsetSeconds, 0)
    }

    func testFeedbackSubmissionRequestBudgetClamping() throws {
        var events: [FeedbackEventInput] = []
        for i in 0..<100 {
            var p = FeedbackEventPayload()
            p["message"] = "event_\(i)_\(String(repeating: "x", count: 1500))"
            events.append(FeedbackEventInput(offsetSeconds: Double(i), kind: "breadcrumb", payload: p))
        }

        var request = FeedbackSubmissionRequest(
            id: UUID(),
            kind: "report",
            build: "100",
            events: events
        )

        request.clampToBudget(maxBytes: 20 * 1024)
        let data = try JSONEncoder().encode(request)
        XCTAssertLessThanOrEqual(data.count, 20 * 1024)
        XCTAssertEqual(request.events.first?.payload["message"], "breadcrumbs.truncated")
    }

    @MainActor
    func testObservableStateTrackingForQuestStateAndBugReportDraft() throws {
        let questState = HollerKitQuestState()
        let questChangeFired = LockedBox(false)
        withObservationTracking {
            _ = questState.quests
            _ = questState.activeQuest
        } onChange: {
            questChangeFired.withLock { $0 = true }
        }

        let definition = QuestDefinition(
            id: "obs.quest",
            title: "Observable Quest",
            area: "ui",
            steps: ["Verify Observation tracking"],
            expect: ["onChange fires"]
        )
        questState.configure(
            questsConfiguration: .definitions([definition]),
            build: "100"
        )
        XCTAssertTrue(questChangeFired.withLock { $0 })

        let draft = BugReportDraft()
        let draftChangeFired = LockedBox(false)
        withObservationTracking {
            _ = draft.comment
            _ = draft.isSubmitting
        } onChange: {
            draftChangeFired.withLock { $0 = true }
        }

        draft.comment = "Updated via @Observable"
        XCTAssertTrue(draftChangeFired.withLock { $0 })

        let speechChangeFired = LockedBox(false)
        withObservationTracking {
            _ = draft.speechCapture.partialTranscript
        } onChange: {
            speechChangeFired.withLock { $0 = true }
        }

        draft.speechCapture.isCapturing = true
        draft.speechCapture.capture.updatePartialTranscriptForTesting("Live reactive transcript")
        XCTAssertTrue(speechChangeFired.withLock { $0 })
        XCTAssertEqual(draft.speechCapture.partialTranscript, "Live reactive transcript")
    }

    @MainActor
    func testAudioOnlyInputModeEnablesVoiceCaptureAndRespectsMaxDuration() throws {
        var config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            inputMode: .audioOnly(presentation: .fullScreen, maxDuration: 18),
            audio: .off
        )

        switch config.effectiveAudioConfiguration {
        case .transcriptOnly(let maxDuration, let requireOnDevice):
            XCTAssertEqual(maxDuration, 18)
            XCTAssertFalse(requireOnDevice)
        default:
            XCTFail("Expected .audioOnly input mode to resolve effectiveAudioConfiguration to .transcriptOnly")
        }

        var onDeviceConfig = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            inputMode: .audioOnly(presentation: .fullScreen, maxDuration: 42),
            audio: .transcriptOnly(maxDuration: 10, requireOnDeviceTranscription: true)
        )
        switch onDeviceConfig.effectiveAudioConfiguration {
        case .transcriptOnly(let maxDuration, let requireOnDevice):
            XCTAssertEqual(maxDuration, 42)
            XCTAssertTrue(requireOnDevice)
        default:
            XCTFail("Expected .audioOnly input mode to preserve requireOnDeviceTranscription and override maxDuration")
        }

        onDeviceConfig.inputMode = HollerKitInputMode.textOnly
        if case .off = onDeviceConfig.effectiveAudioConfiguration {
            // expected
        } else {
            XCTFail("Expected .textOnly to resolve effectiveAudioConfiguration to .off")
        }

        config.inputMode = HollerKitInputMode.audioOnly(presentation: .fullScreen, maxDuration: 18)
        let sheet = BugReportSheet(configuration: config, breadcrumbs: BreadcrumbStore())
        _ = sheet.body
        let pillView = AudioOnlyCaptureView()
        _ = pillView.body
    }

    @MainActor
    func testBugReportToQuestBoardSheetPresentationCoordination() throws {
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true }
        )
        HollerKit.configure(config)

        HollerKit.present()
        XCTAssertTrue(HollerKit.presenterState.isPresented)
        XCTAssertFalse(HollerKit.presenterState.isQuestsPresented)

        HollerKit.requestQuestsAfterBugReportDismiss()
        XCTAssertTrue(HollerKit.presenterState.presentQuestsAfterBugReportDismiss)
        XCTAssertFalse(HollerKit.presenterState.isQuestsPresented)

        HollerKit.presenterState.isPresented = false
        HollerKit.clearPresentationAttachments()
        XCTAssertFalse(HollerKit.presenterState.isPresented)
        XCTAssertFalse(HollerKit.presenterState.presentQuestsAfterBugReportDismiss)
        XCTAssertTrue(HollerKit.presenterState.isQuestsPresented)
    }

    @MainActor
    func testQuestSubmissionIncludesTranscriptMetadataAndRollbacksRejectedOutboxRun() async throws {
        let outboxDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HollerKitQuestRollbackTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outboxDirectory) }

        let questDef = QuestDefinition(
            id: "checkout.quest",
            title: "Checkout Quest",
            area: "checkout",
            steps: ["Complete checkout"],
            expect: ["Order succeeds"]
        )

        let capturedSubmissions = LockedBox<[FeedbackSubmissionRequest]>([])
        let shouldRejectFlush = LockedBox(false)
        let rejectedFeedbackIdsBox = LockedBox<Set<String>>([])
        let shouldAcceptNonRejectedFeedback = LockedBox(false)

        StubURLProtocol.setHandler { request, bodyData in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST", url.path == "/v1/feedback" {
                var decodedRequest: FeedbackSubmissionRequest?
                if let bodyData,
                   let decoded = try? JSONDecoder().decode(FeedbackSubmissionRequest.self, from: bodyData) {
                    decodedRequest = decoded
                    capturedSubmissions.withLock { $0.append(decoded) }
                }
                let feedbackId = decodedRequest?.id.lowercased() ?? ""
                let isSpecificallyRejected = rejectedFeedbackIdsBox.withLock { $0.contains(feedbackId) }
                if shouldRejectFlush.withLock({ $0 }) || isSpecificallyRejected {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data(#"{"error":{"code":"invalid_quest","message":"Unprocessable quest run"}}"#.utf8))
                }
                if shouldAcceptNonRejectedFeedback.withLock({ $0 }) {
                    let responseJSON = """
                    {
                      "ok": true,
                      "idempotent": false,
                      "feedback": {
                        "id": "\(feedbackId)",
                        "kind": "\(decodedRequest?.kind ?? "quest_run")",
                        "build": "200",
                        "submitterId": "tester-1",
                        "createdAt": "2026-11-11T12:00:00Z",
                        "updatedAt": "2026-11-11T12:00:00Z"
                      }
                    }
                    """
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data(responseJSON.utf8))
                }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":{"code":"unavailable","message":"Offline queue test"}}"#.utf8))
            }
            let manifestJSON = """
            {
              "ok": true,
              "build": "200",
              "pendingCount": 1,
              "quests": [
                {
                  "id": "checkout.quest",
                  "version": 1,
                  "contentHash": "\(questDef.contentHash)",
                  "questStatus": "active",
                  "boardStatus": "pending",
                  "title": "Checkout Quest",
                  "area": "checkout",
                  "setup": [],
                  "steps": ["Complete checkout"],
                  "expect": ["Order succeeds"],
                  "needs": [],
                  "record": "optional"
                }
              ]
            }
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(manifestJSON.utf8))
        }
        defer { StubURLProtocol.setHandler(nil) }

        let session = makeStubSession()
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            metadata: { ["build": "200"] },
            quests: .definitions([questDef]),
            urlSession: session,
            outboxDirectoryURL: outboxDirectory.appendingPathComponent("Outbox", isDirectory: true)
        )
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(config)
        XCTAssertEqual(HollerKit.quests.quests.first?.status, .pending)

        let questItem = try XCTUnwrap(HollerKit.quests.quests.first)
        HollerKit.quests.startQuest(questItem)
        let transcript = HollerKitTranscript(
            text: "Voice note for quest run",
            locale: "en-US",
            engine: .appleOnDevice,
            confidence: 0.91,
            durationSeconds: 5.5
        )

        let queuedOutcome = try await HollerKit.quests.submitActiveQuest(
            result: .fail,
            comment: "Voice note for quest run",
            transcript: transcript
        )
        if case .queued(let queuedId, _, _) = queuedOutcome {
            XCTAssertNotNil(queuedId)
        } else {
            XCTFail("Expected quest run to be queued offline on HTTP 503")
        }

        // Optimistic board status is updated to .failed while queued in the outbox
        XCTAssertEqual(HollerKit.quests.quests.first?.status, .failed)
        XCTAssertEqual(HollerKit.quests.quests.first?.latestRun?.result, .fail)

        let firstSubmission = try XCTUnwrap(capturedSubmissions.withLock { $0.first })
        XCTAssertEqual(firstSubmission.metadata["transcriptLocale"], "en-US")
        XCTAssertEqual(firstSubmission.metadata["transcriptEngine"], "apple-on-device")
        XCTAssertEqual(firstSubmission.metadata["transcriptConfidence"], "0.91")
        XCTAssertEqual(firstSubmission.metadata["transcriptDurationSeconds"], "5.5")

        // Now flush the outbox when the server permanently rejects the queued item with HTTP 422
        shouldRejectFlush.withLock { $0 = true }
        let flushResult = await HollerKit.flushOutbox()
        XCTAssertEqual(flushResult.rejectedErrors.count, 1)

        // Optimistic status override should be rolled back to .pending
        XCTAssertEqual(HollerKit.quests.quests.first?.status, .pending)
        XCTAssertNil(HollerKit.quests.quests.first?.latestRun)

        // Verify multi-run ordering and rollback across reconfiguration:
        // Queue Run A (.fail) then Run B (.pass) while offline (503).
        shouldRejectFlush.withLock { $0 = false }
        let baseDate = Date(timeIntervalSince1970: 1_700_100_000)

        let itemForRunA = try XCTUnwrap(HollerKit.quests.quests.first)
        HollerKit.quests.startQuest(itemForRunA, startedAt: baseDate)
        let outcomeA = try await HollerKit.quests.submitActiveQuest(
            result: .fail,
            comment: "Run A failed",
            transcript: nil,
            endedAt: baseDate.addingTimeInterval(5)
        )
        guard case .queued(let runAId, _, _) = outcomeA else {
            XCTFail("Expected Run A to be queued")
            return
        }

        let itemForRunB = try XCTUnwrap(HollerKit.quests.quests.first)
        HollerKit.quests.startQuest(itemForRunB, startedAt: baseDate.addingTimeInterval(10))
        let outcomeB = try await HollerKit.quests.submitActiveQuest(
            result: .pass,
            comment: "Run B passed",
            transcript: nil,
            endedAt: baseDate.addingTimeInterval(15)
        )
        guard case .queued(let runBId, _, _) = outcomeB else {
            XCTFail("Expected Run B to be queued")
            return
        }

        XCTAssertEqual(HollerKit.quests.quests.first?.status, .passed)
        XCTAssertEqual(HollerKit.quests.quests.first?.counts.fail, 1)
        XCTAssertEqual(HollerKit.quests.quests.first?.counts.pass, 1)
        XCTAssertEqual(HollerKit.quests.quests.first?.latestRun?.result, .pass)
        XCTAssertEqual(HollerKit.quests.completedQuests.count, 1)

        // Re-configure HollerKit to simulate app restart while both runs are still queued on disk
        HollerKit.configure(config)
        XCTAssertEqual(HollerKit.quests.quests.first?.status, .passed)
        XCTAssertEqual(HollerKit.quests.quests.first?.counts.fail, 1)
        XCTAssertEqual(HollerKit.quests.quests.first?.counts.pass, 1)

        // Reject Run A with 422 while accepting Run B (and a report submission triggering OutboxStore.submit)
        rejectedFeedbackIdsBox.withLock { $0 = [runAId.uuidString.lowercased()] }
        shouldAcceptNonRejectedFeedback.withLock { $0 = true }

        let reportOutcome = try await HollerKit.submitReport(
            HollerKitReportPayload(
                inputMode: .textOnly,
                comment: "Trigger outbox flush via submitReport",
                metadata: ["build": "200"]
            )
        )
        if case .sent = reportOutcome {
            // expected
        } else {
            XCTFail("Expected report submission to succeed and flush outbox")
        }

        // Run A was rejected, but Run B succeeded -> board preserves Run B's .passed status, counts, and latestRun!
        XCTAssertEqual(HollerKit.quests.quests.first?.status, .passed)
        XCTAssertEqual(HollerKit.quests.quests.first?.counts.fail, 0)
        XCTAssertEqual(HollerKit.quests.quests.first?.counts.pass, 1)
        XCTAssertEqual(HollerKit.quests.quests.first?.latestRun?.id, runBId.uuidString.lowercased())
        XCTAssertEqual(HollerKit.quests.quests.first?.latestRun?.comment, "Run B passed")
        XCTAssertEqual(HollerKit.quests.completedQuests.count, 1)

        // And if Run B is also rolled back, the confirmed baseline (.pending) is restored and Completed is empty
        HollerKit.quests.rollbackRejectedFeedbackIds([runBId])
        XCTAssertEqual(HollerKit.quests.quests.first?.status, .pending)
        XCTAssertEqual(HollerKit.quests.quests.first?.counts.pass, 0)
        XCTAssertNil(HollerKit.quests.quests.first?.latestRun)
        XCTAssertTrue(HollerKit.quests.completedQuests.isEmpty)
    }

    func testReportPayloadAndRequestClampEventsToMax200WithTruncatedMarker() throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let breadcrumbs: [HollerKitBreadcrumb] = (0..<250).map { index in
            HollerKitBreadcrumb(
                timestamp: baseDate.addingTimeInterval(Double(index)),
                category: "nav",
                message: "crumb-\(index)",
                offsetSeconds: Double(index)
            )
        }

        let payload = HollerKitReportPayload(
            inputMode: .textAndAudio,
            comment: "Too many breadcrumbs",
            metadata: ["build": "100"],
            breadcrumbs: breadcrumbs,
            truncatedBreadcrumbsCount: 10
        )

        let (request, _) = payload.toFeedbackSubmission()
        XCTAssertEqual(request.events.count, HollerKitReportPayload.maxFeedbackEvents)
        XCTAssertEqual(request.events.count, 200)
        XCTAssertEqual(request.events.first?.payload["message"], "breadcrumbs.truncated")
        // 10 previously truncated + 51 newly dropped (250 -> 199 retained) = 61 total dropped
        XCTAssertEqual(request.events.first?.payload.fields?["dropped"], .int(61))
        XCTAssertEqual(request.events.first?.payload["dropped"], "61")
        XCTAssertEqual(request.events[1].payload["message"], "crumb-51")
        XCTAssertEqual(request.events.last?.payload["message"], "crumb-249")

        // Also verify FeedbackSubmissionRequest.clampToBudget trims >200 events while preserving mark events
        var rawEvents: [FeedbackEventInput] = (0..<210).map { idx in
            FeedbackEventInput(
                offsetSeconds: Double(idx),
                kind: "breadcrumb",
                payload: ["message": "raw-\(idx)"]
            )
        }
        rawEvents.insert(
            FeedbackEventInput(
                offsetSeconds: 5.0,
                kind: "mark",
                payload: ["label": "Mark 1", "markId": "m1"]
            ),
            at: 5
        )
        var directRequest = FeedbackSubmissionRequest(
            kind: "quest_run",
            build: "100",
            events: rawEvents
        )
        directRequest.clampToBudget()
        XCTAssertEqual(directRequest.events.count, 200)
        XCTAssertEqual(directRequest.events.first?.payload["message"], "breadcrumbs.truncated")
        XCTAssertTrue(directRequest.events.contains(where: { $0.kind == "mark" && $0.payload["markId"] == "m1" }))
        XCTAssertEqual(directRequest.events.last?.payload["message"], "raw-209")
    }

    func testPendingQuestItemPreservesBoardStatusAndLatestRun() throws {
        let json = """
        {
          "ok": true,
          "build": "200",
          "pendingCount": 1,
          "quests": [
            {
              "id": "sync.quest",
              "version": 1,
              "contentHash": "abc123",
              "title": "Sync Quest",
              "area": "sync",
              "setup": [],
              "steps": ["Step 1"],
              "expect": ["Synced"],
              "needs": [],
              "record": "optional",
              "status": "active",
              "boardStatus": "failed",
              "createdAt": "2026-11-11T12:00:00Z",
              "counts": {
                "pass": 0,
                "fail": 1,
                "unsure": 0,
                "abandoned": 0
              },
              "latestRun": {
                "id": "11111111-2222-3333-4444-555555555555",
                "build": "200",
                "result": "fail",
                "submitterId": "tester-1",
                "comment": "Broken button",
                "createdAt": "2026-11-11T12:00:00Z"
              }
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(PendingQuestsResponse.self, from: Data(json.utf8))
        let store = QuestStore()
        let items = store.boardItems(from: response.quests, definitions: [], isSimulator: true)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.status, .failed)
        XCTAssertEqual(items.first?.latestRun?.result, .fail)
        XCTAssertEqual(items.first?.latestRun?.comment, "Broken button")
    }

    #if canImport(UIKit)
    /// Generates a real valid QuickTime `.mov` video file on disk using `AVAssetWriter` for unit testing duration inspection, thumbnails, and transcoding.
    @MainActor
    private func makeSampleVideoFile(
        at url: URL,
        durationSeconds: Double = 2.0,
        frameSize: CGSize = CGSize(width: 64, height: 64)
    ) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(frameSize.width),
                kCVPixelBufferHeightKey as String: Int(frameSize.height)
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 10
        let totalFrames = max(2, Int((durationSeconds * Double(fps)).rounded()))
        for frameIndex in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(frameSize.width),
                Int(frameSize.height),
                kCVPixelFormatType_32ARGB,
                nil,
                &pixelBuffer
            )
            XCTAssertEqual(status, kCVReturnSuccess)
            if let buffer = pixelBuffer {
                CVPixelBufferLockBaseAddress(buffer, [])
                if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                    let totalBytes = bytesPerRow * Int(frameSize.height)
                    memset(baseAddress, Int32(40 + (frameIndex * 17) % 180), totalBytes)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
                _ = adaptor.append(buffer, withPresentationTime: presentationTime)
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        XCTAssertEqual(writer.status, .completed, "AVAssetWriter failed: \(String(describing: writer.error))")
    }

    @MainActor
    func testBugReportDraftPasteBranchingWithItemProviders() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-paste-branching-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleMovieURL = tempDir.appendingPathComponent("clip.mov", isDirectory: false)
        try await makeSampleVideoFile(at: sampleMovieURL, durationSeconds: 2.0)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let sampleImage = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let samplePNGData = try XCTUnwrap(sampleImage.pngData())

        func makeImageProvider() -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                visibility: .all
            ) { completion in
                completion(samplePNGData, nil)
                return nil
            }
            return provider
        }

        func makeMovieProvider(fileURL: URL = sampleMovieURL) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.quickTimeMovie.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                completion(fileURL, false, nil)
                return nil
            }
            return provider
        }

        // 1. Image-only item provider
        let draft1 = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft1", isDirectory: true))
        let imageOnlyCount = await draft1.pasteImagesFromClipboard(itemProviders: [makeImageProvider()])
        XCTAssertEqual(imageOnlyCount, 1)
        XCTAssertEqual(draft1.images.count, 1)
        XCTAssertFalse(draft1.images[0].isVideo)
        XCTAssertEqual(draft1.images[0].kind, .image)
        XCTAssertEqual(draft1.images[0].title, "Pasted Image 1")
        XCTAssertNil(draft1.attachmentStatusMessage)

        // 2. Movie-only item provider
        let draft2 = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft2", isDirectory: true))
        let movieOnlyCount = await draft2.pasteImagesFromClipboard(itemProviders: [makeMovieProvider()])
        XCTAssertEqual(movieOnlyCount, 1)
        XCTAssertEqual(draft2.images.count, 1)
        XCTAssertTrue(draft2.images[0].isVideo)
        XCTAssertEqual(draft2.images[0].kind, .video)
        XCTAssertEqual(draft2.images[0].title, "Pasted Video 1")
        XCTAssertEqual(draft2.images[0].formattedDuration, "0:02")
        let copiedVideoURL = try XCTUnwrap(draft2.images[0].videoFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedVideoURL.path))
        XCTAssertTrue(copiedVideoURL.path.hasPrefix(draft2.tempDirectoryURL.path))
        XCTAssertNil(draft2.attachmentStatusMessage)

        // 3. Mixed clipboard (multiple movies + images, respecting both 3-video cap and 12-attachment cap)
        let draft3 = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft3", isDirectory: true))
        let mixedProviders: [NSItemProvider] = [
            makeMovieProvider(),
            makeImageProvider(),
            makeMovieProvider(),
            makeMovieProvider(),
            makeMovieProvider(), // 4th video -> rejected by 3-video cap while images still attach
            makeImageProvider()
        ]
        let mixedCount = await draft3.pasteImagesFromClipboard(itemProviders: mixedProviders)
        XCTAssertEqual(mixedCount, 5)
        XCTAssertEqual(draft3.videoCount, 3)
        XCTAssertEqual(draft3.images.filter { !$0.isVideo }.count, 2)
        XCTAssertEqual(draft3.attachmentStatusMessage, "You can attach up to 3 videos per report.")

        // 4. URL + thumbnail fallback (source puts a link + thumbnail image instead of a video file)
        let draft4 = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft4", isDirectory: true))
        let urlWithThumbnailProvider = NSItemProvider()
        urlWithThumbnailProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.url.identifier,
            visibility: .all
        ) { completion in
            completion(Data("https://example.com/screen-recording.mp4".utf8), nil)
            return nil
        }
        urlWithThumbnailProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(samplePNGData, nil)
            return nil
        }
        let fallbackCount = await draft4.pasteImagesFromClipboard(itemProviders: [urlWithThumbnailProvider])
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(draft4.images.count, 1)
        XCTAssertFalse(draft4.images[0].isVideo)
        XCTAssertEqual(
            draft4.attachmentStatusMessage,
            "Clipboard only contained a link or thumbnail; attached image preview instead of video."
        )

        // URL-only item provider without any image
        let draftURLOnly = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft-url-only", isDirectory: true))
        let urlOnlyProvider = NSItemProvider()
        urlOnlyProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.url.identifier,
            visibility: .all
        ) { completion in
            completion(Data("https://example.com/video-only-link".utf8), nil)
            return nil
        }
        let urlOnlyCount = await draftURLOnly.pasteImagesFromClipboard(itemProviders: [urlOnlyProvider])
        XCTAssertEqual(urlOnlyCount, 0)
        XCTAssertTrue(draftURLOnly.images.isEmpty)
        XCTAssertEqual(
            draftURLOnly.attachmentStatusMessage,
            "Clipboard only contained a link, not a video file or image."
        )

        // 5. Unsupported item provider (plain text only)
        let draft5 = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft5", isDirectory: true))
        let textProvider = NSItemProvider()
        textProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("just plain text".utf8), nil)
            return nil
        }
        let unsupportedCount = await draft5.pasteImagesFromClipboard(itemProviders: [textProvider])
        XCTAssertEqual(unsupportedCount, 0)
        XCTAssertTrue(draft5.images.isEmpty)
        XCTAssertEqual(draft5.attachmentStatusMessage, "No image or video found on the clipboard.")
    }

    @MainActor
    func testBugReportDraftVideoCapDurationLimitAndTranscoding() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-video-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            HollerKit.quests.serverMaxVideoBytes = nil
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Verify server manifest response exposes limits.maxVideoBytes and updates HollerKit.quests.serverMaxVideoBytes
        StubURLProtocol.setHandler { request, _ in
            let url = try XCTUnwrap(request.url)
            let json: [String: Any] = [
                "ok": true,
                "build": "100",
                "pendingCount": 0,
                "quests": [],
                "limits": [
                    "maxImageBytes": 10_485_760,
                    "maxAudioBytes": 15_728_640,
                    "maxVideoBytes": 100_000,
                    "maxImages": 12
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = APIClient(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "token" },
            session: makeStubSession()
        )
        let manifestResponse = try await client.syncBuildManifest(build: "100", appVersion: "1.0", quests: [])
        XCTAssertEqual(manifestResponse.limits?.maxVideoBytes, 100_000)
        XCTAssertNil(HollerKit.quests.serverMaxVideoBytes, "APIClient should not mutate HollerKit.quests directly")
        let questStore = QuestStore(cacheDirectoryURL: tempDir.appendingPathComponent("quest-cache", isDirectory: true))
        _ = try await questStore.syncWithServer(
            definitions: [],
            build: "100",
            appVersion: "1.0",
            client: client,
            persistToCache: false
        )
        XCTAssertEqual(HollerKit.quests.serverMaxVideoBytes, 100_000)

        let draft = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft", isDirectory: true))
        XCTAssertEqual(draft.effectiveMaxVideoBytes, 100_000)

        // Create real video file on disk and verify real AVAssetImageGenerator + AVAssetExportSession
        let realVideoURL = tempDir.appendingPathComponent("real.mov", isDirectory: false)
        try await makeSampleVideoFile(at: realVideoURL, durationSeconds: 1.5)
        let inspectedDuration = try await BugReportAttachment.inspectVideoDurationSeconds(at: realVideoURL)
        XCTAssertGreaterThan(inspectedDuration, 0.5)
        XCTAssertLessThanOrEqual(inspectedDuration, 3.0)
        let generatedThumbnail = await BugReportAttachment.generateVideoThumbnail(for: realVideoURL)
        XCTAssertNotNil(generatedThumbnail)
        let realTranscodedURL = try await BugReportAttachment.transcodeVideo(
            sourceURL: realVideoURL,
            outputDirectoryURL: tempDir.appendingPathComponent("real-transcode", isDirectory: true),
            maxBytes: 5_000_000
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: realTranscodedURL.path))

        // 1. Clip over 60 seconds is rejected BEFORE transcoding (even when file size exceeds maxVideoBytes)
        let oversizedLongURL = tempDir.appendingPathComponent("long-oversized.mov", isDirectory: false)
        let oversizedPayload = Data(repeating: 0xAB, count: 250_000) // > 100_000 server limit
        try oversizedPayload.write(to: oversizedLongURL)

        draft.videoDurationInspector = { _ in 60.5 }
        let addedLong = await draft.addVideo(from: oversizedLongURL)
        XCTAssertFalse(addedLong)
        XCTAssertEqual(draft.attachmentStatusMessage, "Videos must be 1 minute or shorter.")
        XCTAssertEqual(draft.transcodeInvocationCount, 0, "Duration must be checked before transcoding")
        XCTAssertTrue(draft.images.isEmpty)

        // 2. Under-size clip (<= 60s and <= effectiveMaxVideoBytes) is uploaded untouched without transcoding
        let underSizeURL = tempDir.appendingPathComponent("undersize.mov", isDirectory: false)
        let underSizePayload = Data((0..<40_000).map { UInt8($0 & 0xFF) })
        try underSizePayload.write(to: underSizeURL)

        draft.videoDurationInspector = { _ in 12.0 }
        let addedUnderSize = await draft.addVideo(from: underSizeURL, title: "Screen Clip 1")
        XCTAssertTrue(addedUnderSize)
        XCTAssertEqual(draft.transcodeInvocationCount, 0, "Under-size video must not be transcoded")
        XCTAssertEqual(draft.images.count, 1)
        let storedUnderSizeURL = try XCTUnwrap(draft.images[0].videoFileURL)
        let storedUnderSizeBytes = try Data(contentsOf: storedUnderSizeURL)
        XCTAssertEqual(storedUnderSizeBytes, underSizePayload, "Under-size video bytes must remain untouched")
        XCTAssertEqual(draft.images[0].formattedDuration, "0:12")

        // 3. Over-size clip (<= 60s and > effectiveMaxVideoBytes) is transcoded
        let overSizeURL = tempDir.appendingPathComponent("oversize.mov", isDirectory: false)
        try oversizedPayload.write(to: overSizeURL)
        let compressedBytes = Data(repeating: 0xCD, count: 45_000)

        draft.videoDurationInspector = { _ in 45.0 }
        draft.videoTranscoder = { _, outputDir, maxBytes in
            XCTAssertEqual(maxBytes, 100_000)
            let outURL = outputDir.appendingPathComponent("compressed-\(UUID().uuidString).mp4", isDirectory: false)
            try compressedBytes.write(to: outURL)
            return outURL
        }
        let addedOverSize = await draft.addVideo(from: overSizeURL, title: "Screen Clip 2")
        XCTAssertTrue(addedOverSize)
        XCTAssertEqual(draft.transcodeInvocationCount, 1, "Over-size video must be transcoded")
        XCTAssertEqual(draft.images.count, 2)
        let storedTranscodedURL = try XCTUnwrap(draft.images[1].videoFileURL)
        XCTAssertEqual(try Data(contentsOf: storedTranscodedURL), compressedBytes)
        XCTAssertEqual(draft.images[1].videoMimeType, "video/mp4")
        XCTAssertEqual(draft.images[1].formattedDuration, "0:45")

        // 4. Over-size clip that is still over maxVideoBytes after transcoding is rejected
        draft.videoTranscoder = { _, outputDir, _ in
            let outURL = outputDir.appendingPathComponent("still-too-big-\(UUID().uuidString).mp4", isDirectory: false)
            try Data(repeating: 0xEF, count: 150_000).write(to: outURL)
            return outURL
        }
        let addedStillTooBig = await draft.addVideo(from: overSizeURL)
        XCTAssertFalse(addedStillTooBig)
        XCTAssertEqual(draft.transcodeInvocationCount, 2)
        XCTAssertEqual(draft.attachmentStatusMessage, "Video exceeds the maximum size limit even after compression.")
        XCTAssertEqual(draft.images.count, 2)

        // 5. 3-video cap within the 12-attachment total and pickerFilter switching
        #if canImport(PhotosUI)
        XCTAssertEqual(draft.pickerFilter, .any(of: [.images, .videos]))
        #endif
        XCTAssertTrue(draft.canAddMoreVideos)
        XCTAssertEqual(draft.remainingVideoSlots, 1)

        let thirdVideoAdded = await draft.addVideo(from: underSizeURL, title: "Screen Clip 3")
        XCTAssertTrue(thirdVideoAdded)
        XCTAssertEqual(draft.videoCount, 3)
        XCTAssertFalse(draft.canAddMoreVideos)
        XCTAssertEqual(draft.remainingVideoSlots, 0)
        #if canImport(PhotosUI)
        XCTAssertEqual(draft.pickerFilter, .images, "Picker must limit selection to images once 3 videos are attached")
        #endif

        // 4th video is rejected with the 3-video cap message
        let fourthVideoAdded = await draft.addVideo(from: underSizeURL, title: "Screen Clip 4")
        XCTAssertFalse(fourthVideoAdded)
        XCTAssertEqual(draft.attachmentStatusMessage, "You can attach up to 3 videos per report.")
        XCTAssertEqual(draft.videoCount, 3)

        // Images can still be added up to 12 total attachments (3 videos + 9 images = 12)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let sampleImage = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        for idx in 1...9 {
            XCTAssertTrue(draft.addImage(sampleImage, title: "Photo \(idx)"))
        }
        XCTAssertEqual(draft.images.count, 12)
        XCTAssertFalse(draft.canAddMoreImages)
        XCTAssertFalse(draft.addImage(sampleImage))
        XCTAssertEqual(draft.attachmentStatusMessage, "You can attach up to 12 attachments per report.")

        // Removing a video deletes its temp file and re-enables video selection once under 12 total
        draft.removeImage(id: draft.images.last!.id) // remove 1 image -> 11 total
        let removedVideo = draft.images[0]
        let removedVideoFileURL = try XCTUnwrap(removedVideo.videoFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: removedVideoFileURL.path))
        draft.removeImage(id: removedVideo.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedVideoFileURL.path))
        XCTAssertEqual(draft.videoCount, 2)
        XCTAssertTrue(draft.canAddMoreVideos)
        #if canImport(PhotosUI)
        XCTAssertEqual(draft.pickerFilter, .any(of: [.images, .videos]))
        #endif
    }

    @MainActor
    func testBugReportVideoSkipsAnnotationStreamsUploadWithProgressAndCleansUp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-video-upload-\(UUID().uuidString)", isDirectory: true)
        let outboxRoot = tempDir.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleMovieURL = tempDir.appendingPathComponent("clip.mov", isDirectory: false)
        try await makeSampleVideoFile(at: sampleMovieURL, durationSeconds: 2.0)
        let expectedVideoBytes = try Data(contentsOf: sampleMovieURL)

        let draft = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft", isDirectory: true))
        draft.autoDismissDelaySeconds = 0
        draft.comment = "Janky scroll animation clip"
        let added = await draft.addVideo(from: sampleMovieURL, title: "Jank Clip")
        XCTAssertTrue(added)
        let videoAttachment = try XCTUnwrap(draft.images.first)
        XCTAssertTrue(videoAttachment.isVideo)
        XCTAssertEqual(videoAttachment.formattedDuration, "0:02")

        // Verify videos skip annotation
        draft.selectedImage = videoAttachment
        XCTAssertNil(draft.selectedImage, "Video attachments must skip annotation")
        let originalThumbnail = videoAttachment.image
        let redOverlay = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        draft.replaceImage(id: videoAttachment.id, with: redOverlay)
        XCTAssertEqual(draft.images[0].image.size, originalThumbnail.size, "replaceImage must ignore video attachments")

        // Verify streaming upload, outbox persistence while offline, progress stages, and temp file cleanup
        let shouldFailUploadBox = LockedBox(true)
        let uploadedVideoBodyBox = LockedBox<Data?>(nil)
        let uploadGrantRequestsBox = LockedBox<[[String: Any]]>([])
        let submittedFeedbackBox = LockedBox<[String: Any]?>(nil)

        StubURLProtocol.setHandler { request, bodyData in
            let url = try XCTUnwrap(request.url)
            if url.path == "/v1/uploads", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                uploadGrantRequestsBox.withLock { $0.append(body) }
                if shouldFailUploadBox.withLock({ $0 }) {
                    let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
                    return (response, Data("{\"ok\":false}".utf8))
                }
                let grantJSON: [String: Any] = [
                    "ok": true,
                    "key": "fb-video/0.mov",
                    "url": "https://storage.hollerkit.test/upload/0.mov",
                    "expiresAt": "2099-01-01T00:00:00Z"
                ]
                let data = try JSONSerialization.data(withJSONObject: grantJSON)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            if url.host == "storage.hollerkit.test", request.httpMethod == "PUT" {
                uploadedVideoBodyBox.withLock { $0 = bodyData }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            if url.path == "/v1/feedback", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                submittedFeedbackBox.withLock { $0 = body }
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "idempotent": false,
                    "feedback": [
                        "id": (body["id"] as? String) ?? UUID().uuidString.lowercased(),
                        "kind": "report",
                        "build": "1",
                        "submitterId": "tester-1",
                        "createdAt": "2026-11-12T10:00:00Z",
                        "updatedAt": "2026-11-12T10:00:00Z"
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            throw URLError(.unsupportedURL)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let session = makeStubSession()
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "token" },
            isEnabled: { true },
            urlSession: session,
            outboxDirectoryURL: outboxRoot
        )
        let outboxStore = OutboxStore(rootDirectoryURL: outboxRoot)
        let draftVideoTempURL = try XCTUnwrap(videoAttachment.videoFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftVideoTempURL.path))

        // First submission while offline (503) -> queues in outbox and cleans up draft temp files
        await draft.submit(
            configuration: config,
            breadcrumbs: BreadcrumbStore(),
            outboxStore: outboxStore
        )
        guard case .queued(let queuedId, _, _) = draft.submissionOutcome else {
            XCTFail("Expected report to be queued when upload grant returns 503")
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: draftVideoTempURL.path),
            "Draft temporary video file should be cleaned up after enqueueing to outbox"
        )
        let queuedOutboxVideoURL = outboxRoot
            .appendingPathComponent(queuedId.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("0.mov", isDirectory: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: queuedOutboxVideoURL.path),
            "Queued video file must be persisted in the outbox directory until flushed"
        )

        // Now bring server online and submit a second report with a video to observe progress stages and flush both
        shouldFailUploadBox.withLock { $0 = false }
        let draft2 = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("draft2", isDirectory: true))
        draft2.autoDismissDelaySeconds = 0
        _ = await draft2.addVideo(from: sampleMovieURL, title: "Second Clip")
        let (request2, attachments2) = HollerKitReportPayload(
            inputMode: .textAndAudio,
            comment: "Online video submission",
            images: draft2.imageAttachments()
        ).toFeedbackSubmission(build: "1")

        let observedStagesBox = LockedBox<[SubmissionProgressStage]>([])
        let client = APIClient(configuration: config)
        let outcome2 = try await outboxStore.submit(
            request: request2,
            attachments: attachments2,
            using: client,
            onProgress: { stage in
                observedStagesBox.withLock { $0.append(stage) }
            }
        )
        if case .sent = outcome2 {
            // expected
        } else {
            XCTFail("Expected online video submission to succeed")
        }

        let observedStages = observedStagesBox.withLock { $0 }
        XCTAssertTrue(observedStages.contains(.uploadingAttachments(count: 1)))
        XCTAssertTrue(observedStages.contains(.uploadingAttachment(index: 1, total: 1, progress: 0.0)))
        XCTAssertTrue(observedStages.contains(.uploadingAttachment(index: 1, total: 1, progress: 1.0)))
        XCTAssertTrue(observedStages.contains(.sending))
        XCTAssertEqual(
            SubmissionProgressStage.uploadingAttachment(index: 1, total: 2, progress: 0.5).progress ?? -1,
            0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SubmissionProgressStage.uploadingAttachment(index: 1, total: 1, progress: 0.5).title,
            "Uploading attachment (50%)…"
        )

        // Verify streamed video bytes match original file and outbox directories were cleaned up after flush
        XCTAssertEqual(uploadedVideoBodyBox.withLock { $0 }, expectedVideoBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: queuedOutboxVideoURL.path),
            "Outbox video file must be cleaned up after successful flush"
        )
        let grantRequests = uploadGrantRequestsBox.withLock { $0 }
        XCTAssertTrue(grantRequests.contains(where: {
            ($0["kind"] as? String) == "video"
                && ($0["mimeType"] as? String) == "video/quicktime"
                && ($0["size"] as? Int) == expectedVideoBytes.count
        }))
        let submittedAttachments = (submittedFeedbackBox.withLock { $0 }?["attachments"] as? [[String: Any]]) ?? []
        XCTAssertEqual(submittedAttachments.first?["kind"] as? String, "video")
        XCTAssertEqual(submittedAttachments.first?["mimeType"] as? String, "video/quicktime")
        XCTAssertEqual(submittedAttachments.first?["size"] as? Int, expectedVideoBytes.count)

        // Verify caller-owned video files passed via HollerKitAttachment(fileURL:) are preserved on removeImage and cleanupTempFiles
        let callerVideoURL = tempDir.appendingPathComponent("caller-owned.mov", isDirectory: false)
        try expectedVideoBytes.write(to: callerVideoURL)
        let callerAttachment = HollerKitAttachment(
            filename: "Host Recording.mov",
            mimeType: "video/quicktime",
            fileURL: callerVideoURL,
            kind: "video",
            durationSeconds: 2.0
        )
        let callerDraft = BugReportDraft(tempDirectoryURL: tempDir.appendingPathComponent("caller-draft", isDirectory: true))
        callerDraft.loadInitialImagesIfNeeded(
            configuration: config,
            invocationAttachments: [callerAttachment]
        )
        XCTAssertEqual(callerDraft.images.count, 1)
        let callerItemId = try XCTUnwrap(callerDraft.images.first?.id)
        callerDraft.removeImage(id: callerItemId)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: callerVideoURL.path),
            "removeImage must not delete caller-owned video files outside tempDirectoryURL"
        )
        callerDraft.resetForAnotherReport(
            configuration: config,
            invocationAttachments: [callerAttachment]
        )
        callerDraft.cleanupTempFiles()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: callerVideoURL.path),
            "cleanupTempFiles must not delete caller-owned video files outside tempDirectoryURL"
        )

        // Verify OutboxStore.enqueue throws when a supplied attachment fileURL does not exist on disk
        let missingFileURL = tempDir.appendingPathComponent("missing-video.mp4", isDirectory: false)
        do {
            _ = try await outboxStore.enqueue(
                request: FeedbackSubmissionRequest(id: UUID(), kind: "report", build: "1"),
                attachments: [
                    OutboxAttachmentPayload(
                        kind: "video",
                        mimeType: "video/mp4",
                        fileURL: missingFileURL
                    )
                ]
            )
            XCTFail("Expected enqueue to throw when supplied attachment fileURL is missing")
        } catch {
            // Expected error; verify no item was committed to the outbox
            let queuedCount = await outboxStore.pendingCount()
            XCTAssertEqual(queuedCount, 0)
        }
    }
    #endif

    @MainActor
    func testSubmissionProgressStageHumanFriendlyTitlesAcrossFlows() {
        XCTAssertEqual(SubmissionProgressStage.preparing.title, "Preparing feedback…")
        XCTAssertEqual(SubmissionProgressStage.preparing.title(for: .bugReport), "Preparing feedback…")
        XCTAssertEqual(SubmissionProgressStage.preparing.title(for: .questResult), "Preparing feedback…")

        XCTAssertEqual(SubmissionProgressStage.uploadingAttachments(count: 1).title, "Uploading 1 attachment…")
        XCTAssertEqual(SubmissionProgressStage.uploadingAttachments(count: 3).title, "Uploading 3 attachments…")

        XCTAssertEqual(
            SubmissionProgressStage.uploadingAttachment(index: 1, total: 1, progress: 0.42).title,
            "Uploading attachment (42%)…"
        )
        XCTAssertEqual(
            SubmissionProgressStage.uploadingAttachment(index: 2, total: 3, progress: 0.75).title,
            "Uploading attachment 2 of 3 (75%)…"
        )

        XCTAssertEqual(SubmissionProgressStage.sending.title, "Sending your report…")
        XCTAssertEqual(SubmissionProgressStage.sending.title(for: .bugReport), "Sending your report…")
        XCTAssertEqual(SubmissionProgressStage.sending.title(for: .questResult), "Sending your result…")

        let allSampleStages: [SubmissionProgressStage] = [
            .preparing,
            .uploadingAttachments(count: 1),
            .uploadingAttachments(count: 2),
            .uploadingAttachment(index: 1, total: 1, progress: 0.0),
            .uploadingAttachment(index: 1, total: 2, progress: 0.5),
            .sending
        ]
        for stage in allSampleStages {
            XCTAssertFalse(
                stage.title.localizedCaseInsensitiveContains("server"),
                "Progress title '\(stage.title)' must not leak the word 'server'"
            )
            XCTAssertFalse(
                stage.title.contains("..."),
                "Progress title '\(stage.title)' should use the typographic ellipsis '…'"
            )
            for flow in SubmissionFlow.allCases {
                let flowTitle = stage.title(for: flow)
                XCTAssertFalse(
                    flowTitle.localizedCaseInsensitiveContains("server"),
                    "Progress title '\(flowTitle)' for flow \(flow.rawValue) must not leak the word 'server'"
                )
                XCTAssertFalse(
                    flowTitle.contains("..."),
                    "Progress title '\(flowTitle)' for flow \(flow.rawValue) should use the typographic ellipsis '…'"
                )
            }
        }

        let bugDraft = BugReportDraft()
        XCTAssertNil(bugDraft.submissionProgressTitle)
        bugDraft.submissionStage = .sending
        XCTAssertEqual(bugDraft.submissionProgressTitle, "Sending your report…")

        let questDraft = QuestResultDraft()
        XCTAssertNil(questDraft.submissionProgressTitle)
        questDraft.submissionStage = .sending
        XCTAssertEqual(questDraft.submissionProgressTitle, "Sending your result…")

        let bugOverlay = SubmissionFeedbackOverlayView(
            isSubmitting: true,
            stage: .sending,
            flow: .bugReport,
            outcome: nil,
            sentTitle: "Report Sent",
            onDone: {},
            onSendAnother: nil
        )
        XCTAssertEqual(bugOverlay.progressTitle, "Sending your report…")

        let questOverlay = SubmissionFeedbackOverlayView(
            isSubmitting: true,
            stage: .sending,
            flow: .questResult,
            outcome: nil,
            sentTitle: "Quest Submitted",
            onDone: {},
            onSendAnother: nil
        )
        XCTAssertEqual(questOverlay.progressTitle, "Sending your result…")
    }

    #if canImport(UIKit)
    @MainActor
    func testAlwaysVisiblePasteButtonDisabledStateHintAndForegroundRefreshAcrossBothSheets() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-paste-hint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Verify aligned label, accessibility identifiers, and hint copy constants
        XCTAssertEqual(ClipboardPasteAttachmentRow.pasteButtonTitle, "Paste from Clipboard")
        XCTAssertEqual(ClipboardPasteAttachmentRow.pasteButtonSystemImage, "doc.on.clipboard")
        XCTAssertEqual(ClipboardPasteAttachmentRow.pasteButtonAccessibilityIdentifier, "HollerKitPasteImageButton")
        XCTAssertEqual(ClipboardPasteAttachmentRow.hintButtonSystemImage, "info.circle")
        XCTAssertEqual(ClipboardPasteAttachmentRow.hintButtonAccessibilityIdentifier, "HollerKitPasteHintButton")
        XCTAssertEqual(ClipboardPasteAttachmentRow.hintButtonAccessibilityLabel, "Paste from Clipboard Info")
        XCTAssertEqual(ClipboardPasteAttachmentRow.hintTextAccessibilityIdentifier, "HollerKitPasteHintText")
        XCTAssertEqual(
            ClipboardPasteAttachmentRow.hintMessage,
            "Copy a screenshot or screen recording, then paste it here."
        )

        // 2. Verify type-only clipboard availability detection (empty, plain text, image, movie/video, URL)
        XCTAssertFalse(ClipboardAttachmentAvailability.hasAttachableTypeIdentifiers([]))
        XCTAssertFalse(ClipboardAttachmentAvailability.hasAttachableTypeIdentifiers([UTType.plainText.identifier]))
        XCTAssertTrue(ClipboardAttachmentAvailability.hasAttachableTypeIdentifiers([UTType.png.identifier]))
        XCTAssertTrue(ClipboardAttachmentAvailability.hasAttachableTypeIdentifiers([UTType.jpeg.identifier]))
        XCTAssertTrue(ClipboardAttachmentAvailability.hasAttachableTypeIdentifiers([UTType.quickTimeMovie.identifier]))
        XCTAssertTrue(ClipboardAttachmentAvailability.hasAttachableTypeIdentifiers([UTType.mpeg4Movie.identifier]))
        XCTAssertTrue(ClipboardAttachmentAvailability.hasAttachableTypeIdentifiers([UTType.url.identifier]))

        let testPasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: testPasteboard.name) }
        testPasteboard.items = []
        XCTAssertFalse(ClipboardAttachmentAvailability.hasAttachableItem(pasteboard: testPasteboard))

        // 3. Configure an active quest session so both BugReportSheet and QuestResultSheet render their Attachments section
        let questDef = QuestDefinition(
            id: "hollerkit-shake-report",
            title: "Shake to report a bug",
            area: "feedback",
            steps: ["Shake device", "Verify paste button"],
            expect: ["Paste button is visible and disabled when clipboard is empty"]
        )
        let config = HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            quests: .definitions([questDef]),
            urlSession: makeStubSession(),
            outboxDirectoryURL: tempDir.appendingPathComponent("Outbox", isDirectory: true)
        )
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(config)
        let boardItem = QuestBoardItem(
            id: questDef.id,
            version: 2,
            definition: questDef,
            status: .pending
        )
        HollerKit.quests.startQuest(boardItem)
        defer {
            if let active = HollerKit.quests.activeQuest {
                HollerKit.quests.completeSubmittedSession(id: active.id)
            }
        }

        let bugDraft = BugReportDraft(
            configuration: config,
            tempDirectoryURL: tempDir.appendingPathComponent("bug-draft", isDirectory: true)
        )
        bugDraft.pasteboard = testPasteboard
        _ = bugDraft.refreshClipboardImageAvailability()

        let questDraft = QuestResultDraft(
            tempDirectoryURL: tempDir.appendingPathComponent("quest-draft", isDirectory: true)
        )
        questDraft.pasteboard = testPasteboard
        _ = questDraft.refreshClipboardImageAvailability()

        let bugSheet = BugReportSheet(
            configuration: config,
            breadcrumbs: BreadcrumbStore(),
            draft: bugDraft
        )
        let questSheet = QuestResultSheet(
            questState: HollerKit.quests,
            draft: questDraft
        )

        // Host both sheets in UIWindows so SwiftUI .onAppear and NotificationCenter .onReceive subscriptions are active
        let bugHost = UIHostingController(rootView: bugSheet)
        let bugWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bugWindow.rootViewController = bugHost
        bugWindow.makeKeyAndVisible()
        bugHost.view.layoutIfNeeded()

        let questHost = UIHostingController(rootView: questSheet)
        let questWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        questWindow.rootViewController = questHost
        questWindow.makeKeyAndVisible()
        questHost.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        defer {
            bugWindow.isHidden = true
            questWindow.isHidden = true
        }

        // 4. With an empty clipboard, the paste button is visible and disabled in both sheets, while the hint button is enabled
        XCTAssertFalse(bugDraft.hasClipboardImage)
        XCTAssertFalse(questDraft.hasClipboardImage)
        XCTAssertTrue(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertTrue(questSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertFalse(bugSheet.pasteAttachmentRow.isHintButtonDisabled, "Info hint button must remain enabled when clipboard is empty")
        XCTAssertFalse(questSheet.pasteAttachmentRow.isHintButtonDisabled, "Info hint button must remain enabled when clipboard is empty")

        // 5. Copying plain text alone keeps the paste button disabled
        testPasteboard.string = "Just plain text on clipboard"
        NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: testPasteboard)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(bugDraft.hasClipboardImage)
        XCTAssertFalse(questDraft.hasClipboardImage)
        XCTAssertTrue(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertTrue(questSheet.pasteAttachmentRow.isPasteButtonDisabled)

        // 6. Copying an image in another app and returning to foreground enables the paste button in both sheets
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let sampleImage = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        testPasteboard.image = sampleImage
        try await Task.sleep(for: .milliseconds(50))
        bugDraft.hasClipboardImage = false
        questDraft.hasClipboardImage = false
        XCTAssertTrue(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertTrue(questSheet.pasteAttachmentRow.isPasteButtonDisabled)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(bugDraft.hasClipboardImage)
        XCTAssertTrue(questDraft.hasClipboardImage)
        XCTAssertFalse(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertFalse(questSheet.pasteAttachmentRow.isPasteButtonDisabled)

        // Verify disabled state also respects loading, submitting, and maxAttachments cap
        bugDraft.isLoadingAttachments = true
        XCTAssertTrue(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertFalse(bugSheet.pasteAttachmentRow.isHintButtonDisabled)
        bugDraft.isLoadingAttachments = false
        XCTAssertFalse(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)

        bugDraft.isSubmitting = true
        XCTAssertTrue(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertTrue(bugSheet.pasteAttachmentRow.isHintButtonDisabled)
        bugDraft.isSubmitting = false

        // 7. Clear clipboard, verify button disables on didBecomeActiveNotification, then copy a video and verify both sheets enable and can paste the video
        testPasteboard.items = []
        try await Task.sleep(for: .milliseconds(50))
        bugDraft.hasClipboardImage = true
        questDraft.hasClipboardImage = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(bugDraft.hasClipboardImage)
        XCTAssertFalse(questDraft.hasClipboardImage)
        XCTAssertTrue(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertTrue(questSheet.pasteAttachmentRow.isPasteButtonDisabled)

        let sampleMovieURL = tempDir.appendingPathComponent("clipboard-recording.mov", isDirectory: false)
        try await makeSampleVideoFile(at: sampleMovieURL, durationSeconds: 1.5)
        let sampleMovieBytes = try Data(contentsOf: sampleMovieURL)
        testPasteboard.setData(sampleMovieBytes, forPasteboardType: UTType.quickTimeMovie.identifier)
        try await Task.sleep(for: .milliseconds(50))
        bugDraft.hasClipboardImage = false
        questDraft.hasClipboardImage = false

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(bugDraft.hasClipboardImage, "Video on clipboard must enable paste button in BugReportSheet")
        XCTAssertTrue(questDraft.hasClipboardImage, "Video on clipboard must enable paste button in QuestResultSheet")
        XCTAssertFalse(bugSheet.pasteAttachmentRow.isPasteButtonDisabled)
        XCTAssertFalse(questSheet.pasteAttachmentRow.isPasteButtonDisabled)

        // 8. Multi-item pasteboard where the first item is plain text and the second item is movie data
        testPasteboard.items = [
            [UTType.plainText.identifier: "Plain text first item"],
            [UTType.quickTimeMovie.identifier: sampleMovieBytes]
        ]
        try await Task.sleep(for: .milliseconds(50))
        bugDraft.hasClipboardImage = false
        questDraft.hasClipboardImage = false
        XCTAssertTrue(ClipboardAttachmentAvailability.hasAttachableItem(pasteboard: testPasteboard))
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(bugDraft.hasClipboardImage, "Movie in second pasteboard item must enable paste button in BugReportSheet")
        XCTAssertTrue(questDraft.hasClipboardImage, "Movie in second pasteboard item must enable paste button in QuestResultSheet")

        // Verify QuestResultDraft.pasteFromClipboard attaches both video and image providers just like BugReportDraft
        let movieProvider = NSItemProvider()
        movieProvider.registerFileRepresentation(
            forTypeIdentifier: UTType.quickTimeMovie.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(sampleMovieURL, false, nil)
            return nil
        }
        let questPastedVideoCount = await questDraft.pasteFromClipboard(itemProviders: [movieProvider])
        XCTAssertEqual(questPastedVideoCount, 1)
        XCTAssertEqual(questDraft.images.count, 1)
        XCTAssertTrue(questDraft.images[0].isVideo)
        XCTAssertEqual(questDraft.images[0].title, "Pasted Video 1")
    }

    @MainActor
    /// Verifies that submitting a quest result preserves the displayed quest/note/attachments snapshot during
    /// confirmation and sheet dismissal, hides the floating quest overlay while the result sheet is presented,
    /// and cleanly completes the session on both auto-dismiss and manual swipe-dismiss after submit.
    func testQuestResultSheetGracefulDismissalPreservesSnapshotAndCoordinatesOverlayTeardown() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hollerkit-quest-graceful-dismiss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let questDef = QuestDefinition(
            id: "graceful-quest",
            title: "Verify smooth quest dismissal",
            area: "quests",
            steps: ["Step 1", "Step 2"],
            expect: ["Dismisses in a single smooth transition"]
        )

        StubURLProtocol.setHandler { request, bodyData in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.path.hasSuffix("/manifest") {
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "build": "1",
                    "pendingCount": 1,
                    "quests": [
                        [
                            "id": questDef.id,
                            "version": 1,
                            "contentHash": questDef.contentHash,
                            "questStatus": "active",
                            "boardStatus": "pending",
                            "title": questDef.title,
                            "area": questDef.area,
                            "setup": [],
                            "steps": questDef.steps,
                            "expect": questDef.expect,
                            "needs": [],
                            "record": "optional",
                            "counts": ["pass": 0, "fail": 0, "unsure": 0, "abandoned": 0]
                        ]
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["hollerkit-protocol": "1"])!
                return (response, data)
            }
            if url.path == "/v1/uploads", request.httpMethod == "POST" {
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "url": "https://upload.hollerkit.test/put/\(UUID().uuidString)",
                    "key": "uploads/item-\(UUID().uuidString).png",
                    "expiresAt": "2099-01-01T00:00:00Z"
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["hollerkit-protocol": "1"])!
                return (response, data)
            }
            if url.host == "upload.hollerkit.test", request.httpMethod == "PUT" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            if url.path == "/v1/feedback", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
                let id = (body["id"] as? String) ?? UUID().uuidString.lowercased()
                let build = (body["build"] as? String) ?? "1"
                let result = (body["result"] as? String) ?? "pass"
                let questId = (body["questId"] as? String) ?? "graceful-quest"
                let comment = body["comment"] as? String
                let responseJSON: [String: Any] = [
                    "ok": true,
                    "idempotent": false,
                    "feedback": [
                        "id": id,
                        "kind": "quest_run",
                        "questId": questId,
                        "questVersion": 1,
                        "result": result,
                        "build": build,
                        "submitterId": "tester-1",
                        "createdAt": "2026-11-14T18:00:00Z",
                        "updatedAt": "2026-11-14T18:00:00Z",
                        "comment": comment as Any
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["hollerkit-protocol": "1"])!
                return (response, data)
            }
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let session = makeStubSession()
        if let active = HollerKit.quests.activeQuest {
            HollerKit.quests.completeSubmittedSession(id: active.id)
        }
        HollerKit.configure(HollerKitConfiguration(
            server: URL(string: "https://api.hollerkit.test")!,
            auth: { "tester-jwt" },
            isEnabled: { true },
            quests: .definitions([questDef]),
            urlSession: session,
            outboxDirectoryURL: tempDir
        ))
        defer {
            if let active = HollerKit.quests.activeQuest {
                HollerKit.quests.completeSubmittedSession(id: active.id)
            }
            QuestOverlayWindowManager.shared.hide()
        }

        let item = try XCTUnwrap(HollerKit.quests.quests.first)
        HollerKit.quests.startQuest(item)
        let firstSessionId = try XCTUnwrap(HollerKit.quests.activeQuest?.id)
        XCTAssertEqual(HollerKit.quests.activeQuest?.isPresentingResultSheet, false)
        XCTAssertEqual(HollerKit.quests.activeQuest?.isSubmitted, false)

        let windowBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        var reportedOverlayFrame: CGRect = .zero
        let overlayRootView = ZStack(alignment: .bottom) {
            Color.clear.ignoresSafeArea().allowsHitTesting(false)
            QuestOverlayView(
                questState: HollerKit.quests,
                viewportSize: windowBounds.size,
                onFrameChange: { frame in
                    reportedOverlayFrame = frame
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        let hostingController = UIHostingController(rootView: overlayRootView)
        let hostWindow = UIWindow(frame: windowBounds)
        hostWindow.rootViewController = hostingController
        hostWindow.isHidden = false
        hostingController.view.frame = hostWindow.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotEqual(reportedOverlayFrame, .zero, "Active quest overlay must report non-zero interactive frame before presenting result sheet")

        // 1. Present result sheet -> floating overlay hides and reports .zero interactive frame; Back before submit restores it
        HollerKit.quests.presentResultSheet()
        XCTAssertEqual(HollerKit.quests.activeQuest?.isPresentingResultSheet, true)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(reportedOverlayFrame, .zero, "Floating quest overlay must hide and clear interactive frame while result sheet is presented")

        HollerKit.quests.dismissResultSheet()
        XCTAssertEqual(HollerKit.quests.activeQuest?.id, firstSessionId)
        XCTAssertEqual(HollerKit.quests.activeQuest?.isPresentingResultSheet, false)
        XCTAssertEqual(HollerKit.quests.activeQuest?.isSubmitted, false)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotEqual(reportedOverlayFrame, .zero, "Floating quest overlay must reappear if result sheet is dismissed without submitting")

        // 2. Present result sheet on the manager's overlay window, attach an image & note, and submit with auto-dismiss delay
        HollerKit.quests.presentResultSheet()
        HollerKit.quests.toggleStep(at: 0)
        let draft = QuestResultDraft(
            initialResult: .pass,
            initialComment: "Smooth dismissal verified",
            tempDirectoryURL: tempDir.appendingPathComponent("draft-1", isDirectory: true)
        )
        draft.autoDismissDelaySeconds = 0.05
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let testImage = renderer.image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        XCTAssertTrue(draft.addImage(testImage, title: "Confirmation Shot"))

        let sheet = QuestResultSheet(questState: HollerKit.quests, draft: draft)
        XCTAssertEqual(sheet.displayedSession?.id, firstSessionId)
        XCTAssertEqual(sheet.displayedComment, "Smooth dismissal verified")
        XCTAssertEqual(sheet.displayedImages.count, 1)

        XCTAssertNotNil(QuestOverlayWindowManager.shared.currentOverlayWindow?.rootViewController)
        QuestOverlayWindowManager.shared.simulatedModalSheetPresentedForTesting = true
        XCTAssertTrue(QuestOverlayWindowManager.shared.hasMountedOverlayWindow)

        let autoDismissFiredBox = LockedBox<Bool>(false)
        await draft.submit(
            questState: HollerKit.quests,
            clearActiveSessionImmediately: false,
            onAutoDismiss: {
                if let submittedId = draft.submittedSessionId {
                    HollerKit.quests.completeSubmittedSession(id: submittedId)
                }
                autoDismissFiredBox.withLock { $0 = true }
            }
        )

        // Immediately after submit returns (while confirmation badge is displayed):
        // - draft inputs are cleared, but snapshots on draft and QuestResultSheet remain intact
        // - activeQuest is still present with isSubmitted == true
        XCTAssertTrue(draft.comment.isEmpty)
        XCTAssertTrue(draft.images.isEmpty)
        XCTAssertNotNil(draft.submissionOutcome)
        XCTAssertEqual(HollerKit.quests.activeQuest?.id, firstSessionId)
        XCTAssertEqual(HollerKit.quests.activeQuest?.isSubmitted, true)
        XCTAssertEqual(sheet.displayedSession?.id, firstSessionId)
        XCTAssertEqual(sheet.displayedComment, "Smooth dismissal verified")
        XCTAssertEqual(sheet.displayedImages.count, 1)

        // Wait for auto-dismiss callback to trigger session teardown while the sheet VC is still presented
        for _ in 0..<30 {
            if autoDismissFiredBox.withLock({ $0 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(autoDismissFiredBox.withLock { $0 }, "onAutoDismiss must fire after confirmation delay")
        XCTAssertNil(HollerKit.quests.activeQuest, "Active quest session must be cleared when confirmation completes")

        // While the presented sheet is still animating out, the manager window stays mounted awaiting dismissal completion
        QuestOverlayWindowManager.shared.completePendingHideIfNeeded()
        XCTAssertTrue(QuestOverlayWindowManager.shared.hasMountedOverlayWindow)
        XCTAssertTrue(QuestOverlayWindowManager.shared.isAwaitingSheetDismissalTeardown)
        XCTAssertFalse(QuestOverlayWindowManager.shared.isOverlayVisible)

        // Even after activeQuest is nil (while the sheet is animating out), QuestResultSheet preserves its snapshot
        XCTAssertEqual(sheet.displayedSession?.id, firstSessionId)
        XCTAssertEqual(sheet.displayedComment, "Smooth dismissal verified")
        XCTAssertEqual(sheet.displayedImages.count, 1)

        // Finish dismissing the sheet and verify the manager tears down the overlay window via completePendingHideIfNeeded()
        QuestOverlayWindowManager.shared.simulatedModalSheetPresentedForTesting = false
        QuestOverlayWindowManager.shared.completePendingHideIfNeeded()
        XCTAssertFalse(QuestOverlayWindowManager.shared.hasMountedOverlayWindow)
        XCTAssertFalse(QuestOverlayWindowManager.shared.isAwaitingSheetDismissalTeardown)

        // 3. Verify manual swipe-dismiss during post-submit confirmation also coordinates window teardown after sheet dismissal
        HollerKit.quests.startQuest(item)
        let secondSessionId = try XCTUnwrap(HollerKit.quests.activeQuest?.id)
        XCTAssertNotEqual(firstSessionId, secondSessionId)
        HollerKit.quests.presentResultSheet()

        let swipeDraft = QuestResultDraft(
            initialResult: .pass,
            initialComment: "Swiped down during confirmation",
            tempDirectoryURL: tempDir.appendingPathComponent("draft-2", isDirectory: true)
        )
        swipeDraft.autoDismissDelaySeconds = 5.0
        XCTAssertNotNil(QuestOverlayWindowManager.shared.currentOverlayWindow?.rootViewController)
        QuestOverlayWindowManager.shared.simulatedModalSheetPresentedForTesting = true

        await swipeDraft.submit(
            questState: HollerKit.quests,
            clearActiveSessionImmediately: false
        )
        defer { swipeDraft.cancelCapture() }

        XCTAssertEqual(HollerKit.quests.activeQuest?.id, secondSessionId)
        XCTAssertEqual(HollerKit.quests.activeQuest?.isSubmitted, true)

        // Simulate user initiating an interactive swipe-down dismissal after submission:
        // activeQuest clears immediately, but the overlay window stays mounted while the sheet finishes sliding down
        HollerKit.quests.dismissResultSheet()
        XCTAssertNil(
            HollerKit.quests.activeQuest,
            "Swiping down the result sheet after submission must complete and clear the active session"
        )
        XCTAssertTrue(QuestOverlayWindowManager.shared.hasMountedOverlayWindow)
        XCTAssertTrue(QuestOverlayWindowManager.shared.isAwaitingSheetDismissalTeardown)

        // Complete the interactive dismissal and verify the background polling task tears down the overlay window
        QuestOverlayWindowManager.shared.simulatedModalSheetPresentedForTesting = false
        for _ in 0..<20 {
            if !QuestOverlayWindowManager.shared.hasMountedOverlayWindow { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(QuestOverlayWindowManager.shared.hasMountedOverlayWindow)
        XCTAssertFalse(QuestOverlayWindowManager.shared.isAwaitingSheetDismissalTeardown)
    }
    #endif
}
