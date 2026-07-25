import XCTest
@testable import LidAwakeCore

final class LidAwakeCoreTests: XCTestCase {
    func testDefaultSafetySettings() {
        let settings = LidAwakeSettings()
        XCTAssertFalse(settings.requested)
        XCTAssertTrue(settings.acOnly)
        XCTAssertEqual(settings.batteryLimit, 20)
        XCTAssertEqual(settings.maxDuration, 28_800)
        XCTAssertTrue(settings.thermalProtection)
        XCTAssertTrue(settings.notifications)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertNil(settings.expiresAt)
    }

    func testSupportPaths() {
        XCTAssertEqual(LidAwakeController.settingsFile.lastPathComponent, "settings.json")
        XCTAssertEqual(LidAwakeController.statusFile.lastPathComponent, "status.json")
        XCTAssertEqual(LidAwakeController.eventLogFile.lastPathComponent, "events.log")
        XCTAssertEqual(L10n.languageFile.lastPathComponent, "language.txt")
    }

    func testStatusCodableRoundTrip() throws {
        let status = LidAwakeStatus(
            state: .blocked,
            reason: "Waiting for external power",
            settings: LidAwakeSettings(),
            power: PowerInfo(onAC: false, batteryPercent: 75),
            thermal: .nominal,
            remainingSeconds: 600,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(LidAwakeStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    func testEnabledWhenAllConditionsAreSafe() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, expiresAt: now.addingTimeInterval(3600))
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: true, batteryPercent: 80), thermal: .nominal, now: now)
        XCTAssertEqual(result.0, .enabled)
        XCTAssertEqual(result.3, 3600)
    }

    func testBlockedWithoutExternalPower() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, expiresAt: now.addingTimeInterval(3600))
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: false, batteryPercent: 80), thermal: .nominal, now: now)
        XCTAssertEqual(result.0, .blocked)
    }

    func testBlockedAtBatteryLimit() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20, expiresAt: now.addingTimeInterval(3600))
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: false, batteryPercent: 20), thermal: .nominal, now: now)
        XCTAssertEqual(result.0, .blocked)
    }

    func testBlockedByThermalProtection() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, expiresAt: now.addingTimeInterval(3600))
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: true, batteryPercent: 80), thermal: .serious, now: now)
        XCTAssertEqual(result.0, .blocked)
    }

    func testExpiryClearsRequest() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, expiresAt: now)
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: true, batteryPercent: 80), thermal: .nominal, now: now)
        XCTAssertEqual(result.0, .disabled)
        XCTAssertFalse(result.2.requested)
        XCTAssertNil(result.2.expiresAt)
    }

    func testOldSettingsRemainDecodable() throws {
        let data = Data("{\"requested\":false,\"acOnly\":true,\"batteryLimit\":20,\"maxDuration\":28800}".utf8)
        let settings = try JSONDecoder().decode(LidAwakeSettings.self, from: data)
        XCTAssertTrue(settings.thermalProtection)
        XCTAssertTrue(settings.notifications)
        XCTAssertTrue(settings.launchAtLogin)
    }
}
