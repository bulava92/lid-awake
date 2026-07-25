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
        XCTAssertFalse(settings.lockOnLidClose)
        XCTAssertFalse(settings.soundOnLidClose)
        XCTAssertEqual(settings.lidCloseSoundVolume, 50)
        XCTAssertNil(settings.expiresAt)
    }

    func testSupportPaths() {
        XCTAssertEqual(LidAwakeController.settingsFile.lastPathComponent, "settings.json")
        XCTAssertEqual(LidAwakeController.statusFile.lastPathComponent, "status.json")
        XCTAssertEqual(LidAwakeController.eventLogFile.lastPathComponent, "events.log")
        XCTAssertEqual(LidAwakeController.lastLidCloseFile.lastPathComponent, "last-lid-close.txt")
        XCTAssertEqual(L10n.languageFile.lastPathComponent, "language.txt")
    }

    func testStatusCodableRoundTrip() throws {
        let status = LidAwakeStatus(state: .blocked, reason: "Waiting for external power",
            settings: LidAwakeSettings(), power: PowerInfo(onAC: false, batteryPercent: 75),
            thermal: .nominal, remainingSeconds: 600, updatedAt: Date(timeIntervalSince1970: 100))
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(LidAwakeStatus.self, from: data), status)
    }

    func testPermanentModeEnabledWhenSafe() {
        let settings = LidAwakeSettings(requested: true, expiresAt: nil)
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: true, batteryPercent: 80), thermal: .nominal, now: Date())
        XCTAssertEqual(result.0, .enabled)
        XCTAssertNil(result.3)
    }

    func testTemporaryModeRemainingTime() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, expiresAt: now.addingTimeInterval(3600))
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: true, batteryPercent: 80), thermal: .nominal, now: now)
        XCTAssertEqual(result.0, .enabled)
        XCTAssertEqual(result.3, 3600)
    }

    func testDisabledModeNeverBecomesActive() {
        let result = LidAwakeController.evaluate(settings: LidAwakeSettings(requested: false), power: PowerInfo(onAC: true, batteryPercent: 100), thermal: .nominal, now: Date())
        XCTAssertEqual(result.0, .disabled)
    }

    func testBlockedWithoutExternalPower() {
        let settings = LidAwakeSettings(requested: true)
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: false, batteryPercent: 80), thermal: .nominal, now: Date())
        XCTAssertEqual(result.0, .blocked)
    }

    func testBlockedAtBatteryLimit() {
        let settings = LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20)
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: false, batteryPercent: 20), thermal: .nominal, now: Date())
        XCTAssertEqual(result.0, .blocked)
    }

    func testBatteryAboveLimitIsAllowed() {
        let settings = LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20)
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: false, batteryPercent: 21), thermal: .nominal, now: Date())
        XCTAssertEqual(result.0, .enabled)
    }

    func testBlockedByThermalProtection() {
        let settings = LidAwakeSettings(requested: true)
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: true, batteryPercent: 80), thermal: .serious, now: Date())
        XCTAssertEqual(result.0, .blocked)
    }

    func testThermalProtectionCanBeDisabled() {
        let settings = LidAwakeSettings(requested: true, thermalProtection: false)
        let result = LidAwakeController.evaluate(settings: settings, power: PowerInfo(onAC: true, batteryPercent: 80), thermal: .critical, now: Date())
        XCTAssertEqual(result.0, .enabled)
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
        XCTAssertFalse(settings.lockOnLidClose)
        XCTAssertFalse(settings.soundOnLidClose)
        XCTAssertEqual(settings.lidCloseSoundVolume, 50)
    }

    func testNewSettingsRoundTrip() throws {
        let original = LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 30,
            maxDuration: 43_200, thermalProtection: false, notifications: false,
            launchAtLogin: false, lockOnLidClose: true, soundOnLidClose: true,
            lidCloseSoundVolume: 75)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LidAwakeSettings.self, from: data), original)
    }

    func testBuildVersionIsNotEmpty() {
        XCTAssertFalse(LidAwakeController.version.isEmpty)
    }
}
