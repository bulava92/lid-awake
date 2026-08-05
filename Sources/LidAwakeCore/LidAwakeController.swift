import Foundation
import Darwin
import CryptoKit

public enum LidAwakeState: String, Codable { case enabled, disabled, blocked, unknown }
public enum ThermalLevel: String, Codable { case nominal, fair, serious, critical, unknown }
public enum AppLanguage: String, Codable, CaseIterable { case russian, english }

/// A bounded result from a child process.  The runner never waits for an
/// unbounded pipe read or for an unbounded process termination.
public struct ProcessResult: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32?
    public let timedOut: Bool
    public let duration: TimeInterval
    public let launchError: String?
    public let processID: Int32?
    public let startedAt: Date
    public let endedAt: Date

    public init(stdout: String, stderr: String, exitCode: Int32?, timedOut: Bool,
                duration: TimeInterval, launchError: String? = nil, processID: Int32? = nil,
                startedAt: Date = Date(), endedAt: Date = Date()) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.duration = duration
        self.launchError = launchError
        self.processID = processID
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct LidCloseActionPlan: Equatable {
    public let shouldPlaySound: Bool
    public let shouldDebounce: Bool
    public let reason: String

    public init(shouldPlaySound: Bool, shouldDebounce: Bool, reason: String) {
        self.shouldPlaySound = shouldPlaySound
        self.shouldDebounce = shouldDebounce
        self.reason = reason
    }
}

/// The production lid handler and tests share this decision function. It
/// deliberately accepts only the fresh reconciled status and the current
/// display decision, so stale status cannot authorize an action.
public enum LidCloseActionDecider {
    public static func plan(status: LidAwakeStatus, externalDisplayDetected: Bool) -> LidCloseActionPlan {
        guard status.settings.requested, status.state == .enabled else {
            return LidCloseActionPlan(shouldPlaySound: false, shouldDebounce: false, reason: "inactive")
        }
        if externalDisplayDetected {
            return LidCloseActionPlan(shouldPlaySound: false, shouldDebounce: false, reason: "external-display-bypass")
        }
        return LidCloseActionPlan(shouldPlaySound: status.settings.soundOnLidClose,
                                  shouldDebounce: true, reason: "enabled")
    }
}

public protocol ScreenLocker {
    @discardableResult func lockScreen() -> Bool
}

/// Starts short system sounds without blocking the lid event queue while
/// retaining the Process until afplay exits.
public final class LidAwakeSoundPlayer {
    private let queue = DispatchQueue(label: "su.xyz.LidAwake.sound-player")
    private var activeProcesses: [ObjectIdentifier: Process] = [:]

    public init() {}

    @discardableResult
    public func play(path: String, volumePercent: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/afplay") else { return false }
        let volume = String(format: "%.2f", Double(min(max(volumePercent, 0), 100)) / 100.0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = ["-v", volume, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let id = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.activeProcesses.removeValue(forKey: id) }
        }
        queue.sync { activeProcesses[id] = process }
        do {
            try process.run()
            return true
        } catch {
            _ = queue.sync { activeProcesses.removeValue(forKey: id) }
            return false
        }
    }

    deinit {
        queue.sync {
            activeProcesses.values.forEach { $0.terminate() }
            activeProcesses.removeAll()
        }
    }
}

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
    public var skipLidActionsWithExternalDisplay: Bool
    public var displaySleepOnLidClose: Bool
    public var lockOnLidClose: Bool
    public var soundOnLidClose: Bool
    public var lidCloseSoundVolume: Int
    /// Distinguishes a schedule-owned countdown from a temporary mode chosen
    /// manually in the app or through the CLI. This is persisted so the
    /// background agent can apply the same precedence across processes.
    public var temporaryModeIsScheduled: Bool

    public init(requested: Bool = false, acOnly: Bool = true, batteryLimit: Int = 20,
                maxDuration: Int = 28_800, expiresAt: Date? = nil,
                thermalProtection: Bool = true, notifications: Bool = true,
                launchAtLogin: Bool = true, skipLidActionsWithExternalDisplay: Bool = false,
                displaySleepOnLidClose: Bool = false,
                lockOnLidClose: Bool = false, soundOnLidClose: Bool = false,
                lidCloseSoundVolume: Int = 50,
                temporaryModeIsScheduled: Bool = false) {
        self.requested = requested; self.acOnly = acOnly; self.batteryLimit = batteryLimit
        self.maxDuration = maxDuration; self.expiresAt = expiresAt
        self.thermalProtection = thermalProtection; self.notifications = notifications
        self.launchAtLogin = launchAtLogin
        self.skipLidActionsWithExternalDisplay = skipLidActionsWithExternalDisplay
        self.displaySleepOnLidClose = displaySleepOnLidClose
        self.lockOnLidClose = lockOnLidClose; self.soundOnLidClose = soundOnLidClose
        self.lidCloseSoundVolume = lidCloseSoundVolume
        self.temporaryModeIsScheduled = temporaryModeIsScheduled
    }

    enum CodingKeys: String, CodingKey {
        case requested, acOnly, batteryLimit, maxDuration, expiresAt, thermalProtection
        case notifications, launchAtLogin, skipLidActionsWithExternalDisplay
        case displaySleepOnLidClose, lockOnLidClose
        case soundOnLidClose, lidCloseSoundVolume, temporaryModeIsScheduled
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
        skipLidActionsWithExternalDisplay = try c.decodeIfPresent(Bool.self, forKey: .skipLidActionsWithExternalDisplay) ?? false
        displaySleepOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .displaySleepOnLidClose) ?? false
        lockOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lockOnLidClose) ?? false
        soundOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .soundOnLidClose) ?? false
        lidCloseSoundVolume = try c.decodeIfPresent(Int.self, forKey: .lidCloseSoundVolume) ?? 50
        temporaryModeIsScheduled = try c.decodeIfPresent(Bool.self, forKey: .temporaryModeIsScheduled) ?? false
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

    public init(state: LidAwakeState, reason: String, settings: LidAwakeSettings,
                power: PowerInfo, thermal: ThermalLevel, remainingSeconds: Int?, updatedAt: Date) {
        self.state = state
        self.reason = reason
        self.settings = settings
        self.power = power
        self.thermal = thermal
        self.remainingSeconds = remainingSeconds
        self.updatedAt = updatedAt
    }
}

public enum UpdateVerification {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func parseSHA256(_ text: String, expectedFilename: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            let hash = String(first).lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            if fields.count == 1 { return hash }
            let filename = fields.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if URL(fileURLWithPath: filename).lastPathComponent == expectedFilename { return hash }
        }
        return nil
    }
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

    public func requestEnabled(recordScheduleOverride: Bool = true) throws {
        if recordScheduleOverride { AwakeScheduleStore().recordManualOverride(.on) }
        var settings = loadSettings(); settings.requested = true; settings.expiresAt = nil; settings.temporaryModeIsScheduled = false
        try saveSettings(settings); _ = try reconcile(forceApply: true)
    }

    public func requestTemporary(duration: Int, scheduleOverride: Bool = false) throws {
        var settings = loadSettings()
        guard duration >= 60, duration <= settings.maxDuration else { throw LidAwakeError.invalidDuration }
        settings.requested = true
        settings.expiresAt = Date().addingTimeInterval(TimeInterval(duration))
        settings.temporaryModeIsScheduled = scheduleOverride
        try saveSettings(settings); _ = try reconcile(forceApply: true)
    }

    public func cancelTemporary() throws { try requestDisabled() }

    public func requestDisabled(recordScheduleOverride: Bool = true) throws {
        if recordScheduleOverride { AwakeScheduleStore().recordManualOverride(.off) }
        var settings = loadSettings(); settings.requested = false; settings.expiresAt = nil; settings.temporaryModeIsScheduled = false
        try saveSettings(settings); _ = try reconcile(forceApply: true)
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
            updated.requested = false; updated.expiresAt = nil; updated.temporaryModeIsScheduled = false
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
    private static let soundPlayer = LidAwakeSoundPlayer()

    /// Runs a child process while draining stdout and stderr concurrently.
    /// The polling loop is deliberately bounded even when a descendant keeps a
    /// pipe descriptor open after the direct child has exited.
    public func runProcess(executable: String, arguments: [String], timeout: TimeInterval = 5.0) -> ProcessResult {
        let startedAt = Date()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return ProcessResult(stdout: "", stderr: "", exitCode: nil, timedOut: false,
                                 duration: Date().timeIntervalSince(startedAt),
                                 launchError: "Executable not found: \(executable)", startedAt: startedAt)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            // Foundation duplicates the descriptors for the child. Closing the
            // parent's write ends is required for EOF to reach the read side.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            return ProcessResult(stdout: "", stderr: "", exitCode: nil, timedOut: false,
                                 duration: Date().timeIntervalSince(startedAt),
                                 launchError: error.localizedDescription, startedAt: startedAt)
        }

        let processID = process.processIdentifier
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(stdoutFD, F_SETFL, fcntl(stdoutFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderrFD, F_SETFL, fcntl(stderrFD, F_GETFL) | O_NONBLOCK)
        var stdout = Data()
        var stderr = Data()
        var stdoutOpen = true
        var stderrOpen = true

        func drain(_ fd: Int32, into data: inout Data) -> Bool {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return Darwin.read(fd, baseAddress, bytes.count)
                }
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 { return false }
                if errno == EAGAIN || errno == EWOULDBLOCK { return true }
                return false
            }
        }

        func collect() {
            if stdoutOpen { stdoutOpen = drain(stdoutFD, into: &stdout) }
            if stderrOpen { stderrOpen = drain(stderrFD, into: &stderr) }
        }

        func pollPipes(for interval: TimeInterval) {
            var descriptors: [pollfd] = []
            if stdoutOpen { descriptors.append(pollfd(fd: stdoutFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            if stderrOpen { descriptors.append(pollfd(fd: stderrFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            guard !descriptors.isEmpty else {
                Thread.sleep(forTimeInterval: min(interval, 0.01))
                return
            }
            _ = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), Int32(max(1, min(50, interval * 1000))))
            }
            collect()
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning && Date() < deadline {
            collect()
            if process.isRunning { pollPipes(for: min(0.05, max(0.001, deadline.timeIntervalSinceNow))) }
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let termDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < termDeadline {
                collect()
                pollPipes(for: min(0.05, max(0.001, termDeadline.timeIntervalSinceNow)))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < killDeadline {
                    collect()
                    pollPipes(for: min(0.05, max(0.001, killDeadline.timeIntervalSinceNow)))
                }
            }
        }

        // Drain only for a short grace period. This is what prevents a
        // descendant inheriting stdout/stderr from keeping diagnostics stuck.
        let drainDeadline = Date().addingTimeInterval(0.2)
        while (stdoutOpen || stderrOpen) && Date() < drainDeadline {
            collect()
            if stdoutOpen || stderrOpen { pollPipes(for: 0.02) }
        }
        collect()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        return ProcessResult(
            stdout: String(data: stdout, encoding: .utf8) ?? String(decoding: stdout, as: UTF8.self),
            stderr: String(data: stderr, encoding: .utf8) ?? String(decoding: stderr, as: UTF8.self),
            exitCode: process.isRunning ? nil : process.terminationStatus,
            timedOut: timedOut,
            duration: Date().timeIntervalSince(startedAt),
            processID: processID,
            startedAt: startedAt
        )
    }

    @discardableResult private func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5.0) -> String {
        runProcess(executable: path, arguments: arguments, timeout: timeout).stdout
    }

    @discardableResult private func runIncludingStderr(_ path: String, _ arguments: [String], timeout: TimeInterval = 5.0) -> String {
        let result = runProcess(executable: path, arguments: arguments, timeout: timeout)
        return [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @discardableResult private func runStatus(_ path: String, _ arguments: [String], timeout: TimeInterval = 5.0) -> Bool {
        let result = runProcess(executable: path, arguments: arguments, timeout: timeout)
        return result.launchError == nil && !result.timedOut && result.exitCode == 0
    }

    @discardableResult public func lockScreen() -> Bool {
        if FileManager.default.isExecutableFile(atPath: Self.cgSessionPath),
           runStatus(Self.cgSessionPath, ["-suspend"], timeout: 3.0) {
            return true
        }
        guard screenLockDelayIsImmediate() else { return false }
        return runStatus("/usr/bin/pmset", ["displaysleepnow"], timeout: 3.0)
    }

    public static func screenLockDelayIsImmediate(output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("screenlock delay is immediate")
            || normalized.contains("screen lock delay is immediate")
            || normalized.range(of: #"screen\s*lock.*delay.*(?:0|immediate)"#, options: .regularExpression) != nil
    }

    public func screenLockDelayIsImmediate() -> Bool {
        Self.screenLockDelayIsImmediate(output: runIncludingStderr("/usr/sbin/sysadminctl", ["-screenLock", "status"], timeout: 3.0))
    }

    @discardableResult public func playLidCloseSound(volumePercent: Int) -> Bool {
        Self.soundPlayer.play(path: "/System/Library/Sounds/Glass.aiff", volumePercent: volumePercent)
    }

    public func recordLidClose() {
        let value = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? value.write(to: Self.lastLidCloseFile, atomically: true, encoding: .utf8)
        appendEvent(L10n.text("Lid close detected", "Обнаружено закрытие крышки"))
    }

    public func diagnostics(agentPath: String? = nil) -> String {
        let status = loadStatus(); let settings = loadSettings()
        let schedule = try? AwakeScheduleStore().load()
        let lastClose = (try? String(contentsOf: Self.lastLidCloseFile, encoding: .utf8)) ?? "never"
        let architecture = runProcess(executable: "/usr/bin/uname", arguments: ["-m"], timeout: 2)
        let helperResult = FileManager.default.isExecutableFile(atPath: Self.helperPath)
            ? runProcess(executable: "/usr/bin/sudo", arguments: ["-n", Self.helperPath, "status"], timeout: 2)
            : ProcessResult(stdout: "", stderr: "", exitCode: nil, timedOut: false, duration: 0, launchError: "helper missing")
        let screenLockResult = runProcess(executable: "/usr/sbin/sysadminctl", arguments: ["-screenLock", "status"], timeout: 3)
        let lidResult = runProcess(executable: "/usr/sbin/ioreg", arguments: ["-r", "-k", "AppleClamshellState", "-d", "4"], timeout: 3)
        let lidOutput = lidResult.stdout.lowercased()
        let lidClosed: String = if lidOutput.contains("\"appleclamshellstate\" = yes") || lidOutput.contains("\"appleclamshellstate\" = true") || lidOutput.contains("\"appleclamshellstate\" = 1") {
            "true"
        } else if lidOutput.contains("\"appleclamshellstate\" = no") || lidOutput.contains("\"appleclamshellstate\" = false") || lidOutput.contains("\"appleclamshellstate\" = 0") {
            "false"
        } else {
            "unknown"
        }
        func describe(_ operation: String, executable: String, arguments: [String], _ result: ProcessResult) -> String {
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = [out.isEmpty ? nil : "stdout=\(out)", err.isEmpty ? nil : "stderr=\(err)", result.launchError.map { "launchError=\($0)" }].compactMap { $0 }.joined(separator: ", ")
            let exitCode = result.exitCode.map(String.init) ?? "none"
            let suffix = details.isEmpty ? "" : ", \(details)"
            let formatter = ISO8601DateFormatter()
            return "operation=\(operation), executable=\(executable), arguments=\(arguments), pid=\(result.processID.map(String.init) ?? "none"), started=\(formatter.string(from: result.startedAt)), ended=\(formatter.string(from: result.endedAt)), exit=\(exitCode), timeout=\(result.timedOut), duration=\(String(format: "%.3f", result.duration))s\(suffix)"
        }
        return """
        Lid Awake \(Self.version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        architecture: \(architecture.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        helper: \(FileManager.default.isExecutableFile(atPath: Self.helperPath) ? "installed" : "missing")
        subprocess.uname: \(describe("architecture", executable: "/usr/bin/uname", arguments: ["-m"], architecture))
        subprocess.helper.status: \(describe("helper.status", executable: "/usr/bin/sudo", arguments: ["-n", Self.helperPath, "status"], helperResult))
        subprocess.sysadminctl.screenLock: \(describe("screenLock.status", executable: "/usr/sbin/sysadminctl", arguments: ["-screenLock", "status"], screenLockResult))
        subprocess.ioreg.lid: \(describe("lid.state", executable: "/usr/sbin/ioreg", arguments: ["-r", "-k", "AppleClamshellState", "-d", "4"], lidResult))
        language: \(L10n.selectedLanguage.rawValue)
        requested: \(settings.requested)
        mode: \(settings.expiresAt == nil ? "permanent" : "temporary")
        temporary-mode-source: \(settings.expiresAt == nil ? "none" : (settings.temporaryModeIsScheduled ? "schedule" : "user"))
        schedule-enabled: \(schedule?.enabled ?? false)
        schedule-mode: \(schedule?.mode(at: Date())?.rawValue ?? "manual")
        schedule-next: \(schedule?.nextBoundary(after: Date()).map { ISO8601DateFormatter().string(from: $0) } ?? "none")
        external-display-bypass: \(settings.skipLidActionsWithExternalDisplay)
        displays:
        \(DisplayDetector.systemReport())
        display-sleep-on-lid-close: \(settings.displaySleepOnLidClose)
        lock-on-lid-close: \(settings.lockOnLidClose)
        screen-lock-delay-immediate: \(Self.screenLockDelayIsImmediate(output: screenLockResult.stdout + "\n" + screenLockResult.stderr))
        sound-on-lid-close: \(settings.soundOnLidClose)
        sound-volume: \(settings.lidCloseSoundVolume)%
        lid-closed: \(lidClosed)
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
        let result = runProcess(executable: "/usr/bin/sudo", arguments: ["-n", Self.helperPath, command], timeout: 5)
        if let launchError = result.launchError { throw LidAwakeError.commandFailed(launchError) }
        if result.timedOut { throw LidAwakeError.commandFailed("Helper timed out after \(String(format: "%.2f", result.duration))s") }
        guard result.exitCode == 0 else {
            let message = [result.stderr, result.stdout].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "exit code \(result.exitCode.map(String.init) ?? "unknown")"
            throw LidAwakeError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
}

extension LidAwakeController: ScreenLocker {}
