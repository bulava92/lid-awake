import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import CoreGraphics
import UserNotifications
import LidAwakeCore

final class AgentRuntime {
    private struct ScheduleBaseline {
        let requested: Bool
        let expiresAt: Date?
    }

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
    private var pendingTemporaryExpiry: DispatchWorkItem?
    private var scheduledTemporaryHoldActive = false
    private var timedHoldExpiredWhileClosed = false
    private var schedulePolicyKey: String?
    private var scheduleBaseline: ScheduleBaseline?
    private var notificationPermissionRequested = false
    private let lidEventQueue = DispatchQueue(label: "su.xyz.LidAwake.lid-events", qos: .userInitiated)
    private static let lidCloseDebounceSeconds: TimeInterval = 2
    private static let lidStateProbeDelays: [TimeInterval] = [0, 0.05, 0.2, 0.5, 1.0]

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
        armTemporaryExpiryTimerIfNeeded()

        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lidEventQueue.async { self.evaluatePolicy(force: false) }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.scheduleLidStateProbes()
        }
        RunLoop.current.run()
    }

    private func scheduleLidStateProbes() {
        for delay in Self.lidStateProbeDelays {
            lidEventQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.handleLidStateChange()
            }
        }
    }

    private func installLidObserver() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            controller.appendEvent("IOKit root domain unavailable; using fallback lid checks")
            return
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, lidEventQueue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { refcon, _, _, _ in
                guard let refcon else { return }
                Unmanaged<AgentRuntime>.fromOpaque(refcon).takeUnretainedValue().scheduleLidStateProbes()
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
        lidEventQueue.async { [weak self] in
            guard let self else { return }
            self.pendingPowerReconcile?.cancel()
            self.evaluatePolicy(force: true)

            let delayed = DispatchWorkItem { [weak self] in
                self?.evaluatePolicy(force: true)
            }
            self.pendingPowerReconcile = delayed
            self.lidEventQueue.asyncAfter(deadline: .now() + 3, execute: delayed)
        }
    }

    private func evaluatePolicy(force: Bool) {
        do {
            let now = Date()
            try applySchedulePolicy(now: now)
            let shouldForce = force || now.timeIntervalSince(lastForcedApply) >= 300
            let status = try controller.reconcile(now: now, forceApply: shouldForce)
            if shouldForce { lastForcedApply = Date() }
            ensureNotificationPermissionIfNeeded(status.settings)
            notifyTransitionIfNeeded(status)
            lastStatus = status
        } catch {
            controller.appendEvent("Policy error: \(error.localizedDescription)")
            fputs("lid-awake-agent: \(error.localizedDescription)\n", stderr)
        }
    }

    private func applySchedulePolicy(now: Date) throws {
        let schedule = try AwakeScheduleStore().load()
        let activeRule = schedule.enabled ? schedule.activeRule(at: now) : nil
        let activeMode = activeRule?.mode ?? (schedule.enabled ? schedule.fallback.mode : nil)
        let policyKey: String? = if let activeRule {
            "rule:\(activeRule.id):\(activeRule.mode.rawValue)"
        } else if let activeMode {
            "fallback:\(activeMode.rawValue)"
        } else {
            nil
        }

        if policyKey != schedulePolicyKey {
            pendingTemporaryExpiry?.cancel()
            pendingTemporaryExpiry = nil
            scheduledTemporaryHoldActive = false
            timedHoldExpiredWhileClosed = false
            schedulePolicyKey = policyKey
        }

        guard let activeMode, activeMode != .off else {
            if let baseline = scheduleBaseline {
                var settings = controller.loadSettings()
                settings.requested = baseline.requested
                settings.expiresAt = baseline.expiresAt
                try controller.saveSettings(settings)
                scheduleBaseline = nil
            }
            return
        }

        if scheduleBaseline == nil {
            let settings = controller.loadSettings()
            scheduleBaseline = ScheduleBaseline(requested: settings.requested, expiresAt: settings.expiresAt)
        }

        var settings = controller.loadSettings()
        let lidClosed = controller.readLidClosed() == true
        let desiredRequested: Bool
        let desiredExpiry: Date?

        switch activeMode {
        case .on:
            timedHoldExpiredWhileClosed = false
            scheduledTemporaryHoldActive = false
            desiredRequested = true
            desiredExpiry = nil
        case .minutes15, .hour1:
            if !lidClosed {
                // The timed modes still hold the Mac while the lid is open.
                // Closing starts the countdown; opening cancels it.
                timedHoldExpiredWhileClosed = false
                scheduledTemporaryHoldActive = false
                pendingTemporaryExpiry?.cancel()
                pendingTemporaryExpiry = nil
                desiredRequested = true
                desiredExpiry = nil
            } else if timedHoldExpiredWhileClosed {
                desiredRequested = false
                desiredExpiry = nil
            } else if let expiry = settings.expiresAt, expiry > now {
                scheduledTemporaryHoldActive = true
                if pendingTemporaryExpiry == nil { armTemporaryExpiryTimerIfNeeded() }
                desiredRequested = true
                desiredExpiry = expiry
            } else {
                desiredRequested = true
                desiredExpiry = nil
            }
        case .off:
            return
        }

        if settings.requested != desiredRequested || settings.expiresAt != desiredExpiry {
            settings.requested = desiredRequested
            settings.expiresAt = desiredExpiry
            try controller.saveSettings(settings)
        }
    }

    private func armTemporaryExpiryTimerIfNeeded() {
        pendingTemporaryExpiry?.cancel()
        pendingTemporaryExpiry = nil

        guard let expiry = controller.loadSettings().expiresAt else { return }
        if let schedule = try? AwakeScheduleStore().load(),
           let mode = schedule.activeRule(at: Date())?.mode,
           mode.lidCloseDuration != nil {
            scheduledTemporaryHoldActive = true
        }
        let deadline = expiry
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTemporaryExpiry = nil
            self.scheduledTemporaryHoldActive = false

            guard self.controller.readLidClosed() == true else {
                self.timedHoldExpiredWhileClosed = false
                self.evaluatePolicy(force: true)
                return
            }

            let settings = self.controller.loadSettings()
            guard settings.requested, let currentExpiry = settings.expiresAt else { return }
            // A manual temporary-mode change replaced this schedule hold.
            guard abs(currentExpiry.timeIntervalSince(deadline)) < 1 else {
                self.armTemporaryExpiryTimerIfNeeded()
                return
            }
            self.timedHoldExpiredWhileClosed = true

            do {
                try self.controller.requestDisabled(recordScheduleOverride: false)
                self.controller.appendEvent(L10n.text(
                    "Scheduled lid-close hold ended",
                    "Удержание после закрытия крышки завершено по таймеру"
                ))
            } catch {
                self.controller.appendEvent("Could not end scheduled lid-close hold: \(error.localizedDescription)")
            }
        }
        pendingTemporaryExpiry = timer
        lidEventQueue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timer)
    }

    private func applyScheduleActionForLidClose() -> Bool {
        try? applySchedulePolicy(now: Date())
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
                pendingTemporaryExpiry?.cancel()
                pendingTemporaryExpiry = nil
                scheduledTemporaryHoldActive = false
                try controller.requestEnabled(recordScheduleOverride: false)
                controller.appendEvent(L10n.text(
                    "Schedule action on lid close: keep awake",
                    "Действие расписания при закрытии крышки: удерживать активным"
                ))
            case .minutes15, .hour1:
                guard let duration = rule.mode.lidCloseDuration else { return false }
                timedHoldExpiredWhileClosed = false
                scheduledTemporaryHoldActive = true
                try controller.requestTemporary(duration: duration)
                armTemporaryExpiryTimerIfNeeded()
                controller.appendEvent(L10n.text(
                    "Schedule action on lid close: keep awake for \(duration / 60) minutes",
                    "Действие расписания при закрытии крышки: удерживать активным \(duration / 60) мин."
                ))
            }
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
            if let schedule = try? AwakeScheduleStore().load(),
               schedule.enabled,
               schedule.mode(at: Date())?.lidCloseDuration != nil {
                timedHoldExpiredWhileClosed = false
                scheduledTemporaryHoldActive = false
                pendingTemporaryExpiry?.cancel()
                pendingTemporaryExpiry = nil
            }
            evaluatePolicy(force: true)
            return
        }
        guard previousLidClosed != true, lidClosed else { return }

        let settings = controller.loadSettings()

        if settings.skipLidActionsWithExternalDisplay, hasExternalDisplay() {
            controller.appendEvent(L10n.text(
                "Lid actions skipped because an external display is connected",
                "Действия при закрытии крышки пропущены: подключён внешний монитор"
            ))
            return
        }

        // Start the scheduled hold before logging and playing the optional
        // sound. The Mac may begin clamshell sleep immediately after this
        // notification, so the helper must be enabled first.
        _ = applyScheduleActionForLidClose()

        controller.recordLidClose()
        if settings.soundOnLidClose {
            if !controller.playLidCloseSound(volumePercent: settings.lidCloseSoundVolume) {
                controller.appendEvent("Could not play lid-close sound")
            }
        }

        evaluatePolicy(force: false)
        guard let updatedStatus = lastStatus ?? controller.loadStatus(),
              updatedStatus.settings.requested,
              updatedStatus.state == .enabled else { return }

        pendingLidCloseActions?.cancel()
        let actions = DispatchWorkItem { [weak self] in
            self?.performDebouncedLidCloseActions()
        }
        pendingLidCloseActions = actions
        lidEventQueue.asyncAfter(deadline: .now() + Self.lidCloseDebounceSeconds, execute: actions)
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
        pendingTemporaryExpiry?.cancel()
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}

AgentRuntime().start()
