import XCTest
@testable import HollerKit

final class HollerKitTests: XCTestCase {
    func testBreadcrumbStoreKeepsNewestEntries() {
        var store = BreadcrumbStore(capacity: 2)
        store.append(.init(message: "one"))
        store.append(.init(message: "two"))
        store.append(.init(message: "three"))

        XCTAssertEqual(store.snapshot().map(\.message), ["two", "three"])
    }

    func testInputModeWireValues() {
        XCTAssertEqual(HollerKitInputMode.textAndAudio.wireValue, "text-and-audio")
        XCTAssertEqual(HollerKitInputMode.textOnly.wireValue, "text-only")
        XCTAssertEqual(HollerKitInputMode.audioOnly().wireValue, "audio-only")
    }

    func testSignatureIsStable() {
        let signature = MultipartClient.signature(
            body: Data("body".utf8),
            timestamp: "123",
            secret: "secret"
        )

        XCTAssertEqual(signature, "b35166f39a9ce2767342b3153007692e1de6b1c68394e4abb57f806dc23486bd")
    }

    func testMultipartFilenameEscapesHeaderBreakingCharacters() {
        let filename = MultipartBodyBuilder.escapedMultipartFilename("bad\"name\\with\r\nbreak.png")

        XCTAssertEqual(filename, "bad_name_with__break.png")
    }

    func testDefaultAudioModeIsTranscriptOnly() {
        let configuration = HollerKitConfiguration(
            endpoint: URL(string: "https://example.com/bug-report")!,
            appSecret: "secret"
        )

        switch configuration.audio {
        case .transcriptOnly(let maxDuration, let requireOnDeviceTranscription):
            XCTAssertEqual(maxDuration, 60)
            XCTAssertFalse(requireOnDeviceTranscription)
        default:
            XCTFail("Default audio mode should avoid raw audio upload.")
        }
    }

    @MainActor
    func testConfigureStoresInvocationTriggers() {
        HollerKit.configure(
            endpoint: URL(string: "https://example.com/bug-report")!,
            appSecret: "secret",
            invocation: [.shake, .screenshot]
        )

        XCTAssertTrue(HollerKit.currentInvocation.contains(.shake))
        XCTAssertTrue(HollerKit.currentInvocation.contains(.screenshot))
    }

    @MainActor
    func testManualPresentationRequestsSheet() {
        HollerKit.presenterState.isPresented = false
        HollerKit.present()

        XCTAssertTrue(HollerKit.isPresentationRequested)
    }

    @MainActor
    func testPresentationCanCarryScreenshotAttachments() {
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
    }
}
