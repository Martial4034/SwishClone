import XCTest
@testable import SwishCloneCore

final class SwishCloneCoreTests: XCTestCase {

    func testCoreModuleLoads() throws {
        XCTAssertEqual(SwishCloneCore.version, "0.1.4")
    }
}
