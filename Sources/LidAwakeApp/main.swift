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
        statusItem.menu = menu
        menu.delegate = self
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.rebuildMenu() }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let status = (try? controller.reconcile()) ?? controller.loadStatus()
        let settings = controller.loadSettings()
        let state = status?.state ?? .unknown

        if let remaining = status?.remainingSeconds, settings.requested, settings.expiresAt != nil {
            addLabel(t("Temporary mode: active, \(formatRemaining(remaining)) remaining", "Временный режим: активен, осталось \(formatRemaining(remaining))"))
        } else {
            addLabel(t("Current mode: ", "Текущий режим: ") + localizedState(state, temporary: false))
        }
        if state == .blocked, let reason = status?.reason { addLabel(reason) }
        menu.addItem(.separator())

        let enable = addItem(t("Enable", "Включить"), #selector(enablePermanent))
        enable.state = settings.requested && settings.expiresAt == nil ? .on : .off
        let disableItem = addItem(t("Disable", "Выключить"), #selector(disable))
        disableItem.state = !settings.requested ? .on : .off

        let temporaryMenu = NSMenu()
        for pair in [(900, t("15 minutes", "15 минут")), (3600, t("1 hour", "1 час")), (28_800, t("8 hours", "8 часов"))] {
            let entry = item(pair.1, #selector(enableTemporary(_:)))
            entry.tag = pair.0
            entry.isEnabled = pair.0 <= settings.maxDuration
            temporaryMenu.addItem(entry)
        }
        temporaryMenu.addItem(.separator())
        temporaryMenu.addItem(item(t("Custom temporary mode…", "Другой временный режим…"), #selector(customTemporaryMode)))
        if settings.expiresAt != nil {
            temporaryMenu.addItem(.separator())
            temporaryMenu.addItem(item(t("Cancel temporary mode", "Отменить временный режим"), #selector(cancelTemporary)))
        }
        menu.addItem(submenu(t("Temporary mode", "Временный режим"), temporaryMenu))

        let settingsMenu = NSMenu()
        let ac = item(t("Only while connected to power", "Только при подключённом питании"), #selector(toggleAC)); ac.state = settings.acOnly ? .on : .off; settingsMenu.addItem(ac)

        let lidCloseMenu = NSMenu()
        let displaySleep = item(t("Turn off displays", "Выключить экран"), #selector(toggleDisplaySleepOnClose))
        displaySleep.state = settings.displaySleepOnLidClose ? .on : .off
        lidCloseMenu.addItem(displaySleep)

        let lock = item(t("Lock screen", "Блокировать экран"), #selector(toggleLockOnClose))
        lock.state = settings.lockOnLidClose ? .on : .off
        lidCloseMenu.addItem(lock)

        let sound = item(t("Play sound", "Воспроизвести звук"), #selector(toggleLidCloseSound))
        sound.state = settings.soundOnLidClose ? .on : .off
        lidCloseMenu.addItem(sound)

        let soundVolumeMenu = NSMenu()
        for value in [25, 50, 75, 100] {
            let entry = item("\(value)%", #selector(setLidCloseSoundVolume(_:))); entry.tag = value
            entry.state = settings.lidCloseSoundVolume == value ? .on : .off; soundVolumeMenu.addItem(entry)
        }
        let soundVolumeItem = submenu(t("Sound volume", "Громкость звука"), soundVolumeMenu)
        soundVolumeItem.isEnabled = settings.soundOnLidClose
        lidCloseMenu.addItem(soundVolumeItem)

        settingsMenu.addItem(submenu(t("When the lid closes…", "При закрытии крышки…"), lidCloseMenu))

        let thermal = item(t("Thermal protection", "Защита от перегрева"), #selector(toggleThermal)); thermal.state = settings.thermalProtection ? .on : .off; settingsMenu.addItem(thermal)
        let notifications = item(t("Notifications", "Уведомления"), #selector(toggleNotifications)); notifications.state = settings.notifications ? .on : .off; settingsMenu.addItem(notifications)
        let login = item(t("Launch at login", "Запускать при входе"), #selector(toggleLogin)); login.state = settings.launchAtLogin ? .on : .off; settingsMenu.addItem(login)
        settingsMenu.addItem(.separator())

        let batteryMenu = NSMenu()
        for value in [10, 20, 30, 40] {
            let entry = item("\(value)%", #selector(setBatteryLimit(_:))); entry.tag = value
            entry.state = settings.batteryLimit == value ? .on : .off; batteryMenu.addItem(entry)
        }
        settingsMenu.addItem(submenu(t("Disable at battery level", "Отключать при уровне батареи"), batteryMenu))

        let maxMenu = NSMenu()
        for pair in [(3600, t("1 hour", "1 час")), (14_400, t("4 hours", "4 часа")), (28_800, t("8 hours", "8 часов")), (43_200, t("12 hours", "12 часов"))] {
            let entry = item(pair.1, #selector(setMaxDuration(_:))); entry.tag = pair.0
            entry.state = settings.maxDuration == pair.0 ? .on : .off; maxMenu.addItem(entry)
        }
        settingsMenu.addItem(submenu(t("Maximum temporary duration", "Максимальная длительность временного режима"), maxMenu))

        let languageMenu = NSMenu()
        let russian = item("Русский", #selector(useRussian)); russian.state = L10n.selectedLanguage == .russian ? .on : .off; languageMenu.addItem(russian)
        let english = item("English", #selector(useEnglish)); english.state = L10n.selectedLanguage == .english ? .on : .off; languageMenu.addItem(english)
        settingsMenu.addItem(submenu(t("Language", "Язык"), languageMenu))

        menu.addItem(submenu(t("Settings", "Настройки"), settingsMenu))
        menu.addItem(.separator())
        addItem(t("Diagnostics…", "Диагностика…"), #selector(showDiagnostics))
        addItem(t("Open log", "Открыть журнал"), #selector(openLogs))
        addItem(t("Check for updates…", "Проверить обновления…"), #selector(checkUpdates))
        menu.addItem(.separator())
        let quitItem = addItem(t("Quit", "Выход"), #selector(quit)); quitItem.keyEquivalent = "q"; quitItem.keyEquivalentModifierMask = [.command]

        let symbol: String
        if state == .blocked {
            if status?.thermal == .serious || status?.thermal == .critical { symbol = "thermometer.high" }
            else if status?.power.onAC == false && settings.acOnly { symbol = "powerplug" }
            else { symbol = "battery.25" }
        } else if state == .enabled {
            symbol = settings.expiresAt == nil ? "lock.open.fill" : "timer"
        } else {
            symbol = "moon.zzz"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lid Awake")
    }

    private func localizedState(_ state: LidAwakeState, temporary: Bool) -> String {
        switch state {
        case .enabled: return temporary ? t("Temporary", "Временный") : t("Enabled", "Включено")
        case .disabled: return t("Disabled", "Выключено")
        case .blocked: return t("Paused", "Приостановлено")
        case .unknown: return t("Unknown", "Неизвестно")
        }
    }

    private func formatRemaining(_ seconds: Int) -> String {
        let hours = seconds / 3600; let minutes = (seconds % 3600) / 60
        if hours > 0 { return t("\(hours)h \(minutes)m", "\(hours) ч \(minutes) мин") }
        return t("\(max(1, minutes))m", "\(max(1, minutes)) мин")
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: ""); result.target = self; return result
    }
    private func submenu(_ title: String, _ child: NSMenu) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: nil, keyEquivalent: ""); result.submenu = child; return result
    }
    @discardableResult private func addItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let result = item(title, action); menu.addItem(result); return result
    }
    private func addLabel(_ title: String) {
        let result = NSMenuItem(title: title, action: nil, keyEquivalent: ""); result.isEnabled = false; menu.addItem(result)
    }
    private func perform(_ block: () throws -> Void) {
        do { try block() } catch { showAlert(title: "Lid Awake", message: error.localizedDescription, style: .warning) }
        rebuildMenu()
    }
    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert(); alert.alertStyle = style; alert.messageText = title; alert.informativeText = message; alert.runModal()
    }

    @objc private func enablePermanent() { perform { try controller.requestEnabled() } }
    @objc private func enableTemporary(_ sender: NSMenuItem) { perform { try controller.requestTemporary(duration: sender.tag) } }
    @objc private func cancelTemporary() { perform { try controller.cancelTemporary() } }
    @objc private func disable() { perform { try controller.requestDisabled() } }

    @objc private func customTemporaryMode() {
        let settings = controller.loadSettings()
        let alert = NSAlert()
        alert.messageText = t("Custom temporary mode", "Другой временный режим")
        alert.informativeText = t("Enter duration in minutes. Maximum: \(settings.maxDuration / 60).", "Введите длительность в минутах. Максимум: \(settings.maxDuration / 60).")
        let field = NSTextField(string: "60"); field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: t("Start", "Запустить")); alert.addButton(withTitle: t("Cancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn, let minutes = Int(field.stringValue), minutes > 0 else { return }
        perform { try controller.requestTemporary(duration: minutes * 60) }
    }

    @objc private func toggleAC() { perform { try controller.update { $0.acOnly.toggle() } } }
    @objc private func toggleDisplaySleepOnClose() { perform { try controller.update { $0.displaySleepOnLidClose.toggle() } } }
    @objc private func toggleLockOnClose() { perform { try controller.update { $0.lockOnLidClose.toggle() } } }
    @objc private func toggleLidCloseSound() { perform { try controller.update { $0.soundOnLidClose.toggle() } } }
    @objc private func setLidCloseSoundVolume(_ sender: NSMenuItem) { perform { try controller.update { $0.lidCloseSoundVolume = sender.tag }; _ = controller.playLidCloseSound(volumePercent: sender.tag) } }
    @objc private func toggleThermal() { perform { try controller.update { $0.thermalProtection.toggle() } } }
    @objc private func toggleNotifications() { perform { try controller.update { $0.notifications.toggle() } } }
    @objc private func toggleLogin() { perform { try controller.update { $0.launchAtLogin.toggle() } } }
    @objc private func setBatteryLimit(_ sender: NSMenuItem) { perform { try controller.update { $0.batteryLimit = sender.tag } } }
    @objc private func setMaxDuration(_ sender: NSMenuItem) { perform { try controller.update { $0.maxDuration = sender.tag } } }
    @objc private func useRussian() { perform { try L10n.setLanguage(.russian); _ = try controller.reconcile() } }
    @objc private func useEnglish() { perform { try L10n.setLanguage(.english); _ = try controller.reconcile() } }

    @objc private func showDiagnostics() { showAlert(title: t("Diagnostics", "Диагностика"), message: controller.diagnostics()) }
    @objc private func openLogs() {
        let manager = FileManager.default
        try? manager.createDirectory(at: LidAwakeController.agentLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: LidAwakeController.agentLogFile.path) { manager.createFile(atPath: LidAwakeController.agentLogFile.path, contents: nil) }
        NSWorkspace.shared.open(LidAwakeController.agentLogFile)
    }

    @objc private func checkUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/bulava92/lid-awake/releases/latest") else { return }
        var request = URLRequest(url: url); request.setValue("LidAwake/\(LidAwakeController.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var message = self?.t("Could not check for updates.", "Не удалось проверить обновления.") ?? ""
            var releaseURL: URL?
            if let error { message = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                message = self?.t("No published releases yet. You are using version \(LidAwakeController.version).", "Опубликованных релизов пока нет. Установлена версия \(LidAwakeController.version).") ?? ""
            } else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = json["tag_name"] as? String {
                let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                if clean == LidAwakeController.version { message = self?.t("You have the latest version.", "Установлена последняя версия.") ?? "" }
                else {
                    message = self?.t("Version \(tag) is available.", "Доступна версия \(tag).") ?? ""
                    if let value = json["html_url"] as? String { releaseURL = URL(string: value) }
                }
            }
            DispatchQueue.main.async {
                let alert = NSAlert(); alert.messageText = self?.t("Updates", "Обновления") ?? "Lid Awake"; alert.informativeText = message
                if releaseURL != nil { alert.addButton(withTitle: self?.t("Open release", "Открыть релиз") ?? "Open"); alert.addButton(withTitle: self?.t("Close", "Закрыть") ?? "Close") }
                if alert.runModal() == .alertFirstButtonReturn, let releaseURL { NSWorkspace.shared.open(releaseURL) }
            }
        }.resume()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
