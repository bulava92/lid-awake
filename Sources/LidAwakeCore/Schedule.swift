import Foundation

public struct AwakeScheduleTime: Codable, Equatable, Hashable, Sendable, Comparable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw AwakeScheduleError.invalidTime }
        self.hour = hour
        self.minute = minute
    }

    public init(_ value: String) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            throw AwakeScheduleError.invalidTime
        }
        try self.init(hour: hour, minute: minute)
    }

    public var minuteOfDay: Int { hour * 60 + minute }
    public var stringValue: String { String(format: "%02d:%02d", hour, minute) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.minuteOfDay < rhs.minuteOfDay }
}

public enum AwakeScheduleMode: String, Codable, CaseIterable, Sendable {
    case on
    case off
}

public struct AwakeScheduleRule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var enabled: Bool
    public var days: Set<Int>
    public var start: AwakeScheduleTime
    public var end: AwakeScheduleTime
    public var mode: AwakeScheduleMode

    public init(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        days: Set<Int>,
        start: AwakeScheduleTime,
        end: AwakeScheduleTime,
        mode: AwakeScheduleMode
    ) throws {
        guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else { throw AwakeScheduleError.invalidWeekday }
        guard start != end else { throw AwakeScheduleError.zeroLengthInterval }
        self.id = id
        self.enabled = enabled
        self.days = days
        self.start = start
        self.end = end
        self.mode = mode
    }

    public var crossesMidnight: Bool { end < start }
}

public enum AwakeScheduleFallback: String, Codable, CaseIterable, Sendable {
    case off
    case on
    case manual

    public var mode: AwakeScheduleMode? {
        switch self {
        case .off: return .off
        case .on: return .on
        case .manual: return nil
        }
    }
}

public struct AwakeSchedule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var fallback: AwakeScheduleFallback
    public var rules: [AwakeScheduleRule]

    public init(enabled: Bool = false, fallback: AwakeScheduleFallback = .off, rules: [AwakeScheduleRule] = []) {
        self.enabled = enabled
        self.fallback = fallback
        self.rules = rules
    }

    public func validate() throws {
        var occupied = Array(repeating: [Bool](repeating: false, count: 1440), count: 7)
        for rule in rules where rule.enabled {
            guard !rule.days.isEmpty, rule.days.allSatisfy({ (1...7).contains($0) }) else { throw AwakeScheduleError.invalidWeekday }
            guard rule.start != rule.end else { throw AwakeScheduleError.zeroLengthInterval }
            for day in rule.days {
                for (targetDay, minute) in rule.coveredMinutes(startDay: day) {
                    if occupied[targetDay - 1][minute] { throw AwakeScheduleError.overlap(day: targetDay, minute: minute) }
                    occupied[targetDay - 1][minute] = true
                }
            }
        }
    }

    public func mode(at date: Date, calendar: Calendar = .current) -> AwakeScheduleMode? {
        guard enabled else { return nil }
        let weekday = Self.isoWeekday(for: date, calendar: calendar)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return rules.first(where: { $0.enabled && $0.matches(weekday: weekday, minute: minute) })?.mode ?? fallback.mode
    }

    public func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        var candidates: [Date] = []
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let weekday = Self.isoWeekday(for: day, calendar: calendar)
            for rule in rules where rule.enabled && rule.days.contains(weekday) {
                if let start = calendar.date(bySettingHour: rule.start.hour, minute: rule.start.minute, second: 0, of: day), start > date {
                    candidates.append(start)
                }
                let endDay = rule.crossesMidnight ? calendar.date(byAdding: .day, value: 1, to: day) : day
                if let endDay,
                   let end = calendar.date(bySettingHour: rule.end.hour, minute: rule.end.minute, second: 0, of: endDay),
                   end > date {
                    candidates.append(end)
                }
            }
        }
        return candidates.min()
    }

    private static func isoWeekday(for date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }
}

public enum AwakeScheduleError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidTime
    case invalidWeekday
    case zeroLengthInterval
    case overlap(day: Int, minute: Int)

    public var description: String {
        switch self {
        case .invalidTime: return "Time must be in HH:mm format"
        case .invalidWeekday: return "Weekdays must be in the range 1...7"
        case .zeroLengthInterval: return "Schedule interval must not be empty"
        case let .overlap(day, minute): return String(format: "Schedule rules overlap on weekday %d at %02d:%02d", day, minute / 60, minute % 60)
        }
    }
}

public struct AwakeScheduleStore {
    public static var directory: URL { LidAwakeController.supportDirectory.appendingPathComponent("Schedule", isDirectory: true) }
    public static var file: URL { directory.appendingPathComponent("schedule.json") }
    public static var manualOverrideFile: URL { directory.appendingPathComponent("manual-override.json") }

    private struct ManualOverride: Codable {
        let mode: AwakeScheduleMode
        let expiresAt: Date
    }

    public init() {}

    public func defaultSchedule() throws -> AwakeSchedule {
        let allDays = Set(1...7)
        return AwakeSchedule(enabled: false, fallback: .off, rules: [
            try AwakeScheduleRule(id: "day", days: allDays, start: AwakeScheduleTime("08:00"), end: AwakeScheduleTime("23:00"), mode: .on),
            try AwakeScheduleRule(id: "night", days: allDays, start: AwakeScheduleTime("23:00"), end: AwakeScheduleTime("08:00"), mode: .off)
        ])
    }

    public func load(createIfMissing: Bool = true) throws -> AwakeSchedule {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.file.path) {
            let schedule = try defaultSchedule()
            if createIfMissing { try save(schedule) }
            return schedule
        }
        let schedule = try JSONDecoder().decode(AwakeSchedule.self, from: Data(contentsOf: Self.file))
        try schedule.validate()
        return schedule
    }

    public func save(_ schedule: AwakeSchedule) throws {
        try schedule.validate()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(schedule).write(to: Self.file, options: .atomic)
    }

    public func activeManualOverride(now: Date = Date()) -> AwakeScheduleMode? {
        guard let data = try? Data(contentsOf: Self.manualOverrideFile),
              let value = try? JSONDecoder().decode(ManualOverride.self, from: data) else { return nil }
        guard value.expiresAt > now else {
            try? FileManager.default.removeItem(at: Self.manualOverrideFile)
            return nil
        }
        return value.mode
    }

    public func recordManualOverride(_ mode: AwakeScheduleMode, now: Date = Date()) {
        guard let schedule = try? load(), schedule.enabled,
              let boundary = schedule.nextBoundary(after: now) else {
            clearManualOverride()
            return
        }
        let value = ManualOverride(mode: mode, expiresAt: boundary)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: Self.manualOverrideFile, options: .atomic)
    }

    public func clearManualOverride() {
        try? FileManager.default.removeItem(at: Self.manualOverrideFile)
    }
}

private extension AwakeScheduleRule {
    func matches(weekday: Int, minute: Int) -> Bool {
        if !crossesMidnight { return days.contains(weekday) && minute >= start.minuteOfDay && minute < end.minuteOfDay }
        if days.contains(weekday), minute >= start.minuteOfDay { return true }
        let previousDay = weekday == 1 ? 7 : weekday - 1
        return days.contains(previousDay) && minute < end.minuteOfDay
    }

    func coveredMinutes(startDay: Int) -> [(Int, Int)] {
        if !crossesMidnight { return (start.minuteOfDay..<end.minuteOfDay).map { (startDay, $0) } }
        let nextDay = startDay == 7 ? 1 : startDay + 1
        return (start.minuteOfDay..<1440).map { (startDay, $0) } + (0..<end.minuteOfDay).map { (nextDay, $0) }
    }
}
