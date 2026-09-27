import XCTest
import SwishCloneCore
@testable import SwishGestures

final class DisabledActionsStorageTests: XCTestCase {

    func testEncodingIsSortedRawValues() {
        XCTAssertEqual(GestureSettings.encode([.quitApp, .close, .leftHalf]), ["close", "leftHalf", "quitApp"])
        XCTAssertEqual(GestureSettings.encode([]), [])
    }

    func testRoundTrip() {
        let actions: Set<GestureAction> = [.minimize, .bottomRightQuarter, .quitApp]
        XCTAssertEqual(GestureSettings.decode(GestureSettings.encode(actions)), actions)
    }

    func testUnknownOrDamagedValuesKeepGesturesEnabled() {
        XCTAssertEqual(GestureSettings.decode(nil), [])
        XCTAssertEqual(GestureSettings.decode("close"), [], "pas une liste")
        XCTAssertEqual(GestureSettings.decode(["close", "doubleTapToHide"]), [.close], "une valeur venue d'une version plus récente est ignorée")
    }
}
