import Foundation
import Darwin
import LidAwakeCore

let controller = LidAwakeController()

func run(_ executable: String, _ arguments: [String]) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func readLidClosedRobustly() -> Bool? {
    if let value = controller.readLidClosed() { return value }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-l"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let normalized = output.lowercased()

    if normalized.contains("\"appleclamshellstate\" = yes") ||
        normalized.contains("\"appleclamshellstate\" = true") ||
        normalized.contains("\"appleclamshellstate\" = 1") {
        return true
    }

    if normalized.contains("\"appleclamshellstate\" = no") ||
        normalized.contains("\"appleclamshellstate\" = false") ||
        normalized.contains("\"appleclamshellstate\" = 0") {
        return false
    }

    return nil
}

@discardableResult
func lockAndBlankDisplays() -> Bool {
    var locked = controller.lockScreen()

    if !locked {
        locked = run("/usr/bin/osascript", [
            "-e",
            "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
        ])
    }

    if locked {
        Thread.sleep(forTimeInterval: 0.5)
        _ = run("/usr/bin/pmset", ["displaysleepnow"])
        controller.appendEvent(L10n.text(
            "Screen locked and displays turned off after lid close",
            "Экран заблокирован и дисплеи выключены после закрытия крышки"
        ))
    } else {
        controller.appendEvent(L10n.text(
            "Could not lock screen after lid close",
            "Не удалось заблокировать экран после закрытия крышки"
        ))
    }

    return locked
}

var previousLidClosed = readLidClosedRobustly()

while true {
    do {
        let status = try controller.reconcile()
        let lidClosed = readLidClosedRobustly()
        let settings = controller.loadSettings()

        if settings.lockOnLidClose,
           settings.requested,
           status.state == .enabled,
           previousLidClosed != true,
           lidClosed == true {
            _ = lockAndBlankDisplays()
        }

        if let lidClosed { previousLidClosed = lidClosed }
    } catch {
        fputs("lid-awake-agent: \(error.localizedDescription)\n", stderr)
    }

    Thread.sleep(forTimeInterval: 1)
}
