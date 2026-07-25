import Foundation
import LidAwakeCore

let controller = LidAwakeController()
let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    Usage:
      lid-awake on
      lid-awake off
      lid-awake status
      lid-awake for <seconds>
      lid-awake cancel-timer
    """)
}

func fail(_ error: Error) -> Never {
    fputs("lid-awake: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func startTimer(seconds: Int) throws {
    guard seconds > 0 else { throw LidAwakeError.invalidDuration }
    controller.cancelTimer()
    try controller.setEnabled(true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: LidAwakeController.cliPath)
    process.arguments = ["_timer", String(seconds)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try controller.writeTimerPID(process.processIdentifier)
    print("enabled for \(seconds) seconds")
}

func runTimer(seconds: Int) -> Never {
    signal(SIGTERM, SIG_DFL)
    Thread.sleep(forTimeInterval: TimeInterval(seconds))
    _ = try? controller.setEnabled(false)
    controller.clearTimerPID()
    exit(0)
}

do {
    guard let command = arguments.first else {
        printUsage()
        exit(64)
    }

    switch command {
    case "on":
        controller.cancelTimer()
        print(try controller.setEnabled(true))
    case "off":
        controller.cancelTimer()
        print(try controller.setEnabled(false))
    case "status":
        print(controller.state().rawValue)
    case "for":
        guard arguments.count == 2, let seconds = Int(arguments[1]) else {
            throw LidAwakeError.invalidDuration
        }
        try startTimer(seconds: seconds)
    case "cancel-timer":
        controller.cancelTimer()
        print(try controller.setEnabled(false))
    case "_timer":
        guard arguments.count == 2, let seconds = Int(arguments[1]), seconds > 0 else {
            exit(64)
        }
        runTimer(seconds: seconds)
    case "help", "--help", "-h":
        printUsage()
    default:
        printUsage()
        exit(64)
    }
} catch {
    fail(error)
}
