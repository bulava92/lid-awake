import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications
import LidAwakeCore

final class AgentRuntime {
    private struct ScheduleBaseline {
        let requested: Bool
        let expiresAt: Date?
        let temporaryModeIsScheduled: Bool
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
            _ = try reconcilePolicy(now: Date(), force: force)
        } catch {
            controller.appendEvent("Policy error: \(error.localizedDescription)")
            fputs("lid-awake-agent: \(error.localizedDescription)\n", stderr)
        }
    }

    @discardableResult
    private func reconcilePolicy(now: Date, force: Bool) throws -> LidAwakeStatus {
        try applySchedulePolicy(now: now)
        let shouldForce = force || now.timeIntervalSince(lastForcedApply) >= 300
        let status = try controller.reconcile(now: now, forceApply: shouldForce)
        if shouldForce { lastForcedApply = now }
        ensureNotificationPermissionIfNeeded(status.settings)
        notifyTransitionIfNeeded(status)
        lastStatus = status
        return status
    }

    private func userTemporaryModeIsActive(_ settings: LidAwakeSettings, now: Date) -> Bool {
        settings.requested
            && !settings.temporaryModeIsScheduled
            && settings.expiresAt.map { $0 > now } == true
    }

    private func expiredUserTemporaryMode(_ settings: LidAwakeSettings, now: Date) -> Bool {
        !settings.temporaryModeIsScheduled
            && settings.expiresAt.map { $0 <= now } == true
    }

    private func applySchedulePolicy(now: Date) throws {
        var settings = controller.loadSettings()
        if userTemporaryModeIsActive(settings, now: now) {
            // A temporary mode selected by the user owns both requested and
            // expiry state until it ends. The schedule must not overwrite it.
            return
        }
        let userTemporaryExpired = expiredUserTemporaryMode(settings, now: now)
        if userTemporaryExpired {
            // Normalize an expired user timer before the schedule evaluates;
            // otherwise a timed schedule could replace the expiry first.
            _ = try controller.reconcile(now: now, forceApply: false)
            settings = controller.loadSettings()
        }

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

        guard let activeMode else {
            if let baseline = scheduleBaseline {
                settings.requested = baseline.requested
                settings.expiresAt = baseline.expiresAt
                settings.temporaryModeIsScheduled = baseline.temporaryModeIsScheduled
                try controller.saveSettings(settings)
                scheduleBaseline = nil
            }
            return
        }

        if scheduleBaseline == nil {
            scheduleBaseline = ScheduleBaseline(
                requested: settings.requested,
                expiresAt: settings.expiresAt,
                temporaryModeIsScheduled: settings.temporaryModeIsScheduled
            )
        }

        let lidClosed = controller.readLidClosed() == true
        let desiredRequested: Bool
        let desiredExpiry: Date?
        let desiredTemporaryModeIsScheduled: Bool

        switch activeMode {
        case .off:
            pendingTemporaryExpiry?.cancel()
            pendingTemporaryExpiry = nil
            scheduledTemporaryHoldActive = false
            timedHoldExpiredWhileClosed = false
            desiredRequested = false
            desiredExpiry = nil
            desiredTemporaryModeIsScheduled = false
        case .on:
            timedHoldExpiredWhileClosed = false
            scheduledTemporaryHoldActive = false
            desiredRequested = true
            desiredExpiry = nil
            desiredTemporaryModeIsScheduled = false
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
                desiredTemporaryModeIsScheduled = false
            } else if timedHoldExpiredWhileClosed {
                desiredRequested = false
                desiredExpiry = nil
                desiredTemporaryModeIsScheduled = false
            } else if userTemporaryExpired {
                // If the user timer ended while the lid was already closed,
                // resume the active timed schedule with a fresh countdown.
                desiredRequested = true
                desiredExpiry = now.addingTimeInterval(TimeInterval(activeMode.lidCloseDuration ?? 0))
                desiredTemporaryModeIsScheduled = true
            } else if let expiry = settings.expiresAt, expiry > now {
                scheduledTemporaryHoldActive = true
                if pendingTemporaryExpiry == nil { armTemporaryExpiryTimerIfNeeded() }
                desiredRequested = true
                desiredExpiry = expiry
                desiredTemporaryModeIsScheduled = true
            } else {
                desiredRequested = true
                desiredExpiry = nil
                desiredTemporaryModeIsScheduled = false
            }
        }

        if settings.requested != desiredRequested
            || settings.expiresAt != desiredExpiry
            || settings.temporaryModeIsScheduled != desiredTemporaryModeIsScheduled {
            settings.requested = desiredRequested
            settings.expiresAt = desiredExpiry
            settings.temporaryModeIsScheduled = desiredTemporaryModeIsScheduled
            try controller.saveSettings(settings)
        }
        if desiredTemporaryModeIsScheduled, desiredExpiry != nil, pendingTemporaryExpiry == nil {
            armTemporaryExpiryTimerIfNeeded()
        }
    }

    private func armTemporaryExpiryTimerIfNeeded() {
        pendingTemporaryExpiry?.cancel()
        pendingTemporaryExpiry = nil

        let settings = controller.loadSettings()
        guard settings.temporaryModeIsScheduled, let expiry = settings.expiresAt else { return }
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
            guard settings.requested, let currentExpiry = settings.expiresAt else {
                self.evaluatePolicy(force: true)
                return
            }
            guard settings.temporaryModeIsScheduled else {
                // The user started a temporary mode while a scheduled
                // countdown was pending. Never disable that user-owned mode.
                self.timedHoldExpiredWhileClosed = self.controller.readLidClosed() == true
                self.evaluatePolicy(force: true)
                return
            }
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

    private func applyScheduleActionForLidClose() throws -> Bool {
        let now = Date()
        let settings = controller.loadSettings()
        guard !userTemporaryModeIsActive(settings, now: now) else { return false }
        try applySchedulePolicy(now: now)
        guard let rule = try AwakeScheduleStore().load().activeRule(at: now) else { return false }
        switch rule.mode {
        case .off:
            controller.appendEvent(L10n.text(
                "Schedule action on lid close: use standard mode",
                "Действие расписания при закрытии крышки: штатный режим"
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
            try controller.requestTemporary(duration: duration, scheduleOverride: true)
            armTemporaryExpiryTimerIfNeeded()
            controller.appendEvent(L10n.text(
                "Schedule action on lid close: keep awake for \(duration / 60) minutes",
                "Действие расписания при закрытии крышки: удерживать активным \(duration / 60) мин."
            ))
        }
        return true
    }

    fileprivate func handleLidStateChange() {
        guard let lidClosed = controller.readLidClosed() else { return }
        let prev = previousLidClosed
        previousLidClosed = lidClosed
        if !lidClosed {
            pendingLidCloseActions?.cancel()
            pendingLidCloseActions = nil
            if let schedule = try? AwakeScheduleStore().load(), schedule.enabled, schedule.mode(at: Date())?.lidCloseDuration != nil {
                timedHoldExpiredWhileClosed = false
                scheduledTemporaryHoldActive = false
                pendingTemporaryExpiry?.cancel()
                pendingTemporaryExpiry = nil
            }
            evaluatePolicy(force: true)
            return
        }
        guard prev != true, lidClosed else { return }

        controller.recordLidClose()
        do {
            let scheduleApplied = try applyScheduleActionForLidClose()
            // This is intentionally a fresh schedule + reconcile pass. Never
            // use lastStatus here: it can describe the state before the lid
            // close changed the schedule-owned settings.
            let freshStatus = try reconcilePolicy(now: Date(), force: true)
            let freshSettings = freshStatus.settings
            let extDisplayDetected = freshSettings.skipLidActionsWithExternalDisplay && DisplayDetector.checkSystem()
            let plan = LidCloseActionDecider.plan(status: freshStatus, externalDisplayDetected: extDisplayDetected)
            controller.appendEvent("LidCloseEvent: prev=\(String(describing: prev)), schedApplied=\(scheduleApplied), freshReq=\(freshSettings.requested), freshState=\(freshStatus.state.rawValue), extDisplay=\(extDisplayDetected)")
            guard plan.shouldDebounce else {
                controller.appendEvent("Lid actions skipped: \(plan.reason)")
                return
            }
            if plan.shouldPlaySound {
                let soundStarted = controller.playLidCloseSound(volumePercent: freshSettings.lidCloseSoundVolume)
                controller.appendEvent("Sound action: started=\(soundStarted)")
            }
        } catch {
            // A failed schedule/reconcile must not trigger actions from stale
            // settings. The physical lid event itself remains logged.
            controller.appendEvent("Lid close policy failed; actions skipped: \(error.localizedDescription)")
            return
        }

        pendingLidCloseActions?.cancel()
        let actions = DispatchWorkItem { [weak self] in
            self?.performDebouncedLidCloseActions()
        }
        pendingLidCloseActions = actions
        lidEventQueue.asyncAfter(deadline: .now() + Self.lidCloseDebounceSeconds, execute: actions)
    }

    private func performDebouncedLidCloseActions() {
        pendingLidCloseActions = nil
        guard controller.readLidClosed() == true else {
            controller.appendEvent("Debounce cancelled: lid opened")
            return
        }
        let status: LidAwakeStatus
        do {
            status = try reconcilePolicy(now: Date(), force: true)
        } catch {
            controller.appendEvent("Debounce policy failed; actions skipped: \(error.localizedDescription)")
            return
        }
        let externalDisplayDetected = status.settings.skipLidActionsWithExternalDisplay && DisplayDetector.checkSystem()
        let plan = LidCloseActionDecider.plan(status: status, externalDisplayDetected: externalDisplayDetected)
        guard plan.shouldDebounce else {
            controller.appendEvent("Debounce cancelled: \(plan.reason)")
            return
        }

        var locked = false
        if status.settings.lockOnLidClose {
            locked = controller.lockScreen()
            controller.appendEvent(locked ? "Screen locked" : "Screen lock failed")
        }

        if status.settings.displaySleepOnLidClose {
            if locked { Thread.sleep(forTimeInterval: 0.3) }
            let result = controller.runProcess(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"], timeout: 3)
            if result.launchError == nil, !result.timedOut, result.exitCode == 0 {
                controller.appendEvent("Displays asleep")
            } else {
                controller.appendEvent("Displays asleep failed: exit=\(result.exitCode.map(String.init) ?? "none") timeout=\(result.timedOut)")
            }
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
        guard status.settings.notifications, let old = lastStatus, old.state != status.state || old.reason != status.reason else { return }
        let content = UNMutableNotificationContent()
        content.title = "Lid Awake"
        content.body = status.reason
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [controller] error in
            if let error { controller.appendEvent("Notification error: \(error.localizedDescription)") }
        }
    }

    deinit {
        pendingPowerReconcile?.cancel()
        pendingLidCloseActions?.cancel()
        pendingTemporaryExpiry?.cancel()
        if let powerSourceRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes) }
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}

AgentRuntime().start()
