import Foundation
import LidAwakeCore

let controller = LidAwakeController()
let args = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    Usage:
      lid-awake on [seconds]
      lid-awake off
      lid-awake for <seconds>
      lid-awake status
      lid-awake settings
      lid-awake ac-only on|off
      lid-awake battery-limit <0...100>
      lid-awake max-duration <seconds>
    """)
}

func fail(_ error: Error) -> Never {
    fputs("lid-awake: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func printStatus(_ status: LidAwakeStatus) {
    print("state: \(status.state.rawValue)")
    print("reason: \(status.reason)")
    print("power: \(status.power.onAC ? "AC" : "battery")")
    if let percent = status.power.batteryPercent { print("battery: \(percent)%") }
    if let expiry = status.settings.expiresAt { print("expires: \(ISO8601DateFormatter().string(from: expiry))") }
}

do {
    guard let command = args.first else { usage(); exit(64) }
    switch command {
    case "on":
        let duration = args.count == 2 ? Int(args[1]) : nil
        if args.count > 2 || (args.count == 2 && duration == nil) { throw LidAwakeError.invalidDuration }
        try controller.requestEnabled(duration: duration)
        printStatus(try controller.reconcile())
    case "off", "cancel-timer":
        try controller.requestDisabled()
        printStatus(try controller.reconcile())
    case "for":
        guard args.count == 2, let seconds = Int(args[1]), seconds > 0 else { throw LidAwakeError.invalidDuration }
        try controller.requestEnabled(duration: seconds)
        printStatus(try controller.reconcile())
    case "status":
        printStatus(try controller.reconcile())
    case "settings":
        let value = controller.loadSettings()
        print("requested: \(value.requested)")
        print("ac-only: \(value.acOnly)")
        print("battery-limit: \(value.batteryLimit)")
        print("max-duration: \(value.maxDuration)")
    case "ac-only":
        guard args.count == 2, ["on", "off"].contains(args[1]) else { throw LidAwakeError.invalidValue }
        try controller.update { $0.acOnly = args[1] == "on" }
        print("ac-only: \(args[1])")
    case "battery-limit":
        guard args.count == 2, let value = Int(args[1]), (0...100).contains(value) else { throw LidAwakeError.invalidValue }
        try controller.update { $0.batteryLimit = value }
        print("battery-limit: \(value)")
    case "max-duration":
        guard args.count == 2, let value = Int(args[1]), value > 0 else { throw LidAwakeError.invalidDuration }
        try controller.update {
            $0.maxDuration = value
            if $0.requested { $0.expiresAt = Date().addingTimeInterval(TimeInterval(value)) }
        }
        print("max-duration: \(value)")
    case "help", "--help", "-h": usage()
    default: usage(); exit(64)
    }
} catch { fail(error) }
