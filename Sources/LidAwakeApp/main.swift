import AppKit
import Foundation
import LidAwakeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = LidAwakeController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var refreshTimer: Timer?

    private func t(_ en: String, _ ru: String) -> String { L10n.text(en, ru) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu; menu.delegate = self
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.rebuildMenu() }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let status = (try? controller.reconcile()) ?? controller.loadStatus()
        let settings = controller.loadSettings()
        let state = status?.state ?? .unknown

        addLabel(t("Status: ", "Состояние: ") + localizedState(state))
        if let status { addLabel(status.reason) }
        if let power = status?.power {
            let source = power.onAC ? t("Adapter", "Адаптер") : t("Battery", "Батарея")
            addLabel(t("Power: ", "Питание: ") + source + (power.batteryPercent.map { ", \($0)%" } ?? ""))
            addLabel(t("Thermal state: ", "Температурное состояние: ") + localizedThermal(status.thermal))
        }
        if let remaining = status?.remainingSeconds, settings.requested { addLabel(t("Remaining: ", "Осталось: ") + formatDuration(remaining)) }
        menu.addItem(.separator())

        addItem(t("Enable for 15 minutes", "Включить на 15 минут"), #selector(enable15))
        addItem(t("Enable for 1 hour", "Включить на 1 час"), #selector(enable60))
        addItem(t("Enable for 8 hours", "Включить на 8 часов"), #selector(enable480))
        addItem(t("Disable", "Выключить"), #selector(disable), enabled: settings.requested)
        menu.addItem(.separator())

        let ac = addItem(t("Only while connected to power", "Только при подключённом питании"), #selector(toggleAC)); ac.state = settings.acOnly ? .on : .off
        let thermal = addItem(t("Thermal protection", "Защита от перегрева"), #selector(toggleThermal)); thermal.state = settings.thermalProtection ? .on : .off
        let notifications = addItem(t("Notifications", "Уведомления"), #selector(toggleNotifications)); notifications.state = settings.notifications ? .on : .off
        let login = addItem(t("Launch at login", "Запускать при входе"), #selector(toggleLogin)); login.state = settings.launchAtLogin ? .on : .off

        let batteryMenu = NSMenu()
        for value in [10, 20, 30, 40] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setBatteryLimit(_:)), keyEquivalent: "")
            item.target = self; item.tag = value; item.state = settings.batteryLimit == value ? .on : .off; batteryMenu.addItem(item)
        }
        let batteryItem = NSMenuItem(title: t("Disable at battery level", "Отключать при уровне батареи"), action: nil, keyEquivalent: "")
        batteryItem.submenu = batteryMenu; menu.addItem(batteryItem)

        let maxMenu = NSMenu()
        for pair in [(3600, t("1 hour", "1 час")), (14400, t("4 hours", "4 часа")), (28800, t("8 hours", "8 часов")), (43200, t("12 hours", "12 часов"))] {
            let item = NSMenuItem(title: pair.1, action: #selector(setMaxDuration(_:)), keyEquivalent: "")
            item.target = self; item.tag = pair.0; item.state = settings.maxDuration == pair.0 ? .on : .off; maxMenu.addItem(item)
        }
        let maxItem = NSMenuItem(title: t("Maximum duration", "Максимальная длительность"), action: nil, keyEquivalent: "")
        maxItem.submenu = maxMenu; menu.addItem(maxItem)

        menu.addItem(.separator())
        addItem(t("Check for Updates…", "Проверить обновления…"), #selector(checkUpdates))
        addItem(t("Open Diagnostics…", "Открыть диагностику…"), #selector(showDiagnostics))
        addItem(t("Open Logs", "Открыть логи"), #selector(openLogs))
        addItem(t("Open Project Page", "Открыть страницу проекта"), #selector(openProject))
        menu.addItem(.separator())
        addItem(t("Quit Lid Awake", "Завершить Lid Awake"), #selector(quit))

        let symbol: String
        switch state { case .enabled: symbol = "lock.open.display"; case .blocked: symbol = "exclamationmark.triangle"; default: symbol = "lock.display" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lid Awake")
    }

    private func localizedState(_ state: LidAwakeState) -> String {
        switch state { case .enabled: return t("Enabled", "Включено"); case .disabled: return t("Disabled", "Выключено"); case .blocked: return t("Paused", "Приостановлено"); case .unknown: return t("Unknown", "Неизвестно") }
    }
    private func localizedThermal(_ value: ThermalLevel) -> String {
        switch value { case .nominal: return t("Normal", "Нормальное"); case .fair: return t("Elevated", "Повышенное"); case .serious: return t("High", "Высокое"); case .critical: return t("Critical", "Критическое"); case .unknown: return t("Unknown", "Неизвестно") }
    }
    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours > 0 { return t("\(hours)h \(minutes)m", "\(hours) ч \(minutes) мин") }
        return t("\(max(1, minutes))m", "\(max(1, minutes)) мин")
    }

    @discardableResult private func addItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; menu.addItem(item); return item
    }
    private func addLabel(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }

    private func perform(_ block: () throws -> Void) {
        do { try block() } catch { showAlert(title: "Lid Awake", message: error.localizedDescription, style: .warning) }
        rebuildMenu()
    }
    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert(); alert.alertStyle = style; alert.messageText = title; alert.informativeText = message; alert.runModal()
    }

    @objc private func enable15() { perform { try controller.requestEnabled(duration: 900) } }
    @objc private func enable60() { perform { try controller.requestEnabled(duration: 3600) } }
    @objc private func enable480() { perform { try controller.requestEnabled(duration: 28800) } }
    @objc private func disable() { perform { try controller.requestDisabled() } }
    @objc private func toggleAC() { perform { try controller.update { $0.acOnly.toggle() } } }
    @objc private func toggleThermal() { perform { try controller.update { $0.thermalProtection.toggle() } } }
    @objc private func toggleNotifications() { perform { try controller.update { $0.notifications.toggle() } } }
    @objc private func toggleLogin() { perform { try controller.update { $0.launchAtLogin.toggle() } } }
    @objc private func setBatteryLimit(_ sender: NSMenuItem) { perform { try controller.update { $0.batteryLimit = sender.tag } } }
    @objc private func setMaxDuration(_ sender: NSMenuItem) { perform { try controller.update { $0.maxDuration = sender.tag; if $0.requested { $0.expiresAt = Date().addingTimeInterval(TimeInterval(sender.tag)) } } } }

    @objc private func showDiagnostics() { showAlert(title: t("Diagnostics", "Диагностика"), message: controller.diagnostics()) }
    @objc private func openLogs() {
        let manager = FileManager.default
        try? manager.createDirectory(at: LidAwakeController.agentLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: LidAwakeController.agentLogFile.path) { manager.createFile(atPath: LidAwakeController.agentLogFile.path, contents: nil) }
        NSWorkspace.shared.open(LidAwakeController.agentLogFile)
    }
    @objc private func openProject() { NSWorkspace.shared.open(URL(string: "https://github.com/bulava92/lid-awake")!) }
    @objc private func checkUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/bulava92/lid-awake/releases/latest") else { return }
        var request = URLRequest(url: url); request.setValue("LidAwake/\(LidAwakeController.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let message: String
            if let error { message = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode == 404 { message = self?.t("No published releases yet. You are using version \(LidAwakeController.version).", "Опубликованных релизов пока нет. Установлена версия \(LidAwakeController.version).") ?? "" }
            else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = json["tag_name"] as? String {
                let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                message = clean == LidAwakeController.version ? (self?.t("You have the latest version.", "Установлена последняя версия.") ?? "") : (self?.t("Version \(tag) is available on GitHub.", "На GitHub доступна версия \(tag).") ?? "")
            } else { message = self?.t("Could not check for updates.", "Не удалось проверить обновления.") ?? "" }
            DispatchQueue.main.async { self?.showAlert(title: self?.t("Updates", "Обновления") ?? "Lid Awake", message: message) }
        }.resume()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
