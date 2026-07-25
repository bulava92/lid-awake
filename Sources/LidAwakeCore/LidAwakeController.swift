import Foundation
import Darwin

public enum LidAwakeState: String, Codable { case enabled, disabled, blocked, unknown }
public enum ThermalLevel: String, Codable { case nominal, fair, serious, critical, unknown }
public enum AppLanguage: String, Codable, CaseIterable { case russian, english }

public enum L10n {
    public static var languageFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lid Awake/language.txt")
    }
    public static var selectedLanguage: AppLanguage {
        if let value = try? String(contentsOf: languageFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let language = AppLanguage(rawValue: value) { return language }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? .russian : .english
    }
    public static var isRussian: Bool { selectedLanguage == .russian }
    public static func setLanguage(_ language: AppLanguage) throws {
        try FileManager.default.createDirectory(at: languageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try language.rawValue.write(to: languageFile, atomically: true, encoding: .utf8)
    }
    public static func text(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
}

public enum LidAwakeError: LocalizedError {
    case helperUnavailable, invalidDuration, invalidValue, commandFailed(String)
    public var errorDescription: String? {
        switch self {
        case .helperUnavailable: return L10n.text("Lid Awake helper is not installed. Run install.sh first.", "Системный helper Lid Awake не установлен. Сначала запустите install.sh.")
        case .invalidDuration: return L10n.text("Duration must be between 1 minute and the configured maximum.", "Длительность должна быть от 1 минуты до установленного максимума.")
        case .invalidValue: return L10n.text("Invalid value.", "Недопустимое значение.")
        case .commandFailed(let message): return message
        }
    }
}

public struct LidAwakeSettings: Codable, Equatable {
    public var requested: Bool
    public var acOnly: Bool
    public var batteryLimit: Int
    public var maxDuration: Int
    public var expiresAt: Date?
    public var thermalProtection: Bool
    public var notifications: Bool
    public var launchAtLogin: Bool
    public var lockOnLidClose: Bool
    public var soundOnLidClose: Bool
    public var lidCloseSoundVolume: Int

    public init(requested: Bool = false, acOnly: Bool = true, batteryLimit: Int = 20,
                maxDuration: Int = 28_800, expiresAt: Date? = nil,
                thermalProtection: Bool = true, notifications: Bool = true,
                launchAtLogin: Bool = true, lockOnLidClose: Bool = false,
                soundOnLidClose: Bool = false, lidCloseSoundVolume: Int = 50) {
        self.requested = requested; self.acOnly = acOnly; self.batteryLimit = batteryLimit
        self.maxDuration = maxDuration; self.expiresAt = expiresAt
        self.thermalProtection = thermalProtection; self.notifications = notifications
        self.launchAtLogin = launchAtLogin; self.lockOnLidClose = lockOnLidClose
        self.soundOnLidClose = soundOnLidClose; self.lidCloseSoundVolume = lidCloseSoundVolume
    }

    enum CodingKeys: String, CodingKey {
        case requested, acOnly, batteryLimit, maxDuration, expiresAt, thermalProtection
        case notifications, launchAtLogin, lockOnLidClose, soundOnLidClose, lidCloseSoundVolume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requested = try c.decodeIfPresent(Bool.self, forKey: .requested) ?? false
        acOnly = try c.decodeIfPresent(Bool.self, forKey: .acOnly) ?? true
        batteryLimit = try c.decodeIfPresent(Int.self, forKey: .batteryLimit) ?? 20
        maxDuration = try c.decodeIfPresent(Int.self, forKey: .maxDuration) ?? 28_800
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        thermalProtection = try c.decodeIfPresent(Bool.self, forKey: .thermalProtection) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        lockOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lockOnLidClose) ?? false
        soundOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .soundOnLidClose) ?? false
        lidCloseSoundVolume = try c.decodeIfPresent(Int.self, forKey: .lidCloseSoundVolume) ?? 50
    }
}

public struct PowerInfo: Codable, Equatable {
    public var onAC: Bool
    public var batteryPercent: Int?
    public init(onAC: Bool, batteryPercent: Int?) { self.onAC = onAC; self.batteryPercent = batteryPercent }
}

public struct LidAwakeStatus: Codable, Equatable {
    public var state: LidAwakeState
    public var reason: String
    public var settings: LidAwakeSettings
    public var power: PowerInfo
    public var thermal: ThermalLevel
    public var remainingSeconds: Int?
    public var updatedAt: Date
}

public struct LidAwakeController {
    public static let version = BuildVersion.current
    public static let helperPath = "/usr/local/libexec/lid-awake-helper"
    public static let cliPath = "/usr/local/bin/lid-awake"
    public static let appLabel = "su.xyz.LidAwake.app"
    public static let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    public static var supportDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lid Awake", isDirectory: true) }
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var statusFile: URL { supportDirectory.appendingPathComponent("status.json") }
    public static var eventLogFile: URL { supportDirectory.appendingPathComponent("events.log") }
    public static var previousEventLogFile: URL { supportDirectory.appendingPathComponent("events.log.1") }
    public static var lastLidCloseFile: URL { supportDirectory.appendingPathComponent("last-lid-close.txt") }
    public static var agentLogFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lid Awake/agent.log") }

    public init() {}

    public func loadSettings() -> LidAwakeSettings {
        guard let data = try? Data(contentsOf: Self.settingsFile),
              let value = try? JSONDecoder().decode(LidAwakeSettings.self, from: data) else { return LidAwakeSettings() }
        return value
    }

    public func saveSettings(_ settings: LidAwakeSettings) throws {
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: Self.settingsFile, options: .atomic)
    }

    public func loadStatus() -> LidAwakeStatus? {
        guard let data = try? Data(contentsOf: Self.statusFile) else { return nil }
        return try? JSONDecoder().decode(LidAwakeStatus.self, from: data)
    }

    public func requestEnabled() throws {
        var settings = loadSettings(); settings.requested = true; settings.expiresAt = nil
        try saveSettings(settings); _ = try reconcile()
    }

    public func requestTemporary(duration: Int) throws {
        var settings = loadSettings()
        guard duration >= 60, duration <= settings.maxDuration else { throw LidAwakeError.invalidDuration }
        settings.requested = true; settings.expiresAt = Date().addingTimeInterval(TimeInterval(duration))
        try saveSettings(settings); _ = try reconcile()
    }

    public func cancelTemporary() throws { try requestDisabled() }

    public func requestDisabled() throws {
        var settings = loadSettings(); settings.requested = false; settings.expiresAt = nil
        try saveSettings(settings); _ = try reconcile()
    }

    public func update(_ mutate: (inout LidAwakeSettings) throws -> Void) throws {
        let previous = loadSettings(); var settings = previous
        try mutate(&settings)
        settings.batteryLimit = min(max(settings.batteryLimit, 0), 100)
        settings.maxDuration = max(settings.maxDuration, 60)
        settings.lidCloseSoundVolume = min(max(settings.lidCloseSoundVolume, 0), 100)
        if let expiry = settings.expiresAt, expiry.timeIntervalSinceNow > TimeInterval(settings.maxDuration) {
            settings.expiresAt = Date().addingTimeInterval(TimeInterval(settings.maxDuration))
        }
        try saveSettings(settings)
        if settings.launchAtLogin != previous.launchAtLogin { try applyLaunchAtLogin(settings.launchAtLogin) }
        _ = try reconcile()
    }

    public static func evaluate(settings: LidAwakeSettings, power: PowerInfo, thermal: ThermalLevel, now: Date) -> (LidAwakeState, String, LidAwakeSettings, Int?) {
        var updated = settings
        guard updated.requested else { return (.disabled, L10n.text("Disabled", "Выключено"), updated, nil) }
        if let expiry = updated.expiresAt, expiry <= now {
            updated.requested = false; updated.expiresAt = nil
            return (.disabled, L10n.text("Temporary mode completed", "Временный режим завершён"), updated, nil)
        }
        let remaining = updated.expiresAt.map { max(0, Int($0.timeIntervalSince(now))) }
        if updated.thermalProtection && [.serious, .critical].contains(thermal) {
            return (.blocked, L10n.text("Paused because the Mac is too hot", "Приостановлено из-за высокой температуры Mac"), updated, remaining)
        }
        if updated.acOnly && !power.onAC {
            return (.blocked, L10n.text("Waiting for external power", "Ожидание подключения питания"), updated, remaining)
        }
        if let percent = power.batteryPercent, percent <= updated.batteryLimit {
            return (.blocked, L10n.text("Battery is at or below \(updated.batteryLimit)%", "Заряд батареи \(updated.batteryLimit)% или ниже"), updated, remaining)
        }
        return (.enabled, updated.expiresAt == nil ? L10n.text("Enabled until switched off", "Включено до ручного отключения") : L10n.text("Temporary mode is active", "Временный режим активен"), updated, remaining)
    }

    @discardableResult public func reconcile(now: Date = Date(), forceApply: Bool = false) throws -> LidAwakeStatus {
        let old = loadStatus(); let initial = loadSettings()
        let power = readPowerInfo(); let thermal = readThermalLevel()
        let result = Self.evaluate(settings: initial, power: power, thermal: thermal, now: now)
        if result.2 != initial { try saveSettings(result.2) }
        if forceApply || old == nil || old?.state != result.0 {
            _ = try runHelper(result.0 == .enabled ? "on" : "off")
        }
        let status = LidAwakeStatus(state: result.0, reason: result.1, settings: result.2, power: power, thermal: thermal, remainingSeconds: result.3, updatedAt: now)
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(status).write(to: Self.statusFile, options: .atomic)
        if old?.state != status.state || old?.reason != status.reason { appendEvent(status.reason) }
        return status
    }

    public func readPowerInfo() -> PowerInfo {
        let output = run("/usr/bin/pmset", ["-g", "batt"])
        let onAC = output.localizedCaseInsensitiveContains("AC Power")
        let regex = try? NSRegularExpression(pattern: "([0-9]{1,3})%")
        let range = NSRange(output.startIndex..<output.endIndex, in: output); var percent: Int?
        if let match = regex?.firstMatch(in: output, range: range), let r = Range(match.range(at: 1), in: output) { percent = Int(output[r]) }
        return PowerInfo(onAC: onAC, batteryPercent: percent)
    }

    public func readThermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal; case .fair: return .fair
        case .serious: return .serious; case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    public func readLidClosed() -> Bool? {
        let output = run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "4"]).lowercased()
        if output.contains("\"appleclamshellstate\" = yes") || output.contains("\"appleclamshellstate\" = true") || output.contains("\"appleclamshellstate\" = 1") { return true }
        if output.contains("\"appleclamshellstate\" = no") || output.contains("\"appleclamshellstate\" = false") || output.contains("\"appleclamshellstate\" = 0") { return false }
        return nil
    }

    @discardableResult public func lockScreen() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.cgSessionPath) else { return false }
        return runStatus(Self.cgSessionPath, ["-suspend"])
    }

    @discardableResult public func playLidCloseSound(volumePercent: Int) -> Bool {
        let sound = "/System/Library/Sounds/Glass.aiff"
        guard FileManager.default.fileExists(atPath: sound) else { return false }
        let volume = String(format: "%.2f", Double(min(max(volumePercent, 0), 100)) / 100.0)
        return runStatus("/usr/bin/afplay", ["-v", volume, sound])
    }

    public func recordLidClose() {
        let value = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? value.write(to: Self.lastLidCloseFile, atomically: true, encoding: .utf8)
        appendEvent(L10n.text("Lid close detected", "Обнаружено закрытие крышки"))
    }

    public func diagnostics(agentPath: String? = nil) -> String {
        let status = loadStatus(); let settings = loadSettings()
        let lastClose = (try? String(contentsOf: Self.lastLidCloseFile, encoding: .utf8)) ?? "never"
        return """
        Lid Awake \(Self.version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        architecture: \(run("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines))
        helper: \(FileManager.default.isExecutableFile(atPath: Self.helperPath) ? "installed" : "missing")
        pmset: \((try? runHelper("status")) ?? "unavailable")
        language: \(L10n.selectedLanguage.rawValue)
        requested: \(settings.requested)
        mode: \(settings.expiresAt == nil ? "permanent" : "temporary")
        lock-on-lid-close: \(settings.lockOnLidClose)
        sound-on-lid-close: \(settings.soundOnLidClose)
        sound-volume: \(settings.lidCloseSoundVolume)%
        lid-closed: \(readLidClosed().map(String.init) ?? "unknown")
        last-lid-close: \(lastClose)
        state: \(status?.state.rawValue ?? "unknown")
        reason: \(status?.reason ?? "unknown")
        power: \(status?.power.onAC == true ? "AC" : "battery")
        battery: \(status?.power.batteryPercent.map(String.init) ?? "unknown")
        thermal: \(status?.thermal.rawValue ?? readThermalLevel().rawValue)
        agent: \(agentPath ?? "~/Library/Application Support/Lid Awake/Lid Awake Agent.app/Contents/MacOS/lid-awake-agent")
        settings: \(Self.settingsFile.path)
        events: \(Self.eventLogFile.path)
        agent-log: \(Self.agentLogFile.path)
        """
    }

    public func applyLaunchAtLogin(_ enabled: Bool) throws {
        let target = "gui/\(getuid())/\(Self.appLabel)"
        _ = run("/bin/launchctl", [enabled ? "enable" : "disable", target])
    }

    @discardableResult public func runHelper(_ command: String) throws -> String {
        guard ["on", "off", "status"].contains(command) else { throw LidAwakeError.invalidValue }
        guard FileManager.default.isExecutableFile(atPath: Self.helperPath) else { throw LidAwakeError.helperUnavailable }
        let process = Process(); let out = Pipe(); let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", Self.helperPath, command]
        process.standardOutput = out; process.standardError = err
        try process.run(); process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw LidAwakeError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func appendEvent(_ text: String) {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        rotateLogIfNeeded(Self.eventLogFile, previous: Self.previousEventLogFile, maxBytes: 1_048_576)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: Self.eventLogFile) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        } else { try? line.write(to: Self.eventLogFile, atomically: true, encoding: .utf8) }
    }

    public func rotateLogIfNeeded(_ file: URL, previous: URL, maxBytes: UInt64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? NSNumber, size.uint64Value >= maxBytes else { return }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: file, to: previous)
    }

    @discardableResult private func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }; process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @discardableResult private func runStatus(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }; process.waitUntilExit(); return process.terminationStatus == 0
    }
}
