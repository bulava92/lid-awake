import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt
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

    init() {
        previousLidClosed = controller.readLidClosed()
        controller.rotateLogIfNeeded(LidAwakeController.agentLogFile,
                                     previous: LidAwakeController.agentLogFile.deletingLastPathComponent().appendingPathComponent("agent.log.1"),
                                     maxBytes: 1_048_576)
        controller.appendEvent("Agent started: \(CommandLine.arguments.first ?? "unknown")")
    }

    func start() {
        requestNotificationPermission()
        installLidObserver()
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

    private func evaluatePolicy(force: Bool) {
        do {
            let shouldForce = force || Date().timeIntervalSince(lastForcedApply) >= 300
            let status = try controller.reconcile(forceApply: shouldForce)
            if shouldForce { lastForcedApply = Date() }
            notifyTransitionIfNeeded(status)
            lastStatus = status
        } catch {
            controller.appendEvent("Policy error: \(error.localizedDescription)")
            fputs("lid-awake-agent: \(error.localizedDescription)\n", stderr)
        }
    }

    fileprivate func handleLidStateChange() {
        guard let lidClosed = controller.readLidClosed() else { return }
        defer { previousLidClosed = lidClosed }
        guard previousLidClosed != true, lidClosed else { return }

        evaluatePolicy(force: false)
        guard let status = lastStatus ?? controller.loadStatus(),
              status.settings.requested,
              status.state == .enabled else { return }

        controller.recordLidClose()
        if status.settings.soundOnLidClose {
            if !controller.playLidCloseSound(volumePercent: status.settings.lidCloseSoundVolume) {
                controller.appendEvent("Could not play lid-close sound")
            }
        }
        if status.settings.lockOnLidClose {
            if controller.lockScreen() {
                Thread.sleep(forTimeInterval: 0.3)
                _ = run("/usr/bin/pmset", ["displaysleepnow"])
                controller.appendEvent(L10n.text("Screen locked after lid close", "Экран заблокирован после закрытия крышки"))
            } else {
                controller.appendEvent(L10n.text("Could not lock screen after lid close", "Не удалось заблокировать экран после закрытия крышки"))
            }
        }
    }

    private func requestNotificationPermission() {
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
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}

AgentRuntime().start()
