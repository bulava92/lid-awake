import Foundation
import Darwin

public enum LidAwakeState: String {
    case enabled
    case disabled
    case unknown
}

public enum LidAwakeError: LocalizedError {
    case helperUnavailable
    case commandFailed(String)
    case invalidDuration

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "Lid Awake helper is not installed. Run install.sh first."
        case .commandFailed(let message):
            return message
        case .invalidDuration:
            return "Duration must be a positive number of seconds."
        }
    }
}

public struct LidAwakeController {
    public static let helperPath = "/usr/local/libexec/lid-awake-helper"
    public static let cliPath = "/usr/local/bin/lid-awake"

    public init() {}

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> String {
        try runHelper(enabled ? "on" : "off")
    }

    public func state() -> LidAwakeState {
        guard let output = try? runHelper("status") else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "enabled": return .enabled
        case "disabled": return .disabled
        default: return .unknown
        }
    }

    @discardableResult
    public func runHelper(_ command: String) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.helperPath) else {
            throw LidAwakeError.helperUnavailable
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", Self.helperPath, command]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LidAwakeError.commandFailed(message.isEmpty ? "Lid Awake command failed." : message)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lid Awake", isDirectory: true)
    }

    public static var timerPIDFile: URL {
        supportDirectory.appendingPathComponent("timer.pid")
    }

    public func writeTimerPID(_ pid: Int32) throws {
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try String(pid).write(to: Self.timerPIDFile, atomically: true, encoding: .utf8)
    }

    public func clearTimerPID() {
        try? FileManager.default.removeItem(at: Self.timerPIDFile)
    }

    public func cancelTimer() {
        defer { clearTimerPID() }
        guard let text = try? String(contentsOf: Self.timerPIDFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              isTimerProcess(pid: pid) else {
            return
        }
        Darwin.kill(pid, SIGTERM)
    }

    private func isTimerProcess(pid: Int32) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else { return false }
        let command = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return command.contains(Self.cliPath) && command.contains("_timer")
    }
}
