import Foundation
import Testing
@testable import LidAwakeCore

@Suite("Lid Awake Core")
struct LidAwakeCoreTests {
    @Test func defaultSafetySettings() {
        let settings = LidAwakeSettings()
        #expect(settings.requested == false)
        #expect(settings.acOnly == true)
        #expect(settings.batteryLimit == 20)
        #expect(settings.maxDuration == 28_800)
        #expect(settings.thermalProtection == true)
        #expect(settings.notifications == true)
        #expect(settings.launchAtLogin == true)
        #expect(settings.lockOnLidClose == false)
        #expect(settings.soundOnLidClose == false)
        #expect(settings.lidCloseSoundVolume == 50)
        #expect(settings.expiresAt == nil)
    }

    @Test func supportPaths() {
        #expect(LidAwakeController.settingsFile.lastPathComponent == "settings.json")
        #expect(LidAwakeController.statusFile.lastPathComponent == "status.json")
        #expect(LidAwakeController.eventLogFile.lastPathComponent == "events.log")
        #expect(LidAwakeController.lastLidCloseFile.lastPathComponent == "last-lid-close.txt")
        #expect(L10n.languageFile.lastPathComponent == "language.txt")
    }

    @Test func statusCodableRoundTrip() throws {
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
        #expect(try JSONDecoder().decode(LidAwakeStatus.self, from: data) == status)
    }

    @Test func permanentModeEnabledWhenSafe() {
        let settings = LidAwakeSettings(requested: true, expiresAt: nil)
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .nominal,
            now: Date()
        )
        #expect(result.0 == .enabled)
        #expect(result.3 == nil)
    }

    @Test func temporaryModeRemainingTime() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, expiresAt: now.addingTimeInterval(3600))
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .nominal,
            now: now
        )
        #expect(result.0 == .enabled)
        #expect(result.3 == 3600)
    }

    @Test func disabledModeNeverBecomesActive() {
        let result = LidAwakeController.evaluate(
            settings: LidAwakeSettings(requested: false),
            power: PowerInfo(onAC: true, batteryPercent: 100),
            thermal: .nominal,
            now: Date()
        )
        #expect(result.0 == .disabled)
    }

    @Test func blockedWithoutExternalPower() {
        let settings = LidAwakeSettings(requested: true)
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: false, batteryPercent: 80),
            thermal: .nominal,
            now: Date()
        )
        #expect(result.0 == .blocked)
    }

    @Test func blockedAtBatteryLimit() {
        let settings = LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20)
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: false, batteryPercent: 20),
            thermal: .nominal,
            now: Date()
        )
        #expect(result.0 == .blocked)
    }

    @Test func batteryAboveLimitIsAllowed() {
        let settings = LidAwakeSettings(requested: true, acOnly: false, batteryLimit: 20)
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: false, batteryPercent: 21),
            thermal: .nominal,
            now: Date()
        )
        #expect(result.0 == .enabled)
    }

    @Test func blockedByThermalProtection() {
        let settings = LidAwakeSettings(requested: true)
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .serious,
            now: Date()
        )
        #expect(result.0 == .blocked)
    }

    @Test func thermalProtectionCanBeDisabled() {
        let settings = LidAwakeSettings(requested: true, thermalProtection: false)
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .critical,
            now: Date()
        )
        #expect(result.0 == .enabled)
    }

    @Test func expiryClearsRequest() {
        let now = Date(timeIntervalSince1970: 100)
        let settings = LidAwakeSettings(requested: true, expiresAt: now)
        let result = LidAwakeController.evaluate(
            settings: settings,
            power: PowerInfo(onAC: true, batteryPercent: 80),
            thermal: .nominal,
            now: now
        )
        #expect(result.0 == .disabled)
        #expect(result.2.requested == false)
        #expect(result.2.expiresAt == nil)
    }

    @Test func oldSettingsRemainDecodable() throws {
        let data = Data("{\"requested\":false,\"acOnly\":true,\"batteryLimit\":20,\"maxDuration\":28800}".utf8)
        let settings = try JSONDecoder().decode(LidAwakeSettings.self, from: data)
        #expect(settings.thermalProtection == true)
        #expect(settings.notifications == true)
        #expect(settings.launchAtLogin == true)
        #expect(settings.lockOnLidClose == false)
        #expect(settings.soundOnLidClose == false)
        #expect(settings.lidCloseSoundVolume == 50)
    }

    @Test func newSettingsRoundTrip() throws {
        let original = LidAwakeSettings(
            requested: true,
            acOnly: false,
            batteryLimit: 30,
            maxDuration: 43_200,
            thermalProtection: false,
            notifications: false,
            launchAtLogin: false,
            lockOnLidClose: true,
            soundOnLidClose: true,
            lidCloseSoundVolume: 75
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LidAwakeSettings.self, from: data) == original)
    }

    @Test func buildVersionIsNotEmpty() {
        #expect(LidAwakeController.version.isEmpty == false)
    }
}
