import Foundation
import Darwin
import LidAwakeCore

let controller = LidAwakeController()
let args = Array(CommandLine.arguments.dropFirst())
func t(_ en: String, _ ru: String) -> String { L10n.text(en, ru) }

func usage() {
    print(t("""
    Usage:
      lid-awake on
      lid-awake off
      lid-awake for <seconds>
      lid-awake status
      lid-awake settings
      lid-awake ac-only on|off
      lid-awake external-display-bypass on|off
      lid-awake lock-on-lid-close on|off
      lid-awake battery-limit <0...100>
      lid-awake max-duration <seconds>
      lid-awake thermal-protection on|off
      lid-awake notifications on|off
      lid-awake launch-at-login on|off
      lid-awake language russian|english
      lid-awake diagnostics
      lid-awake log-path
      lid-awake version
    """, """
    Использование:
      lid-awake on
      lid-awake off
      lid-awake for <секунды>
      lid-awake status
      lid-awake settings
      lid-awake ac-only on|off
      lid-awake external-display-bypass on|off
      lid-awake lock-on-lid-close on|off
      lid-awake battery-limit <0...100>
      lid-awake max-duration <секунды>
      lid-awake thermal-protection on|off
      lid-awake notifications on|off
      lid-awake launch-at-login on|off
      lid-awake language russian|english
      lid-awake diagnostics
      lid-awake log-path
      lid-awake version
    """))
}

func fail(_ error: Error) -> Never { fputs("lid-awake: \(error.localizedDescription)\n", stderr); exit(1) }
func boolValue(_ value: String) throws -> Bool {
    guard ["on", "off"].contains(value) else { throw LidAwakeError.invalidValue }
    return value == "on"
}

func printStatus(_ status: LidAwakeStatus) {
    print(t("state", "состояние") + ": \(status.state.rawValue)")
    print(t("reason", "причина") + ": \(status.reason)")
    print(t("mode", "режим") + ": \(status.settings.expiresAt == nil ? t("permanent", "постоянный") : t("temporary", "временный"))")
    print(t("power", "питание") + ": \(status.power.onAC ? "AC" : t("battery", "батарея"))")
    if let percent = status.power.batteryPercent { print(t("battery", "заряд") + ": \(percent)%") }
    print(t("thermal", "температура") + ": \(status.thermal.rawValue)")
    if let remaining = status.remainingSeconds { print(t("remaining", "осталось") + ": \(remaining)") }
}

func printSettings(_ value: LidAwakeSettings) {
    print("requested: \(value.requested)")
    print("ac-only: \(value.acOnly)")
    print("external-display-bypass: \(value.skipLidActionsWithExternalDisplay)")
    print("lock-on-lid-close: \(value.lockOnLidClose)")
    print("battery-limit: \(value.batteryLimit)")
    print("max-temporary-duration: \(value.maxDuration)")
    print("thermal-protection: \(value.thermalProtection)")
    print("notifications: \(value.notifications)")
    print("launch-at-login: \(value.launchAtLogin)")
    print("language: \(L10n.selectedLanguage.rawValue)")
}

do {
    guard let command = args.first else { usage(); exit(64) }
    switch command {
    case "on":
        guard args.count == 1 else { throw LidAwakeError.invalidValue }
        try controller.requestEnabled(); printStatus(try controller.reconcile())
    case "off", "cancel-timer":
        try controller.requestDisabled(); printStatus(try controller.reconcile())
    case "for":
        guard args.count == 2, let seconds = Int(args[1]), seconds > 0 else { throw LidAwakeError.invalidDuration }
        try controller.requestTemporary(duration: seconds); printStatus(try controller.reconcile())
    case "status": printStatus(try controller.reconcile())
    case "settings": printSettings(controller.loadSettings())
    case "ac-only":
        guard args.count == 2 else { throw LidAwakeError.invalidValue }
        let enabled = try boolValue(args[1]); try controller.update { $0.acOnly = enabled }; print("ac-only: \(args[1])")
    case "external-display-bypass":
        guard args.count == 2 else { throw LidAwakeError.invalidValue }
        let enabled = try boolValue(args[1]); try controller.update { $0.skipLidActionsWithExternalDisplay = enabled }; print("external-display-bypass: \(args[1])")
    case "lock-on-lid-close":
        guard args.count == 2 else { throw LidAwakeError.invalidValue }
        let enabled = try boolValue(args[1]); try controller.update { $0.lockOnLidClose = enabled }; print("lock-on-lid-close: \(args[1])")
    case "battery-limit":
        guard args.count == 2, let value = Int(args[1]), (0...100).contains(value) else { throw LidAwakeError.invalidValue }
        try controller.update { $0.batteryLimit = value }; print("battery-limit: \(value)")
    case "max-duration":
        guard args.count == 2, let value = Int(args[1]), value > 0 else { throw LidAwakeError.invalidDuration }
        try controller.update { $0.maxDuration = value; if $0.requested, $0.expiresAt != nil { $0.expiresAt = Date().addingTimeInterval(TimeInterval(value)) } }
        print("max-temporary-duration: \(value)")
    case "thermal-protection":
        guard args.count == 2 else { throw LidAwakeError.invalidValue }
        let enabled = try boolValue(args[1]); try controller.update { $0.thermalProtection = enabled }; print("thermal-protection: \(args[1])")
    case "notifications":
        guard args.count == 2 else { throw LidAwakeError.invalidValue }
        let enabled = try boolValue(args[1]); try controller.update { $0.notifications = enabled }; print("notifications: \(args[1])")
    case "launch-at-login":
        guard args.count == 2 else { throw LidAwakeError.invalidValue }
        let enabled = try boolValue(args[1]); try controller.update { $0.launchAtLogin = enabled }; print("launch-at-login: \(args[1])")
    case "language":
        guard args.count == 2, let language = AppLanguage(rawValue: args[1]) else { throw LidAwakeError.invalidValue }
        try L10n.setLanguage(language); _ = try controller.reconcile(); print("language: \(language.rawValue)")
    case "diagnostics": print(controller.diagnostics())
    case "log-path": print(LidAwakeController.agentLogFile.path)
    case "version", "--version", "-v": print(LidAwakeController.version)
    case "help", "--help", "-h": usage()
    default: usage(); exit(64)
    }
} catch { fail(error) }
