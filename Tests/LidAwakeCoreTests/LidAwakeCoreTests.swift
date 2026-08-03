import Foundation
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
        XCTAssertFalse(settings.skipLidActionsWithExternalDisplay)
        XCTAssertFalse(settings.lockOnLidClose)
        XCTAssertFalse(settings.soundOnLidClose)
        XCTAssertEqual(settings.lidCloseSoundVolume, 50)
        XCTAssertNil(settings.expiresAt)
        XCTAssertFalse(settings.temporaryModeIsScheduled)
    }

    func testSupportPaths() {
        XCTAssertEqual(LidAwakeController.settingsFile.lastPathComponent, "settings.json")
        XCTAssertEqual(LidAwakeController.statusFile.lastPathComponent, "status.json")
        XCTAssertEqual(LidAwakeController.eventLogFile.lastPathComponent, "events.log")
        XCTAssertEqual(LidAwakeController.lastLidCloseFile.lastPathComponent, "last-lid-close.txt")
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
        XCTAssertEqual(try JSONDecoder().decode(LidAwakeStatus.self, from: data), status)
    }

    func testPermanentModeEnabledWhenSafe() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true, expiresAt: nil),
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .nominal,
            now: Date()
        )
        XCTAssertEqual(result.0, .enabled)
        XCTAssertNil(result.3)
    }

    func testTemporaryModeRemainingTime() {
        let now = Date(timeIntervalSince1970: 100)
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true, expiresAt: now.addingTimeInterval(3600)),
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .nominal,
            now: now
        )
        XCTAssertEqual(result.0, .enabled)
        XCTAssertEqual(result.3, 3600)
    }

    func testDisabledModeNeverBecomesActive() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: false),
            power: PowerInfo(onAC: true, batteryPercent: 100),
            thermal: .nominal,
            now: Date()
        )
        XCTAssertEqual(result.0, .disabled)
    }

    func testBlockedWithoutExternalPower() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true),
            power: PowerInfo(onAC: false, batteryPercent: 80),
            thermal: .nominal,
            now: Date()
        )
        XCTAssertEqual(result.0, .blocked)
    }

    func testBlockedAtBatteryLimit() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20),
            power: PowerInfo(onAC: false, batteryPercent: 20),
            thermal: .nominal,
            now: Date()
        )
        XCTAssertEqual(result.0, .blocked)
    }

    func testBatteryAboveLimitIsAllowed() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20),
            power: PowerInfo(onAC: false, batteryPercent: 21),
            thermal: .nominal,
            now: Date()
        )
        XCTAssertEqual(result.0, .enabled)
    }

    func testBlockedByThermalProtection() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true),
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .serious,
            now: Date()
        )
        XCTAssertEqual(result.0, .blocked)
    }

    func testThermalProtectionCanBeDisabled() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true, thermalProtection: false),
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .critical,
            now: Date()
        )
        XCTAssertEqual(result.0, .enabled)
    }

    func testExpiryClearsRequest() {
        let now = Date(timeIntervalSince1970: 100)
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: true, expiresAt: now),
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .nominal,
            now: now
        )
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
        XCTAssertFalse(settings.skipLidActionsWithExternalDisplay)
        XCTAssertFalse(settings.lockOnLidClose)
        XCTAssertFalse(settings.soundOnLidClose)
        XCTAssertEqual(settings.lidCloseSoundVolume, 50)
        XCTAssertFalse(settings.temporaryModeIsScheduled)
    }

    func testNewSettingsRoundTrip() throws {
        let original = LidAwakeSettings(
            requested: true,
            acOnly: false,
            batteryLimit: 30,
            maxDuration: 43_200,
            thermalProtection: false,
            notifications: false,
            launchAtLogin: false,
            skipLidActionsWithExternalDisplay: true,
            lockOnLidClose: true,
            soundOnLidClose: true,
            lidCloseSoundVolume: 75,
            temporaryModeIsScheduled: true
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LidAwakeSettings.self, from: data), original)
    }

    func testBuildVersionIsNotEmpty() {
        XCTAssertFalse(LidAwakeController.version.isEmpty)
    }

    func testParsesMatchingChecksum() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(
            UpdateVerification.parseSHA256("\(hash)  LidAwake-1.4.3.pkg\n", expectedFilename: "LidAwake-1.4.3.pkg"),
            hash
        )
        XCTAssertNil(UpdateVerification.parseSHA256("\(hash)  other.pkg\n", expectedFilename: "LidAwake-1.4.3.pkg"))
    }

    func testCalculatesKnownSHA256() {
        XCTAssertEqual(
            UpdateVerification.sha256Hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testRecognizesImmediateScreenLock() {
        XCTAssertTrue(LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is immediate"))
        XCTAssertTrue(LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is 0"))
        XCTAssertFalse(LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is 5 seconds"))
    }

    func testWeeklyScheduleAndOvernightRules() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let schedule = AwakeSchedule(enabled: true, fallback: .off, rules: [
            try AwakeScheduleRule(days: Set(1...7), start: AwakeScheduleTime("08:00"), end: AwakeScheduleTime("23:00"), mode: .minutes15),
            try AwakeScheduleRule(days: Set(1...7), start: AwakeScheduleTime("23:00"), end: AwakeScheduleTime("08:00"), mode: .off)
        ])
        try schedule.validate()
        XCTAssertEqual(schedule.activeRule(at: formatter.date(from: "2026-07-20 12:00")!, calendar: calendar)?.mode, .minutes15)
        XCTAssertEqual(schedule.activeRule(at: formatter.date(from: "2026-07-21 07:59")!, calendar: calendar)?.mode, .off)
        XCTAssertEqual(AwakeScheduleMode.minutes15.lidCloseDuration, 900)
        XCTAssertEqual(AwakeScheduleMode.hour1.lidCloseDuration, 3600)
        XCTAssertEqual(schedule.nextBoundary(after: formatter.date(from: "2026-07-20 22:00")!, calendar: calendar), formatter.date(from: "2026-07-20 23:00")!)
    }

    func testScheduleRejectsOverlaps() throws {
        let schedule = AwakeSchedule(enabled: true, rules: [
            try AwakeScheduleRule(days: [1], start: AwakeScheduleTime("08:00"), end: AwakeScheduleTime("12:00"), mode: .on),
            try AwakeScheduleRule(days: [1], start: AwakeScheduleTime("11:00"), end: AwakeScheduleTime("13:00"), mode: .off)
        ])
        XCTAssertThrowsError(try schedule.validate())
    }
}
