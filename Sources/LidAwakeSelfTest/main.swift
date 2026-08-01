import Foundation
import Darwin
import LidAwakeCore

struct SelfTestFailure: Error {
    let message: String
}

var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    checks += 1
    guard condition() else { throw SelfTestFailure(message: message) }
}

func runSelfTests() throws {
    let defaults = LidAwakeSettings()
    try expect(defaults.requested == false, "default requested state must be false")
    try expect(defaults.acOnly == true, "AC-only must be enabled by default")
    try expect(defaults.batteryLimit == 20, "default battery limit must be 20%")
    try expect(defaults.maxDuration == 28_800, "default maximum duration must be 8 hours")
    try expect(defaults.thermalProtection == true, "thermal protection must be enabled by default")
    try expect(defaults.notifications == true, "notifications must be enabled by default")
    try expect(defaults.launchAtLogin == true, "launch at login must be enabled by default")
    try expect(defaults.skipLidActionsWithExternalDisplay == false, "external-display bypass must be disabled by default")
    try expect(defaults.displaySleepOnLidClose == false, "display sleep must be disabled by default")
    try expect(defaults.lockOnLidClose == false, "screen lock must be disabled by default")
    try expect(defaults.soundOnLidClose == false, "lid-close sound must be disabled by default")
    try expect(defaults.lidCloseSoundVolume == 50, "default sound volume must be 50%")
    try expect(defaults.expiresAt == nil, "default mode must not have an expiry")

    let now = Date(timeIntervalSince1970: 100)
    let safePower = PowerInfo(onAC: true, batteryPercent: 80)

    let permanent = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true, expiresAt: nil),
        power: safePower,
        thermal: .nominal,
        now: now
    )
    try expect(permanent.0 == .enabled, "permanent mode must be enabled under safe conditions")
    try expect(permanent.3 == nil, "permanent mode must not report remaining time")

    let temporary = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true, expiresAt: now.addingTimeInterval(3600)),
        power: safePower,
        thermal: .nominal,
        now: now
    )
    try expect(temporary.0 == .enabled, "temporary mode must be enabled under safe conditions")
    try expect(temporary.3 == 3600, "temporary mode must report remaining time")

    let disabled = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: false),
        power: PowerInfo(onAC: true, batteryPercent: 100),
        thermal: .nominal,
        now: now
    )
    try expect(disabled.0 == .disabled, "disabled mode must stay disabled")

    let withoutPower = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true),
        power: PowerInfo(onAC: false, batteryPercent: 80),
        thermal: .nominal,
        now: now
    )
    try expect(withoutPower.0 == .blocked, "AC-only mode must block without external power")

    let lowBattery = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20),
        power: PowerInfo(onAC: false, batteryPercent: 20),
        thermal: .nominal,
        now: now
    )
    try expect(lowBattery.0 == .blocked, "battery threshold must block at the configured limit")

    let batteryAllowed = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20),
        power: PowerInfo(onAC: false, batteryPercent: 21),
        thermal: .nominal,
        now: now
    )
    try expect(batteryAllowed.0 == .enabled, "battery above the configured limit must be allowed")

    let overheated = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true),
        power: safePower,
        thermal: .serious,
        now: now
    )
    try expect(overheated.0 == .blocked, "thermal protection must block serious thermal state")

    let thermalDisabled = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true, thermalProtection: false),
        power: safePower,
        thermal: .critical,
        now: now
    )
    try expect(thermalDisabled.0 == .enabled, "disabled thermal protection must allow critical thermal state")

    let expired = LidAwakeController.evaluate(
        settings: LidAwakeSettings(requested: true, expiresAt: now),
        power: safePower,
        thermal: .nominal,
        now: now
    )
    try expect(expired.0 == .disabled, "expired temporary mode must be disabled")
    try expect(expired.2.requested == false, "expired temporary mode must clear requested state")
    try expect(expired.2.expiresAt == nil, "expired temporary mode must clear expiry")

    let legacyData = Data("{\"requested\":false,\"acOnly\":true,\"batteryLimit\":20,\"maxDuration\":28800}".utf8)
    let legacy = try JSONDecoder().decode(LidAwakeSettings.self, from: legacyData)
    try expect(legacy.thermalProtection == true, "legacy settings must enable thermal protection")
    try expect(legacy.notifications == true, "legacy settings must enable notifications")
    try expect(legacy.launchAtLogin == true, "legacy settings must enable launch at login")
    try expect(legacy.skipLidActionsWithExternalDisplay == false, "legacy settings must disable external-display bypass")
    try expect(legacy.displaySleepOnLidClose == false, "legacy settings must disable display sleep")
    try expect(legacy.lockOnLidClose == false, "legacy settings must disable screen locking")
    try expect(legacy.soundOnLidClose == false, "legacy settings must disable lid-close sound")
    try expect(legacy.lidCloseSoundVolume == 50, "legacy settings must use 50% sound volume")

    let original = LidAwakeSettings(
        requested: true,
        acOnly: false,
        batteryLimit: 30,
        maxDuration: 43_200,
        thermalProtection: false,
        notifications: false,
        launchAtLogin: false,
        skipLidActionsWithExternalDisplay: true,
        displaySleepOnLidClose: true,
        lockOnLidClose: true,
        soundOnLidClose: true,
        lidCloseSoundVolume: 75
    )
    let roundTrip = try JSONDecoder().decode(LidAwakeSettings.self, from: JSONEncoder().encode(original))
    try expect(roundTrip == original, "settings Codable round-trip must preserve all values")
    try expect(LidAwakeController.version.isEmpty == false, "build version must not be empty")

    let checksum = String(repeating: "a", count: 64)
    try expect(
        UpdateVerification.parseSHA256("\(checksum)  LidAwake-1.4.3.pkg\n", expectedFilename: "LidAwake-1.4.3.pkg") == checksum,
        "matching release checksum must be parsed"
    )
    try expect(
        UpdateVerification.parseSHA256("\(checksum)  other.pkg\n", expectedFilename: "LidAwake-1.4.3.pkg") == nil,
        "checksum for another file must be rejected"
    )
    try expect(
        UpdateVerification.sha256Hex(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA-256 calculation must match the known vector"
    )
    try expect(
        LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is immediate"),
        "immediate screen-lock delay must be recognized"
    )
    try expect(
        LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is 0"),
        "zero screen-lock delay must be recognized"
    )
    try expect(
        !LidAwakeController.screenLockDelayIsImmediate(output: "screenLock delay is 5 seconds"),
        "non-zero screen-lock delay must be rejected"
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let schedule = AwakeSchedule(enabled: true, fallback: .off, rules: [
        try AwakeScheduleRule(id: "day", days: Set(1...7), start: AwakeScheduleTime("08:00"), end: AwakeScheduleTime("23:00"), mode: .minutes15),
        try AwakeScheduleRule(id: "night", days: Set(1...7), start: AwakeScheduleTime("23:00"), end: AwakeScheduleTime("08:00"), mode: .off)
    ])
    try schedule.validate()
    try expect(schedule.activeRule(at: formatter.date(from: "2026-07-20 12:00")!, calendar: calendar)?.mode == .minutes15, "day schedule must select the 15-minute lid-close action")
    try expect(schedule.activeRule(at: formatter.date(from: "2026-07-20 23:30")!, calendar: calendar)?.mode == .off, "night schedule must select no action")
    try expect(schedule.mode(at: formatter.date(from: "2026-07-21 07:59")!, calendar: calendar) == .off, "overnight schedule must extend into the next day")
    try expect(schedule.activeRule(at: formatter.date(from: "2026-07-21 08:00")!, calendar: calendar)?.mode == .minutes15, "schedule boundary must switch actions")
    try expect(AwakeScheduleMode.minutes15.lidCloseDuration == 900 && AwakeScheduleMode.hour1.lidCloseDuration == 3600, "timed schedule actions must use the configured durations")
    try expect(schedule.nextBoundary(after: formatter.date(from: "2026-07-20 22:00")!, calendar: calendar) == formatter.date(from: "2026-07-20 23:00")!, "next schedule boundary must be calculated")

    let overlap = AwakeSchedule(enabled: true, rules: [
        try AwakeScheduleRule(days: [1], start: AwakeScheduleTime("08:00"), end: AwakeScheduleTime("12:00"), mode: .on),
        try AwakeScheduleRule(days: [1], start: AwakeScheduleTime("11:00"), end: AwakeScheduleTime("13:00"), mode: .off)
    ])
    do {
        try overlap.validate()
        try expect(false, "overlapping schedule rules must be rejected")
    } catch AwakeScheduleError.overlap {
        try expect(true, "overlapping schedule rules are rejected")
    }
}

do {
    try runSelfTests()
    print("Lid Awake self-test passed: \(checks) checks")
} catch let failure as SelfTestFailure {
    fputs("Lid Awake self-test failed: \(failure.message)\n", stderr)
    exit(1)
} catch {
    fputs("Lid Awake self-test failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
