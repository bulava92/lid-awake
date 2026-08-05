import Foundation
import Darwin
import CoreGraphics
import LidAwakeCore

struct SelfTestFailure: Error {
    let message: String
}

struct SelfTestDisplayProvider: DisplayInfoProvider {
    let builtin: [CGDirectDisplayID: Bool]
    let active: [CGDirectDisplayID: Bool]
    let online: [CGDirectDisplayID: Bool]
    func isOnline(_ id: CGDirectDisplayID) -> Bool { online[id] ?? false }
    func isActive(_ id: CGDirectDisplayID) -> Bool { active[id] ?? false }
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool { builtin[id] ?? false }
    func bounds(_ id: CGDirectDisplayID) -> CGRect { CGRect(x: 0, y: 0, width: 1000, height: 1000) }
    func isInMirrorSet(_ id: CGDirectDisplayID) -> Bool { false }
    func mirrorsDisplay(_ id: CGDirectDisplayID) -> CGDirectDisplayID { kCGNullDirectDisplay }
    func isVirtual(_ id: CGDirectDisplayID) -> Bool { false }
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
    try expect(defaults.temporaryModeIsScheduled == false, "manual temporary mode must be the default source")

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
    try expect(expired.2.temporaryModeIsScheduled == false, "expired temporary mode must clear its source")

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
    try expect(legacy.temporaryModeIsScheduled == false, "legacy settings must default to a manual temporary source")

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
        lidCloseSoundVolume: 75,
        temporaryModeIsScheduled: true
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

    let runner = LidAwakeController()
    let shortProcess = runner.runProcess(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2"], timeout: 2)
    try expect(shortProcess.stdout == "out" && shortProcess.stderr == "err" && shortProcess.exitCode == 0 && !shortProcess.timedOut,
               "process runner must capture both output streams")
    let sleepingProcess = runner.runProcess(executable: "/bin/sleep", arguments: ["10"], timeout: 0.2)
    try expect(sleepingProcess.timedOut && sleepingProcess.duration < 2,
               "process runner must terminate a timed-out child")
    let ignoringTermProcess = runner.runProcess(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 10"], timeout: 0.2)
    try expect(ignoringTermProcess.timedOut && ignoringTermProcess.duration < 2,
               "process runner must escalate from SIGTERM to SIGKILL")
    let inheritedPipeProcess = runner.runProcess(executable: "/bin/sh", arguments: ["-c", "sleep 10 & printf child; exit 0"], timeout: 2)
    try expect(inheritedPipeProcess.exitCode == 0 && inheritedPipeProcess.stdout == "child" && inheritedPipeProcess.duration < 2,
               "process runner must not wait for inherited pipe descriptors")
    let largeOutputScript = "i=0; while [ $i -lt 20000 ]; do printf oooooooooo; printf eeeeeeeeee >&2; i=$((i+1)); done"
    let largeOutputProcess = runner.runProcess(executable: "/bin/sh", arguments: ["-c", largeOutputScript], timeout: 3)
    try expect(!largeOutputProcess.timedOut && largeOutputProcess.exitCode == 0
               && largeOutputProcess.stdout.count > 100_000 && largeOutputProcess.stderr.count > 100_000,
               "process runner must drain large stdout and stderr concurrently")
    let missingProcess = runner.runProcess(executable: "/definitely/not/a/real/executable", arguments: [], timeout: 0.2)
    try expect(missingProcess.launchError != nil && !missingProcess.timedOut,
               "process runner must report launch errors")

    let builtinOnly = DisplayDetector.hasRealExternalDisplay(
        provider: SelfTestDisplayProvider(builtin: [1: true], active: [1: true], online: [1: true]),
        onlineDisplays: [1]
    )
    try expect(!builtinOnly, "built-in display must not trigger external-display bypass")
    let enabledStatus = LidAwakeStatus(
        state: .enabled, reason: "test",
        settings: LidAwakeSettings(requested: true, acOnly: false, soundOnLidClose: true),
        power: safePower, thermal: .nominal, remainingSeconds: nil, updatedAt: now
    )
    let enabledPlan = LidCloseActionDecider.plan(status: enabledStatus, externalDisplayDetected: false)
    try expect(enabledPlan.shouldPlaySound && enabledPlan.shouldDebounce, "enabled lid action must play sound and debounce lock")
    let offStatus = LidAwakeStatus(
        state: .disabled, reason: "test",
        settings: LidAwakeSettings(requested: false, acOnly: false, soundOnLidClose: true),
        power: safePower, thermal: .nominal, remainingSeconds: nil, updatedAt: now
    )
    let offPlan = LidCloseActionDecider.plan(status: offStatus, externalDisplayDetected: false)
    try expect(!offPlan.shouldPlaySound && !offPlan.shouldDebounce, "disabled lid action must do nothing")

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
    try expect(schedule.activeRule(at: formatter.date(from: "2026-07-20 23:30")!, calendar: calendar)?.mode == .off, "night schedule must select standard mode")
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
