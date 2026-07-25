import AppKit
import Foundation
import LidAwakeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = LidAwakeController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Lid Awake")
        statusItem.menu = menu
        menu.delegate = self
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let state = controller.state()

        let status = NSMenuItem(title: "Status: \(state.rawValue.capitalized)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addItem("Enable", action: #selector(enable), enabled: state != .enabled)
        addItem("Disable", action: #selector(disable), enabled: state != .disabled)

        let timerMenu = NSMenu()
        timerMenu.addItem(item("15 minutes", #selector(timer15)))
        timerMenu.addItem(item("1 hour", #selector(timer60)))
        timerMenu.addItem(item("8 hours", #selector(timer480)))
        let timerItem = NSMenuItem(title: "Enable for…", action: nil, keyEquivalent: "")
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        addItem("Cancel timer and disable", action: #selector(cancelTimer), enabled: true)
        menu.addItem(.separator())
        addItem("Quit Lid Awake", action: #selector(quit), enabled: true)

        statusItem.button?.image = NSImage(
            systemSymbolName: state == .enabled ? "moon.zzz.fill" : "moon.zzz",
            accessibilityDescription: "Lid Awake"
        )
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        return result
    }

    private func addItem(_ title: String, action: Selector, enabled: Bool) {
        let result = item(title, action)
        result.isEnabled = enabled
        menu.addItem(result)
    }

    private func runCLI(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LidAwakeController.cliPath)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                showError("The Lid Awake command failed.")
            }
        } catch {
            showError(error.localizedDescription)
        }
        rebuildMenu()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Lid Awake"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func enable() { runCLI(["on"]) }
    @objc private func disable() { runCLI(["off"]) }
    @objc private func timer15() { runCLI(["for", "900"]) }
    @objc private func timer60() { runCLI(["for", "3600"]) }
    @objc private func timer480() { runCLI(["for", "28800"]) }
    @objc private func cancelTimer() { runCLI(["cancel-timer"]) }
    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
