import Foundation

public enum LidAwakeState: String, Codable { case enabled, disabled, blocked, unknown }

public enum LidAwakeError: LocalizedError {
    case helperUnavailable, invalidDuration, invalidValue, commandFailed(String)
    public var errorDescription: String? {
        switch self {
        case .helperUnavailable: return "Lid Awake helper is not installed. Run install.sh first."
        case .invalidDuration: return "Duration must be a positive number of seconds."
        case .invalidValue: return "Invalid value."
        case .commandFailed(let message): return message
        }
    }
}

public struct LidAwakeSettings: Codable, Equatable {
    public var requested = false
    public var acOnly = true
    public var batteryLimit = 20
    public var maxDuration = 28_800
    public var expiresAt: Date?
    public init() {}
}

public struct PowerInfo: Codable, Equatable {
    public var onAC: Bool
    public var batteryPercent: Int?
    public init(onAC: Bool, batteryPercent: Int?) {
        self.onAC = onAC; self.batteryPercent = batteryPercent
    }
}

public struct LidAwakeStatus: Codable, Equatable {
    public var state: LidAwakeState
    public var reason: String
    public var settings: LidAwakeSettings
    public var power: PowerInfo
    public var updatedAt: Date
}

public struct LidAwakeController {
    public static let helperPath = "/usr/local/libexec/lid-awake-helper"
    public static let cliPath = "/usr/local/bin/lid-awake"
    public static let agentPath = "/usr/local/libexec/lid-awake-agent"
    public static var supportDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lid Awake", isDirectory: true) }
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var statusFile: URL { supportDirectory.appendingPathComponent("status.json") }

    public init() {}

    public func loadSettings() -> LidAwakeSettings {
        guard let data = try? Data(contentsOf: Self.settingsFile), let value = try? JSONDecoder().decode(LidAwakeSettings.self, from: data) else { return LidAwakeSettings() }
        return value
    }

    public func saveSettings(_ settings: LidAwakeSettings) throws {
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: Self.settingsFile, options: .atomic)
    }

    public func loadStatus() -> LidAwakeStatus? {
        guard let data = try? Data(contentsOf: Self.statusFile) else { return nil }
        return try? JSONDecoder().decode(LidAwakeStatus.self, from: data)
    }

    public func requestEnabled(duration: Int? = nil) throws {
        var settings = loadSettings()
        let seconds = duration ?? settings.maxDuration
        guard seconds > 0 else { throw LidAwakeError.invalidDuration }
        settings.requested = true
        settings.expiresAt = Date().addingTimeInterval(TimeInterval(min(seconds, settings.maxDuration)))
        try saveSettings(settings)
        _ = try reconcile()
    }

    public func requestDisabled() throws {
        var settings = loadSettings(); settings.requested = false; settings.expiresAt = nil
        try saveSettings(settings); _ = try reconcile()
    }

    public func update(_ mutate: (inout LidAwakeSettings) throws -> Void) throws {
        var settings = loadSettings(); try mutate(&settings); try saveSettings(settings); _ = try reconcile()
    }

    @discardableResult public func reconcile(now: Date = Date()) throws -> LidAwakeStatus {
        var settings = loadSettings()
        let power = readPowerInfo()
        var state: LidAwakeState = .disabled
        var reason = "Disabled"

        if settings.requested {
            if let expiry = settings.expiresAt, expiry <= now {
                settings.requested = false; settings.expiresAt = nil; try saveSettings(settings); reason = "Maximum time reached"
            } else if settings.acOnly && !power.onAC {
                state = .blocked; reason = "Waiting for external power"
            } else if let percent = power.batteryPercent, percent <= settings.batteryLimit {
                state = .blocked; reason = "Battery is at or below \(settings.batteryLimit)%"
            } else {
                state = .enabled; reason = "Closed-lid sleep is disabled"
            }
        }

        _ = try runHelper(state == .enabled ? "on" : "off")
        let status = LidAwakeStatus(state: state, reason: reason, settings: settings, power: power, updatedAt: now)
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(status).write(to: Self.statusFile, options: .atomic)
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

    private func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }; process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
