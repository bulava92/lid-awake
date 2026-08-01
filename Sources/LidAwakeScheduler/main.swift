import AppKit
import Foundation
import LidAwakeCore

private struct ScheduleStatus: Codable {
    let enabled: Bool
    let mode: AwakeScheduleMode?
    let nextBoundary: Date?
    let deferredByTemporaryMode: Bool
}

private let store = AwakeScheduleStore()
private let controller = LidAwakeController()

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func temporaryModeIsActive(now: Date = Date()) -> Bool {
    let settings = controller.loadSettings()
    guard settings.requested, let expiry = settings.expiresAt else { return false }
    return expiry > now
}

private func status(now: Date = Date()) throws -> ScheduleStatus {
    let schedule = try store.load()
    let manual = store.activeManualOverride(now: now)
    return ScheduleStatus(
        enabled: schedule.enabled,
        mode: manual ?? schedule.mode(at: now),
        nextBoundary: schedule.nextBoundary(after: now),
        deferredByTemporaryMode: temporaryModeIsActive(now: now)
    )
}

@discardableResult
private func apply(now: Date = Date()) throws -> Bool {
    let current = try status(now: now)
    guard current.enabled, !current.deferredByTemporaryMode, let mode = current.mode else { return false }
    let settings = controller.loadSettings()
    let requested = mode == .on
    guard settings.requested != requested || settings.expiresAt != nil else { return false }
    if requested { try controller.requestEnabled(recordScheduleOverride: false) }
    else { try controller.requestDisabled(recordScheduleOverride: false) }
    return true
}

private func setEnabled(_ enabled: Bool) throws {
    var schedule = try store.load()
    schedule.enabled = enabled
    try store.save(schedule)
    store.clearManualOverride()
    if enabled { _ = try apply() }
}

private func printStatus(_ value: ScheduleStatus) {
    print("enabled: \(value.enabled)")
    print("mode: \(value.mode?.rawValue ?? "manual")")
    print("temporary-mode: \(value.deferredByTemporaryMode ? "active" : "inactive")")
    if let boundary = value.nextBoundary { print("next: \(ISO8601DateFormatter().string(from: boundary))") }
}

private final class ScheduleRunLoop {
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.applyAndSchedule() },
            center.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.applyAndSchedule() },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.applyAndSchedule() }
        ]
        applyAndSchedule()
    }

    private func applyAndSchedule() {
        _ = try? apply()
        let current = try? status()
        let delay: TimeInterval
        if current?.deferredByTemporaryMode == true {
            delay = 2
        } else if let boundary = current?.nextBoundary {
            delay = max(1, min(boundary.timeIntervalSinceNow + 0.5, 60))
        } else {
            delay = 60
        }
        timer?.invalidate()
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.applyAndSchedule() }
        timer = next
        RunLoop.current.add(next, forMode: .common)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        timer?.invalidate()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "status"

do {
    switch command {
    case "init-default":
        _ = try store.load()
        print(AwakeScheduleStore.file.path)
    case "show":
        let data = try JSONEncoder().encode(store.load())
        print(String(data: data, encoding: .utf8) ?? "{}")
    case "validate":
        try store.load().validate()
        print("valid")
    case "status": printStatus(try status())
    case "apply": _ = try apply()
    case "enable": try setEnabled(true)
    case "disable": try setEnabled(false)
    case "next":
        if let date = try store.load().nextBoundary(after: Date()) { print(ISO8601DateFormatter().string(from: date)) }
    case "run":
        let loop = ScheduleRunLoop()
        loop.start()
        RunLoop.current.run()
    default:
        fail("Usage: lid-awake-scheduler init-default|show|validate|status|apply|enable|disable|next|run", code: 64)
    }
} catch let error as AwakeScheduleError {
    fail(error.description, code: 78)
} catch {
    fail(error.localizedDescription)
}
