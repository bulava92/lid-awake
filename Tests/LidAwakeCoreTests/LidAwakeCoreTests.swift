import XCTest
@testable import LidAwakeCore

final class LidAwakeCoreTests: XCTestCase {
    func testStateRawValues() {
        XCTAssertEqual(LidAwakeState.enabled.rawValue, "enabled")
        XCTAssertEqual(LidAwakeState.disabled.rawValue, "disabled")
        XCTAssertEqual(LidAwakeState.unknown.rawValue, "unknown")
    }

    func testSupportPaths() {
        XCTAssertEqual(LidAwakeController.timerPIDFile.lastPathComponent, "timer.pid")
        XCTAssertEqual(LidAwakeController.supportDirectory.lastPathComponent, "Lid Awake")
    }
}
