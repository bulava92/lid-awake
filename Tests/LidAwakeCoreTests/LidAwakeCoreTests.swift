import XCTest
@testable import LidAwakeCore

final class LidAwakeCoreTests: XCTestCase {
    func testDefaultSafetySettings() {
        let settings = LidAwakeSettings()
        XCTAssertFalse(settings.requested)
        XCTAssertTrue(settings.acOnly)
        XCTAssertEqual(settings.batteryLimit, 20)
        XCTAssertEqual(settings.maxDuration, 28_800)
        XCTAssertNil(settings.expiresAt)
    }

    func testSupportPaths() {
        XCTAssertEqual(LidAwakeController.settingsFile.lastPathComponent, "settings.json")
        XCTAssertEqual(LidAwakeController.statusFile.lastPathComponent, "status.json")
        XCTAssertEqual(LidAwakeController.supportDirectory.lastPathComponent, "Lid Awake")
    }

    func testStatusCodableRoundTrip() throws {
        let status = LidAwakeStatus(
            state: .blocked,
            reason: "Waiting for external power",
            settings: LidAwakeSettings(),
            power: PowerInfo(onAC: false, batteryPercent: 75),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(LidAwakeStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }
}
