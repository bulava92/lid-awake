import AppKit
import Carbon.HIToolbox
import Foundation
import LidAwakeCore

private let lidAwakeHotKeySignature: OSType = 0x4C41574B // LAWK
private let lidAwakeHotKeyID: UInt32 = 1

private func lidAwakeHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == lidAwakeHotKeySignature,
          hotKeyID.id == lidAwakeHotKeyID else { return noErr }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    delegate.toggleFromHotKey()
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = LidAwakeController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    private func t(_ en: String, _ ru: String) -> String { L10n.text(en, ru) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        menu.delegate = self
        registerGlobalHotKey()
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.rebuildMenu() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            lidAwakeHotKeyHandler,
            1,
            &eventType,
            userData,
            &hotKeyHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: lidAwakeHotKeySignature, id: lidAwakeHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

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

        let toggleItem = addItem(
            settings.requested ? t("Disable", "Выключить") : t("Enable", "Включить"),
            #selector(togglePermanent)
        )
        toggleItem.keyEquivalent = "l"
        toggleItem.keyEquivalentModifierMask = [.command, .option]

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
        let externalDisplayBypass = item(
            t("Do nothing when an external display is connected", "Не выполнять действия при подключённом внешнем мониторе"),
            #selector(toggleExternalDisplayBypass)
        )
        externalDisplayBypass.state = settings.skipLidActionsWithExternalDisplay ? .on : .off
        lidCloseMenu.addItem(externalDisplayBypass)
        lidCloseMenu.addItem(.separator())

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
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(item(t("Hide menu bar icon…", "Скрыть значок в строке меню…"), #selector(hideMenuBarIcon)))

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

    @objc private func togglePermanent() {
        let settings = controller.loadSettings()
        perform {
            if settings.requested {
                try controller.requestDisabled()
            } else {
                try controller.requestEnabled()
            }
        }
    }

    func toggleFromHotKey() {
        DispatchQueue.main.async { [weak self] in self?.togglePermanent() }
    }

    @objc private func enableTemporary(_ sender: NSMenuItem) { perform { try controller.requestTemporary(duration: sender.tag) } }
    @objc private func cancelTemporary() { perform { try controller.cancelTemporary() } }

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
    @objc private func toggleExternalDisplayBypass() { perform { try controller.update { $0.skipLidActionsWithExternalDisplay.toggle() } } }
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

    @objc private func hideMenuBarIcon() {
        let alert = NSAlert()
        alert.messageText = t("Hide menu bar icon?", "Скрыть значок в строке меню?")
        alert.informativeText = t(
            "The Lid Awake interface will close, but the background agent will continue working. Launch Lid Awake again from Applications to restore the icon.",
            "Интерфейс Lid Awake закроется, но фоновый агент продолжит работать. Чтобы вернуть значок, снова запустите Lid Awake из папки «Программы»."
        )
        alert.addButton(withTitle: t("Hide", "Скрыть"))
        alert.addButton(withTitle: t("Cancel", "Отмена"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSApp.terminate(nil)
    }

    @objc private func showDiagnostics() { showAlert(title: t("Diagnostics", "Диагностика"), message: controller.diagnostics()) }
    @objc private func openLogs() {
        let manager = FileManager.default
        try? manager.createDirectory(at: LidAwakeController.agentLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: LidAwakeController.agentLogFile.path) { manager.createFile(atPath: LidAwakeController.agentLogFile.path, contents: nil) }
        NSWorkspace.shared.open(LidAwakeController.agentLogFile)
    }

    @objc private func checkUpdates() {
        let current = LidAwakeController.version
        guard let url = URL(string: "https://api.github.com/repos/bulava92/lid-awake/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("LidAwake/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.showAlert(title: self.t("Updates", "Обновления"), message: error.localizedDescription, style: .warning) }
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                DispatchQueue.main.async {
                    self.showAlert(title: self.t("Updates", "Обновления"), message: self.t("Could not read the GitHub response.", "Не удалось прочитать ответ GitHub."), style: .warning)
                }
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            let assets = json["assets"] as? [[String: Any]] ?? []
            let downloadableAssets = assets.compactMap { asset -> (name: String, url: URL)? in
                guard let name = asset["name"] as? String,
                      let rawURL = asset["browser_download_url"] as? String,
                      let url = URL(string: rawURL) else { return nil }
                return (name, url)
            }
            let packages = downloadableAssets.filter { $0.name.lowercased().hasSuffix(".pkg") }
            let package = packages.first { $0.name.localizedCaseInsensitiveContains(latest) } ?? packages.first
            let verifiedPackage = package.flatMap { package -> (name: String, url: URL, checksumURL: URL)? in
                let checksumName = package.name + ".sha256"
                guard let checksumURL = downloadableAssets.first(where: {
                    $0.name.caseInsensitiveCompare(checksumName) == .orderedSame
                })?.url else { return nil }
                return (package.name, package.url, checksumURL)
            }

            DispatchQueue.main.async {
                guard latest.compare(current, options: .numeric) == .orderedDescending else {
                    self.showAlert(title: self.t("No update available", "Обновление не требуется"), message: self.t("Version \(current) is up to date.", "Установлена актуальная версия \(current)."))
                    return
                }

                let alert = NSAlert()
                alert.messageText = self.t("Version \(latest) is available", "Доступна версия \(latest)")
                if verifiedPackage != nil {
                    alert.informativeText = self.t("The installer checksum and trusted macOS signature will be verified before it is opened.", "Перед открытием будут проверены контрольная сумма и доверенная подпись установщика macOS.")
                    alert.addButton(withTitle: self.t("Install update", "Установить обновление"))
                } else {
                    alert.informativeText = self.t("The release does not contain a verifiable .pkg installer and matching .sha256 file.", "В релизе нет проверяемого .pkg-установщика и соответствующего файла .sha256.")
                    alert.addButton(withTitle: self.t("Open release", "Открыть релиз"))
                }
                alert.addButton(withTitle: self.t("Open release notes", "Открыть описание"))
                alert.addButton(withTitle: self.t("Later", "Позже"))

                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    if let verifiedPackage {
                        self.downloadAndOpenUpdate(
                            packageURL: verifiedPackage.url,
                            checksumURL: verifiedPackage.checksumURL,
                            filename: verifiedPackage.name,
                            version: latest
                        )
                    } else if let releaseURL {
                        NSWorkspace.shared.open(releaseURL)
                    }
                case .alertSecondButtonReturn:
                    if let releaseURL { NSWorkspace.shared.open(releaseURL) }
                default:
                    break
                }
            }
        }.resume()
    }

    private func downloadAndOpenUpdate(packageURL: URL, checksumURL: URL, filename: String, version: String) {
        var checksumRequest = URLRequest(url: checksumURL)
        checksumRequest.setValue("LidAwake/\(version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: checksumRequest) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data,
                  let text = String(data: data, encoding: .utf8),
                  let expectedChecksum = UpdateVerification.parseSHA256(text, expectedFilename: filename) else {
                DispatchQueue.main.async {
                    self.showAlert(
                        title: self.t("Update verification failed", "Не удалось проверить обновление"),
                        message: self.t("The release checksum is missing or invalid.", "Контрольная сумма релиза отсутствует или некорректна."),
                        style: .warning
                    )
                }
                return
            }
            self.downloadVerifiedPackage(
                packageURL: packageURL,
                filename: filename,
                version: version,
                expectedChecksum: expectedChecksum
            )
        }.resume()
    }

    private func downloadVerifiedPackage(packageURL: URL, filename: String, version: String, expectedChecksum: String) {
        var request = URLRequest(url: packageURL)
        request.setValue("LidAwake/\(version)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.showAlert(title: self.t("Could not download update", "Не удалось скачать обновление"), message: error.localizedDescription, style: .warning) }
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let temporaryURL else {
                DispatchQueue.main.async { self.showAlert(title: self.t("Could not download update", "Не удалось скачать обновление"), message: self.t("The server returned an invalid response.", "Сервер вернул некорректный ответ."), style: .warning) }
                return
            }

            do {
                let safeFilename = URL(fileURLWithPath: filename).lastPathComponent
                guard safeFilename.lowercased().hasSuffix(".pkg") else {
                    throw NSError(domain: "LidAwake.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: self.t("The update file is not a .pkg package.", "Файл обновления не является пакетом .pkg.")])
                }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Lid Awake Updates", isDirectory: true)
                    .appendingPathComponent(version, isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(safeFilename)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw NSError(domain: "LidAwake.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: self.t("The downloaded package is empty or damaged.", "Загруженный пакет пуст или повреждён.")])
                }
                let packageData = try Data(contentsOf: destination, options: .mappedIfSafe)
                guard UpdateVerification.sha256Hex(of: packageData) == expectedChecksum else {
                    throw NSError(domain: "LidAwake.Update", code: 3, userInfo: [NSLocalizedDescriptionKey: self.t("The package checksum does not match the release checksum.", "Контрольная сумма пакета не совпадает с опубликованной.")])
                }
                guard self.verifyInstallerPackage(at: destination) else {
                    throw NSError(domain: "LidAwake.Update", code: 4, userInfo: [NSLocalizedDescriptionKey: self.t("macOS did not accept the package as signed, trusted, and notarized.", "macOS не подтвердила, что пакет подписан, является доверенным и нотарифицирован.")])
                }
                DispatchQueue.main.async {
                    if !NSWorkspace.shared.open(destination) {
                        self.showAlert(title: self.t("Could not open Installer", "Не удалось открыть установщик"), message: self.t("The package was saved at: \(destination.path)", "Пакет сохранён: \(destination.path)"), style: .warning)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.showAlert(title: self.t("Could not prepare update", "Не удалось подготовить обновление"), message: error.localizedDescription, style: .warning) }
            }
        }.resume()
    }

    private func verifyInstallerPackage(at url: URL) -> Bool {
        func succeeds(_ executable: String, _ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        return succeeds("/usr/sbin/pkgutil", ["--check-signature", url.path])
            && succeeds("/usr/sbin/spctl", ["--assess", "--type", "install", url.path])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
