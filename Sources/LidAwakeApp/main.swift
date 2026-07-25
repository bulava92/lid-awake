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
        statusItem.menu = menu
        menu.delegate = self
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let status = (try? controller.reconcile()) ?? controller.loadStatus()
        let settings = controller.loadSettings()
        let state = status?.state ?? .unknown

        addLabel("Status: \(state.rawValue.capitalized)")
        if let status { addLabel(status.reason) }
        if let power = status?.power {
            addLabel("Power: \(power.onAC ? "Adapter" : "Battery")\(power.batteryPercent.map { ", \($0)%" } ?? "")")
        }
        if let expiry = settings.expiresAt, settings.requested {
            let formatter = DateFormatter(); formatter.timeStyle = .short
            addLabel("Until: \(formatter.string(from: expiry))")
        }
        menu.addItem(.separator())

        addItem("Enable for 15 minutes", #selector(enable15))
        addItem("Enable for 1 hour", #selector(enable60))
        addItem("Enable for 8 hours", #selector(enable480))
        addItem("Disable", #selector(disable), enabled: settings.requested)
        menu.addItem(.separator())

        let ac = addItem("Only while connected to power", #selector(toggleAC))
        ac.state = settings.acOnly ? .on : .off

        let batteryMenu = NSMenu()
        for value in [10, 20, 30, 40] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setBatteryLimit(_:)), keyEquivalent: "")
            item.target = self; item.tag = value; item.state = settings.batteryLimit == value ? .on : .off
            batteryMenu.addItem(item)
        }
        let batteryItem = NSMenuItem(title: "Disable at battery level", action: nil, keyEquivalent: "")
        batteryItem.submenu = batteryMenu; menu.addItem(batteryItem)

        let maxMenu = NSMenu()
        for pair in [(3600, "1 hour"), (14400, "4 hours"), (28800, "8 hours"), (43200, "12 hours")] {
            let item = NSMenuItem(title: pair.1, action: #selector(setMaxDuration(_:)), keyEquivalent: "")
            item.target = self; item.tag = pair.0; item.state = settings.maxDuration == pair.0 ? .on : .off
            maxMenu.addItem(item)
        }
        let maxItem = NSMenuItem(title: "Maximum duration", action: nil, keyEquivalent: "")
        maxItem.submenu = maxMenu; menu.addItem(maxItem)

        menu.addItem(.separator())
        addItem("Quit Lid Awake", #selector(quit))
        statusItem.button?.image = NSImage(systemSymbolName: state == .enabled ? "lock.open.display" : "lock.display", accessibilityDescription: "Lid Awake")
    }

    @discardableResult private func addItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled; menu.addItem(item); return item
    }
    private func addLabel(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }

    private func perform(_ block: () throws -> Void) {
        do { try block() } catch {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Lid Awake"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func enable15() { perform { try controller.requestEnabled(duration: 900) } }
    @objc private func enable60() { perform { try controller.requestEnabled(duration: 3600) } }
    @objc private func enable480() { perform { try controller.requestEnabled(duration: 28800) } }
    @objc private func disable() { perform { try controller.requestDisabled() } }
    @objc private func toggleAC() { perform { try controller.update { $0.acOnly.toggle() } } }
    @objc private func setBatteryLimit(_ sender: NSMenuItem) { perform { try controller.update { $0.batteryLimit = sender.tag } } }
    @objc private func setMaxDuration(_ sender: NSMenuItem) { perform { try controller.update { $0.maxDuration = sender.tag } } }
    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
