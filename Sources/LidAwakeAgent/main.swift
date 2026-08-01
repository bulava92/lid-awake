import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import CoreGraphics
import UserNotifications
import LidAwakeCore

final class AgentRuntime {
    private let controller = LidAwakeController()
    private var previousLidClosed: Bool?
    private var lastStatus: LidAwakeStatus?
    private var lastForcedApply = Date.distantPast
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootDomain: io_service_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var pendingPowerReconcile: DispatchWorkItem?
    private var pendingLidCloseActions: DispatchWorkItem?
    private var notificationPermissionRequested = false
    private static let lidCloseDebounceSeconds: TimeInterval = 2

    init() {
        previousLidClosed = controller.readLidClosed()
        controller.rotateLogIfNeeded(LidAwakeController.agentLogFile,
                                     previous: LidAwakeController.agentLogFile.deletingLastPathComponent().appendingPathComponent("agent.log.1"),
                                     maxBytes: 1_048_576)
        controller.appendEvent("Agent started: \(CommandLine.arguments.first ?? "unknown")")
    }

    func start() {
        installLidObserver()
        installPowerSourceObserver()
        evaluatePolicy(force: true)

        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.evaluatePolicy(force: false)
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.handleLidStateChange()
        }
        RunLoop.current.run()
    }

    private func installLidObserver() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            controller.appendEvent("IOKit root domain unavailable; using fallback lid checks")
            return
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { refcon, _, _, _ in
                guard let refcon else { return }
                Unmanaged<AgentRuntime>.fromOpaque(refcon).takeUnretainedValue().handleLidStateChange()
            },
            refcon,
            &notifier
        )
        if result != KERN_SUCCESS {
            controller.appendEvent("Could not register IOKit lid observer: \(result)")
        }
    }

    private func installPowerSourceObserver() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let owner = Unmanaged<AgentRuntime>.fromOpaque(context).takeUnretainedValue()
            owner.handlePowerSourceChange()
        }, context)?.takeRetainedValue() else {
            controller.appendEvent("Could not register IOKit power source observer; using periodic checks")
            return
        }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func handlePowerSourceChange() {
        pendingPowerReconcile?.cancel()
        evaluatePolicy(force: true)

        let delayed = DispatchWorkItem { [weak self] in
            self?.evaluatePolicy(force: true)
        }
        pendingPowerReconcile = delayed
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: delayed)
    }

    private func evaluatePolicy(force: Bool) {
        do {
            let shouldForce = force || Date().timeIntervalSince(lastForcedApply) >= 300
            let status = try controller.reconcile(forceApply: shouldForce)
            if shouldForce { lastForcedApply = Date() }
            ensureNotificationPermissionIfNeeded(status.settings)
            notifyTransitionIfNeeded(status)
            lastStatus = status
        } catch {
            controller.appendEvent("Policy error: \(error.localizedDescription)")
            fputs("lid-awake-agent: \(error.localizedDescription)\n", stderr)
        }
    }

    private func applyScheduleActionForLidClose() -> Bool {
        guard let rule = try? AwakeScheduleStore().load().activeRule(at: Date()) else { return false }
        do {
            switch rule.mode {
            case .off:
                controller.appendEvent(L10n.text(
                    "Schedule action on lid close: do nothing",
                    "Действие расписания при закрытии крышки: ничего не делать"
                ))
                return false
            case .on:
                try controller.requestEnabled(recordScheduleOverride: false)
                controller.appendEvent(L10n.text(
                    "Schedule action on lid close: keep awake",
                    "Действие расписания при закрытии крышки: удерживать активным"
                ))
            case .minutes15, .hour1:
                guard let duration = rule.mode.lidCloseDuration else { return false }
                try controller.requestTemporary(duration: duration)
                controller.appendEvent(L10n.text(
                    "Schedule action on lid close: keep awake for \(duration / 60) minutes",
                    "Действие расписания при закрытии крышки: удерживать активным \(duration / 60) мин."
                ))
            }
            evaluatePolicy(force: true)
            return true
        } catch {
            controller.appendEvent("Could not apply schedule action on lid close: \(error.localizedDescription)")
            return false
        }
    }

    fileprivate func handleLidStateChange() {
        guard let lidClosed = controller.readLidClosed() else { return }
        defer { previousLidClosed = lidClosed }
        if !lidClosed {
            pendingLidCloseActions?.cancel()
            pendingLidCloseActions = nil
            return
        }
        guard previousLidClosed != true, lidClosed else { return }

        evaluatePolicy(force: false)
        guard let status = lastStatus ?? controller.loadStatus() else { return }

        if status.settings.skipLidActionsWithExternalDisplay, hasExternalDisplay() {
            controller.appendEvent(L10n.text(
                "Lid actions skipped because an external display is connected",
                "Действия при закрытии крышки пропущены: подключён внешний монитор"
            ))
            return
        }

        controller.recordLidClose()
        if status.settings.soundOnLidClose {
            if !controller.playLidCloseSound(volumePercent: status.settings.lidCloseSoundVolume) {
                controller.appendEvent("Could not play lid-close sound")
            }
        }

        _ = applyScheduleActionForLidClose()
        evaluatePolicy(force: false)
        guard let updatedStatus = lastStatus ?? controller.loadStatus(),
              updatedStatus.settings.requested,
              updatedStatus.state == .enabled else { return }

        pendingLidCloseActions?.cancel()
        let actions = DispatchWorkItem { [weak self] in
            self?.performDebouncedLidCloseActions()
        }
        pendingLidCloseActions = actions
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lidCloseDebounceSeconds, execute: actions)
    }

    private func hasExternalDisplay() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private func performDebouncedLidCloseActions() {
        pendingLidCloseActions = nil
        guard controller.readLidClosed() == true else { return }

        evaluatePolicy(force: false)
        guard let status = lastStatus ?? controller.loadStatus(),
              status.settings.requested,
              status.state == .enabled else { return }

        var locked = false
        if status.settings.lockOnLidClose {
            locked = controller.lockScreen()
            if !locked {
                controller.appendEvent(L10n.text("Could not lock screen after lid close", "Не удалось заблокировать экран после закрытия крышки"))
            }
        }

        if status.settings.displaySleepOnLidClose {
            if locked { Thread.sleep(forTimeInterval: 0.3) }
            if run("/usr/bin/pmset", ["displaysleepnow"]) {
                controller.appendEvent(L10n.text("Displays turned off after lid close", "Дисплеи выключены после закрытия крышки"))
            } else {
                controller.appendEvent(L10n.text("Could not turn displays off after lid close", "Не удалось выключить дисплеи после закрытия крышки"))
            }
        } else if locked {
            controller.appendEvent(L10n.text("Screen locked after lid close", "Экран заблокирован после закрытия крышки"))
        }
    }

    private func ensureNotificationPermissionIfNeeded(_ settings: LidAwakeSettings) {
        guard settings.notifications, !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { self.controller.appendEvent("Notification permission error: \(error.localizedDescription)") }
            else if !granted { self.controller.appendEvent("Notification permission not granted") }
        }
    }

    private func notifyTransitionIfNeeded(_ status: LidAwakeStatus) {
        guard status.settings.notifications,
              let old = lastStatus,
              old.state != status.state || old.reason != status.reason else { return }
        let content = UNMutableNotificationContent()
        content.title = "Lid Awake"
        content.body = status.reason
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [controller] error in
            if let error { controller.appendEvent("Notification error: \(error.localizedDescription)") }
        }
    }

    private func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    deinit {
        pendingPowerReconcile?.cancel()
        pendingLidCloseActions?.cancel()
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}

AgentRuntime().start()
