import Foundation

public enum LidAwakeState: String, Codable { case enabled, disabled, blocked, unknown }
public enum ThermalLevel: String, Codable { case nominal, fair, serious, critical, unknown }

public enum L10n {
    public static var isRussian: Bool { Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true }
    public static func text(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
}

public enum LidAwakeError: LocalizedError {
    case helperUnavailable, invalidDuration, invalidValue, commandFailed(String)
    public var errorDescription: String? {
        switch self {
        case .helperUnavailable: return L10n.text("Lid Awake helper is not installed. Run install.sh first.", "Системный helper Lid Awake не установлен. Сначала запустите install.sh.")
        case .invalidDuration: return L10n.text("Duration must be a positive number of seconds.", "Длительность должна быть положительным числом секунд.")
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

    public init(requested: Bool = false, acOnly: Bool = true, batteryLimit: Int = 20, maxDuration: Int = 28_800, expiresAt: Date? = nil, thermalProtection: Bool = true, notifications: Bool = true, launchAtLogin: Bool = true) {
        self.requested = requested; self.acOnly = acOnly; self.batteryLimit = batteryLimit
        self.maxDuration = maxDuration; self.expiresAt = expiresAt
        self.thermalProtection = thermalProtection; self.notifications = notifications; self.launchAtLogin = launchAtLogin
    }

    enum CodingKeys: String, CodingKey { case requested, acOnly, batteryLimit, maxDuration, expiresAt, thermalProtection, notifications, launchAtLogin }
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
    public static let version = "1.1.0"
    public static let helperPath = "/usr/local/libexec/lid-awake-helper"
    public static let cliPath = "/usr/local/bin/lid-awake"
    public static let agentPath = "/usr/local/libexec/lid-awake-agent"
    public static let appLabel = "su.xyz.LidAwake.app"
    public static var supportDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lid Awake", isDirectory: true) }
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var statusFile: URL { supportDirectory.appendingPathComponent("status.json") }
    public static var eventLogFile: URL { supportDirectory.appendingPathComponent("events.log") }
    public static var agentLogFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lid Awake/agent.log") }

    public init() {}

    public func loadSettings() -> LidAwakeSettings {
        guard let data = try? Data(contentsOf: Self.settingsFile), let value = try? JSONDecoder().decode(LidAwakeSettings.self, from: data) else { return LidAwakeSettings() }
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

    public func requestEnabled(duration: Int? = nil) throws {
        var settings = loadSettings(); let seconds = duration ?? settings.maxDuration
        guard seconds > 0 else { throw LidAwakeError.invalidDuration }
        settings.requested = true
        settings.expiresAt = Date().addingTimeInterval(TimeInterval(min(seconds, settings.maxDuration)))
        try saveSettings(settings); _ = try reconcile()
    }

    public func requestDisabled() throws {
        var settings = loadSettings(); settings.requested = false; settings.expiresAt = nil
        try saveSettings(settings); _ = try reconcile()
    }

    public func update(_ mutate: (inout LidAwakeSettings) throws -> Void) throws {
        var settings = loadSettings(); try mutate(&settings)
        settings.batteryLimit = min(max(settings.batteryLimit, 0), 100)
        settings.maxDuration = max(settings.maxDuration, 60)
        try saveSettings(settings); try applyLaunchAtLogin(settings.launchAtLogin); _ = try reconcile()
    }

    public static func evaluate(settings: LidAwakeSettings, power: PowerInfo, thermal: ThermalLevel, now: Date) -> (LidAwakeState, String, LidAwakeSettings, Int?) {
        var updated = settings
        guard updated.requested else { return (.disabled, L10n.text("Disabled", "Выключено"), updated, nil) }
        if let expiry = updated.expiresAt, expiry <= now {
            updated.requested = false; updated.expiresAt = nil
            return (.disabled, L10n.text("Maximum time reached", "Достигнуто максимальное время работы"), updated, nil)
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
        return (.enabled, L10n.text("Closed-lid sleep is disabled", "Сон при закрытии крышки отключён"), updated, remaining)
    }

    @discardableResult public func reconcile(now: Date = Date()) throws -> LidAwakeStatus {
        let old = loadStatus()
        let initial = loadSettings(); let power = readPowerInfo(); let thermal = readThermalLevel()
        let result = Self.evaluate(settings: initial, power: power, thermal: thermal, now: now)
        if result.2 != initial { try saveSettings(result.2) }
        _ = try runHelper(result.0 == .enabled ? "on" : "off")
        let status = LidAwakeStatus(state: result.0, reason: result.1, settings: result.2, power: power, thermal: thermal, remainingSeconds: result.3, updatedAt: now)
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(status).write(to: Self.statusFile, options: .atomic)
        if old?.state != status.state || old?.reason != status.reason { appendEvent(status.reason); if status.settings.notifications { notifyTransition(from: old, to: status) } }
        return status
    }

    public func readPowerInfo() -> PowerInfo {
        let output = run("/usr/bin/pmset", ["-g", "batt"])
        let onAC = output.localizedCaseInsensitiveContains("AC Power")
        let regex = try? NSRegularExpression(pattern: "([0-9]{1,3})%")
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var percent: Int?
        if let match = regex?.firstMatch(in: output, range: range), let r = Range(match.range(at: 1), in: output) { percent = Int(output[r]) }
        return PowerInfo(onAC: onAC, batteryPercent: percent)
    }

    public func readThermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    public func diagnostics() -> String {
        let status = loadStatus(); let settings = loadSettings()
        return """
        Lid Awake \(Self.version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        architecture: \(run("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines))
        helper: \(FileManager.default.isExecutableFile(atPath: Self.helperPath) ? "installed" : "missing")
        pmset: \((try? runHelper("status")) ?? "unavailable")
        requested: \(settings.requested)
        state: \(status?.state.rawValue ?? "unknown")
        reason: \(status?.reason ?? "unknown")
        power: \(status?.power.onAC == true ? "AC" : "battery")
        battery: \(status?.power.batteryPercent.map(String.init) ?? "unknown")
        thermal: \(status?.thermal.rawValue ?? readThermalLevel().rawValue)
        settings: \(Self.settingsFile.path)
        events: \(Self.eventLogFile.path)
        agent-log: \(Self.agentLogFile.path)
        """
    }

    public func applyLaunchAtLogin(_ enabled: Bool) throws {
        let uid = getuid(); let target = "gui/\(uid)/\(Self.appLabel)"
        _ = run("/bin/launchctl", [enabled ? "enable" : "disable", target])
        if enabled { _ = run("/bin/launchctl", ["kickstart", "-k", target]) }
    }

    @discardableResult public func runHelper(_ command: String) throws -> String {
        guard ["on", "off", "status"].contains(command) else { throw LidAwakeError.invalidValue }
        guard FileManager.default.isExecutableFile(atPath: Self.helperPath) else { throw LidAwakeError.helperUnavailable }
        let process = Process(); let out = Pipe(); let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); process.arguments = ["-n", Self.helperPath, command]
        process.standardOutput = out; process.standardError = err
        try process.run(); process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw LidAwakeError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendEvent(_ text: String) {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: Self.eventLogFile) { try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
        else { try? line.write(to: Self.eventLogFile, atomically: true, encoding: .utf8) }
    }

    private func notifyTransition(from old: LidAwakeStatus?, to status: LidAwakeStatus) {
        guard old != nil else { return }
        let title = "Lid Awake"; let message = status.reason.replacingOccurrences(of: "\"", with: "\\\"")
        _ = run("/usr/bin/osascript", ["-e", "display notification \"\(message)\" with title \"\(title)\""])
    }

    @discardableResult private func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }; process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
