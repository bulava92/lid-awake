import AppKit
import Foundation
import LidAwakeCore

private let store = AwakeScheduleStore()
private let schedulerPath = "/usr/local/libexec/lid-awake-scheduler"
private func t(_ en: String, _ ru: String) -> String { L10n.text(en, ru) }

private func date(for time: AwakeScheduleTime) -> Date {
    Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? Date()
}

private func scheduleTime(from date: Date) throws -> AwakeScheduleTime {
    let value = Calendar.current.dateComponents([.hour, .minute], from: date)
    return try AwakeScheduleTime(hour: value.hour ?? 0, minute: value.minute ?? 0)
}

private func runScheduler(_ arguments: [String]) {
    guard FileManager.default.isExecutableFile(atPath: schedulerPath) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: schedulerPath)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

final class ScheduleEditorController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var schedule: AwakeSchedule
    private var selectedIndex: Int?
    private var changingSelection = false

    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 530),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    private let enabled = NSButton(checkboxWithTitle: t("Enable schedule", "Использовать расписание"), target: nil, action: nil)
    private let fallback = NSPopUpButton()
    private let table = NSTableView()
    private let ruleEnabled = NSButton(checkboxWithTitle: t("Interval enabled", "Интервал включён"), target: nil, action: nil)
    private var dayButtons: [NSButton] = []
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let mode = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: t("Remove", "Удалить"), target: nil, action: nil)

    override init() {
        schedule = (try? store.load()) ?? (try! store.defaultSchedule())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if schedule.rules.isEmpty { setEditorEnabled(false) } else { selectRule(0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildUI() {
        window.title = t("Lid Awake Schedule", "Расписание Lid Awake")
        window.minSize = NSSize(width: 760, height: 500)
        window.setFrameAutosaveName("LidAwakeScheduleEditorWindow")

        let root = NSView()
        window.contentView = root

        let title = NSTextField(labelWithString: t("Weekly schedule", "Недельное расписание"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: t(
            "Choose when Lid Awake should keep the Mac active or allow normal sleep.",
            "Выберите, когда Lid Awake должен удерживать Mac активным или разрешать обычный сон."
        ))
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4

        enabled.state = schedule.enabled ? .on : .off
        fallback.addItems(withTitles: [
            t("Allow normal sleep", "Разрешать обычный сон"),
            t("Keep awake", "Удерживать активным"),
            t("Keep manual state", "Сохранять ручной режим")
        ])
        fallback.selectItem(at: schedule.fallback == .off ? 0 : schedule.fallback == .on ? 1 : 2)
        let fallbackRow = NSStackView(views: [NSTextField(labelWithString: t("Outside intervals:", "Вне интервалов:")), fallback])
        fallbackRow.orientation = .horizontal
        fallbackRow.alignment = .centerY
        fallbackRow.spacing = 8
        let settings = NSStackView(views: [enabled, NSView(), fallbackRow])
        settings.orientation = .horizontal
        settings.alignment = .centerY
        let header = NSStackView(views: [heading, settings])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 14

        table.headerView = nil
        table.rowHeight = 48
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table

        let add = NSButton(title: t("Add", "Добавить"), target: self, action: #selector(addRule))
        removeButton.target = self
        removeButton.action = #selector(removeRule)
        let buttons = NSStackView(views: [add, removeButton, NSView()])
        buttons.orientation = .horizontal
        let list = NSStackView(views: [NSTextField(labelWithString: t("Intervals", "Интервалы")), scroll, buttons])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.widthAnchor.constraint(equalToConstant: 285).isActive = true
        scroll.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        buttons.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true

        let editor = buildRuleEditor()
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let content = NSStackView(views: [list, divider, editor])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 18
        editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 390).isActive = true

        status.textColor = .systemRed
        let cancel = NSButton(title: t("Cancel", "Отмена"), target: self, action: #selector(cancel))
        let save = NSButton(title: t("Save", "Сохранить"), target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let footer = NSStackView(views: [status, NSView(), cancel, save])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let main = NSStackView(views: [header, content, footer])
        main.translatesAutoresizingMaskIntoConstraints = false
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 18
        root.addSubview(main)
        header.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        settings.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
    }

    private func buildRuleEditor() -> NSView {
        let view = NSView()
        ruleEnabled.target = self
        ruleEnabled.action = #selector(updateRule)
        let days = NSStackView()
        days.orientation = .horizontal
        days.spacing = 5
        let names = L10n.isRussian ? ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"] : ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        for (index, name) in names.enumerated() {
            let button = NSButton(title: name, target: self, action: #selector(updateRule))
            button.setButtonType(.pushOnPushOff)
            button.tag = index + 1
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            dayButtons.append(button)
            days.addArrangedSubview(button)
        }
        for picker in [startPicker, endPicker] {
            picker.datePickerElements = [.hourMinute]
            picker.datePickerStyle = .textFieldAndStepper
            picker.target = self
            picker.action = #selector(updateRule)
        }
        let times = NSStackView(views: [formGroup(t("Start", "Начало"), startPicker), formGroup(t("End", "Конец"), endPicker)])
        times.orientation = .horizontal
        times.distribution = .fillEqually
        times.spacing = 18
        mode.addItems(withTitles: [t("Keep awake", "Удерживать активным"), t("Allow normal sleep", "Разрешать обычный сон")])
        mode.target = self
        mode.action = #selector(updateRule)
        let hint = NSTextField(wrappingLabelWithString: t(
            "Intervals may cross midnight, for example 23:00–08:00.",
            "Интервалы могут переходить через полночь, например 23:00–08:00."
        ))
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            NSTextField(labelWithString: t("Interval settings", "Параметры интервала")), ruleEnabled,
            NSTextField(labelWithString: t("Days", "Дни недели")), days, times,
            formGroup(t("Action", "Действие"), mode), hint, NSView()
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view.addSubview(stack)
        times.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    private func formGroup(_ title: String, _ control: NSView) -> NSStackView {
        let stack = NSStackView(views: [NSTextField(labelWithString: title), control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int { schedule.rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = schedule.rules[row]
        let id = NSUserInterfaceItemIdentifier("ScheduleRuleCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = id
        let label = cell.textField ?? NSTextField(labelWithString: "")
        if label.superview == nil {
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        label.stringValue = "\(compactDays(rule.days))  \(rule.start.stringValue)–\(rule.end.stringValue)  ·  \(rule.mode == .on ? t("On", "Вкл") : t("Off", "Выкл"))"
        label.textColor = rule.enabled ? .labelColor : .secondaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !changingSelection, table.selectedRow >= 0 else { return }
        saveControls(reload: false)
        loadRule(table.selectedRow)
    }

    private func compactDays(_ days: Set<Int>) -> String {
        if days == Set(1...7) { return t("Every day", "Каждый день") }
        if days == Set(1...5) { return t("Mon–Fri", "Пн–Пт") }
        if days == Set([6, 7]) { return t("Sat–Sun", "Сб–Вс") }
        let names = L10n.isRussian ? ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"] : ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        return days.sorted().map { names[$0 - 1] }.joined(separator: ",")
    }

    private func selectRule(_ index: Int) {
        changingSelection = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        changingSelection = false
        loadRule(index)
    }

    private func loadRule(_ index: Int) {
        guard schedule.rules.indices.contains(index) else { return }
        selectedIndex = index
        let rule = schedule.rules[index]
        ruleEnabled.state = rule.enabled ? .on : .off
        for button in dayButtons { button.state = rule.days.contains(button.tag) ? .on : .off }
        startPicker.dateValue = date(for: rule.start)
        endPicker.dateValue = date(for: rule.end)
        mode.selectItem(at: rule.mode == .on ? 0 : 1)
        setEditorEnabled(true)
    }

    private func setEditorEnabled(_ value: Bool) {
        [ruleEnabled, startPicker, endPicker, mode].forEach { $0.isEnabled = value }
        dayButtons.forEach { $0.isEnabled = value }
        removeButton.isEnabled = value
    }

    private func saveControls(reload: Bool = true) {
        guard let index = selectedIndex, schedule.rules.indices.contains(index) else { return }
        let days = Set(dayButtons.filter { $0.state == .on }.map(\.tag))
        guard !days.isEmpty,
              let start = try? scheduleTime(from: startPicker.dateValue),
              let end = try? scheduleTime(from: endPicker.dateValue), start != end else { return }
        schedule.rules[index].enabled = ruleEnabled.state == .on
        schedule.rules[index].days = days
        schedule.rules[index].start = start
        schedule.rules[index].end = end
        schedule.rules[index].mode = mode.indexOfSelectedItem == 0 ? .on : .off
        if reload { table.reloadData() }
    }

    @objc private func updateRule() { saveControls() }

    @objc private func addRule() {
        guard let rule = try? AwakeScheduleRule(days: Set(1...7), start: AwakeScheduleTime("09:00"), end: AwakeScheduleTime("18:00"), mode: .on) else { return }
        schedule.rules.append(rule)
        table.reloadData()
        selectRule(schedule.rules.count - 1)
    }

    @objc private func removeRule() {
        guard let index = selectedIndex, schedule.rules.indices.contains(index) else { return }
        schedule.rules.remove(at: index)
        table.reloadData()
        if schedule.rules.isEmpty { selectedIndex = nil; setEditorEnabled(false) }
        else { selectRule(min(index, schedule.rules.count - 1)) }
    }

    @objc private func save() {
        saveControls()
        schedule.enabled = enabled.state == .on
        schedule.fallback = fallback.indexOfSelectedItem == 0 ? .off : fallback.indexOfSelectedItem == 1 ? .on : .manual
        do {
            try store.save(schedule)
            store.clearManualOverride()
            runScheduler(["apply"])
            NSApp.terminate(nil)
        } catch let error as AwakeScheduleError {
            status.stringValue = L10n.isRussian ? "Ошибка расписания: \(error.description)" : "Schedule error: \(error.description)"
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func cancel() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = ScheduleEditorController()
app.delegate = delegate
app.run()
