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
}
