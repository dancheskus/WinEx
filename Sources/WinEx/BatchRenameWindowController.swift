import AppKit

/// «Переименовать N объектов» (F2 / «Переименовать» with several items selected): a few fixed
/// steps above, the names «Было → Станет» below, updated on every key typed. Names that can't be
/// given are red, with the reason, and the button stays off until there are none.
final class BatchRenameWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                         NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static var open: [BatchRenameWindowController] = []
    /// The rules of the last renaming («Как в прошлый раз»).
    private static let rulesKey = "BatchRenameRules"
    private static let presetsKey = "BatchRenamePresets"

    static var lastRules: BatchRenameRules? {
        AppDefaults.store.data(forKey: rulesKey).flatMap { try? JSONDecoder().decode(BatchRenameRules.self, from: $0) }
    }

    static var presets: [BatchRenameRules.Preset] {
        get { AppDefaults.store.data(forKey: presetsKey).flatMap { try? JSONDecoder().decode([BatchRenameRules.Preset].self, from: $0) } ?? [] }
        set { AppDefaults.store.set(try? JSONEncoder().encode(newValue), forKey: presetsKey) }
    }

    /// `done` gets the items renamed (old URL → new URL), once they are.
    static func show(for items: [BatchRename.Item], done: @escaping ([(from: URL, to: URL)]) -> Void) {
        guard items.count > 1 else { return }
        let controller = BatchRenameWindowController(items: items, done: done)
        open.append(controller)
        let mouse = NSEvent.mouseLocation
        let screen = NSApp.keyWindow?.screen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let window = controller.window, let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2 + 60))
        }
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.findField)
        #if DEBUG
        debugLast = controller
        #endif
    }

    private let items: [BatchRename.Item]
    private let existing: [String: Set<String>]
    private let done: ([(from: URL, to: URL)]) -> Void
    /// Opens empty; a preset or «Как в прошлый раз» fills it.
    private var rules = BatchRenameRules()
    /// The preset applied last (the menu offers to update, rename or delete it).
    private var presetName: String?
    private var outcomes: [BatchRename.Outcome] = []
    private var isRenaming = false

    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let matchCase = NSButton(checkboxWithTitle: L("Различать заглавные"), target: nil, action: nil)
    private let removeNumbers = NSButton(checkboxWithTitle: L("Убрать номера, которые уже есть в именах"), target: nil, action: nil)
    private let newNameField = NSTextField()
    private let prefixField = NSTextField()
    private let suffixField = NSTextField()
    private let numbering = NSPopUpButton()
    private let startField = NSTextField()
    private let digits = NSPopUpButton()
    private let separator = NSPopUpButton()
    private let textCase = NSPopUpButton()
    private let presetsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let resetButton = NSButton(title: L("Очистить"), target: nil, action: nil)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let renameButton = NSButton(title: L("Переименовать"), target: nil, action: nil)

    private init(items: [BatchRename.Item], done: @escaping ([(from: URL, to: URL)]) -> Void) {
        self.items = items
        self.done = done
        existing = BatchRename.existingNames(for: items)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("Переименовать %@ %@", items.count, plural(items.count, "объект", "объекта", "объектов"))
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        build()
        show(rules)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        for field in [findField, replaceField, newNameField, prefixField, suffixField, startField] {
            field.delegate = self
            field.lineBreakMode = .byClipping
            field.cell?.isScrollable = true
        }
        findField.placeholderString = L("Что найти")
        replaceField.placeholderString = L("На что (пусто — убрать)")
        newNameField.placeholderString = L("Одно имя для всех, например «Отпуск»")
        prefixField.placeholderString = L("Текст в начале")
        suffixField.placeholderString = L("Текст в конце")
        startField.formatter = {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = 0
            formatter.maximum = 999_999
            return formatter
        }()
        startField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        fill(numbering, [L("Нет"), L("В начале"), L("В конце")])
        // (Titles show examples; they follow the count and where the number goes: see `update`)
        fill(digits, ["", "1, 2, 3", "01, 02, 03", "001, 002, 003", "0001, 0002, 0003"])
        fill(separator, ["", "", "", ""])
        fill(textCase, [L("Как есть"), L("все строчные"), L("ВСЕ ЗАГЛАВНЫЕ"), L("Каждое Слово С Заглавной"), L("Первая заглавная")])
        for control in [matchCase, removeNumbers, numbering, digits, separator, textCase] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.spacing = 8
            return stack
        }
        let to = NSTextField(labelWithString: L("на"))
        let from = NSTextField(labelWithString: L("с"))
        presetsButton.menu?.delegate = self
        presetsButton.addItem(withTitle: L("Шаблоны"))
        resetButton.target = self
        resetButton.action = #selector(reset(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [textCase, presetsButton, resetButton] { view.setContentHuggingPriority(.defaultHigh, for: .horizontal) }

        let grid = NSGridView(views: [
            [label(L("Заменить:")), row([findField, to, replaceField, matchCase])],
            [label(L("Новое имя:")), newNameField],
            [label(L("Добавить:")), row([prefixField, suffixField])],
            [label(L("Нумерация:")), row([numbering, from, startField, digits, separator])],
            [NSGridCell.emptyContentView, removeNumbers],
            [label(L("Буквы:")), row([textCase, spacer, presetsButton, resetButton])],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for field in [findField, replaceField, prefixField, suffixField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }
        findField.widthAnchor.constraint(equalTo: replaceField.widthAnchor).isActive = true
        prefixField.widthAnchor.constraint(equalTo: suffixField.widthAnchor).isActive = true

        for (id, title) in [("old", L("Было")), ("new", L("Станет"))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.rowHeight = 24
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        // Its own line above the buttons, the whole width: every reason a name can't be given fits
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = 0
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: L("Отменить"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        renameButton.target = self
        renameButton.action = #selector(rename(_:))
        renameButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, renameButton])
        buttons.spacing = 8

        for view in [grid, scroll, status, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private func fill(_ popup: NSPopUpButton, _ titles: [String]) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
    }

    // MARK: Rules ⇄ controls

    private func show(_ rules: BatchRenameRules) {
        findField.stringValue = rules.find
        replaceField.stringValue = rules.replaceWith
        matchCase.state = rules.matchCase ? .on : .off
        removeNumbers.state = rules.removeNumbers ? .on : .off
        newNameField.stringValue = rules.newName
        prefixField.stringValue = rules.prefix
        suffixField.stringValue = rules.suffix
        numbering.selectItem(at: BatchRenameRules.Numbering.allCases.firstIndex(of: rules.numbering) ?? 0)
        startField.stringValue = String(rules.startNumber)
        digits.selectItem(at: min(max(rules.digits, 0), 4))
        separator.selectItem(at: BatchRenameRules.Separator.allCases.firstIndex(of: rules.separator) ?? 0)
        textCase.selectItem(at: BatchRenameRules.Case.allCases.firstIndex(of: rules.textCase) ?? 0)
    }

    private func readRules() {
        rules.find = findField.stringValue
        rules.replaceWith = replaceField.stringValue
        rules.matchCase = matchCase.state == .on
        rules.removeNumbers = removeNumbers.state == .on
        rules.newName = newNameField.stringValue
        rules.prefix = prefixField.stringValue
        rules.suffix = suffixField.stringValue
        rules.numbering = BatchRenameRules.Numbering.allCases[max(numbering.indexOfSelectedItem, 0)]
        rules.startNumber = Int(startField.stringValue.filter(\.isNumber)) ?? 1
        rules.digits = max(digits.indexOfSelectedItem, 0)
        rules.separator = BatchRenameRules.Separator.allCases[max(separator.indexOfSelectedItem, 0)]
        rules.textCase = BatchRenameRules.Case.allCases[max(textCase.indexOfSelectedItem, 0)]
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    @objc private func controlChanged(_ sender: Any?) { update() }

    private func update() {
        readRules()
        outcomes = BatchRename.preview(items, rules: rules, existing: existing)
        // «Новое имя» replaces the whole name: nothing left to find in it
        let replacing = rules.newName.isEmpty
        for control in [findField, replaceField, matchCase] as [NSControl] { control.isEnabled = replacing }
        let numbered = rules.numbering != .off
        for control in [startField, digits, separator] as [NSControl] { control.isEnabled = numbered }
        showExamples()
        table.reloadData()

        let problems = outcomes.filter { $0.problem != nil }.count
        let changing = outcomes.filter(\.changes).count
        if problems > 0 {
            // Each reason once, in the order the names show them
            var reasons: [String] = []
            for outcome in outcomes { if outcome.problem != nil, !reasons.contains(reason(outcome.problem)) { reasons.append(reason(outcome.problem)) } }
            status.stringValue = L("Нельзя переименовать %@ %@: %@", problems, plural(problems, "объект", "объекта", "объектов"),
                                   reasons.joined(separator: "; "))
            status.textColor = .systemRed
        } else if changing == 0 {
            status.stringValue = L("Пока имена не меняются")
            status.textColor = .secondaryLabelColor
        } else {
            status.stringValue = L("Будут переименованы: %@ из %@", changing, outcomes.count)
            status.textColor = .secondaryLabelColor
        }
        renameButton.isEnabled = problems == 0 && changing > 0 && !isRenaming
    }

    private func reason(_ problem: BatchRename.Problem?) -> String {
        switch problem {
        case .empty: L("имя получается пустым")
        case .invalidCharacters: L("в имени нельзя «/» и «:»")
        case .hidden: L("имя с точки в начале — файл станет невидимым")
        case .tooLong: L("слишком длинное имя")
        case .duplicate: rules.numbering == .off ? L("имена повторяются — включите нумерацию") : L("имена повторяются")
        case .exists: L("такое имя уже есть в папке")
        case nil: ""
        }
    }

    /// The number's examples as it will be: "01, 02 … 12" for twelve, "«1 Имя»" when it goes first.
    private func showExamples() {
        let last = rules.startNumber + max(items.count - 1, 0)
        let width = String(last).count
        func padded(_ n: Int) -> String { String(repeating: "0", count: max(width - String(n).count, 0)) + String(n) }
        digits.item(at: 0)?.title = L("Авто: %@", "\(padded(rules.startNumber)), \(padded(rules.startNumber + 1)) … \(padded(last))")
        let first = rules.numbering == .start
        let name = L("Имя")
        func example(_ number: String, _ separator: String) -> String { first ? number + separator + name : name + separator + number }
        separator.item(at: 0)?.title = L("Через пробел: «%@»", example("1", " "))
        separator.item(at: 1)?.title = L("Через «_»: «%@»", example("1", "_"))
        separator.item(at: 2)?.title = L("Через «-»: «%@»", example("1", "-"))
        separator.item(at: 3)?.title = L("В скобках: «%@»", example("(1)", " "))
        // (A popup shows its item's title only when told to)
        for popup in [digits, separator] { popup.synchronizeTitleAndSelectedItem() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { outcomes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, outcomes.indices.contains(row) else { return nil }
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.cell?.wraps = false
            field.cell?.usesSingleLineMode = true
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        guard let field = cell.textField else { return cell }
        let outcome = outcomes[row]
        if id.rawValue == "old" {
            field.attributedStringValue = NSAttributedString(string: outcome.oldName, attributes: [
                .foregroundColor: outcome.changes ? NSColor.labelColor : NSColor.secondaryLabelColor])
        } else {
            field.attributedStringValue = newNameText(outcome)
        }
        field.lineBreakMode = .byTruncatingMiddle   // (setting an attributed string resets it)
        field.toolTip = outcome.problem.map(reason)
        return cell
    }

    /// The new name, its changed part stressed; red when it can't be given (the reason: below the
    /// list and in the tooltip).
    private func newNameText(_ outcome: BatchRename.Outcome) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        guard outcome.changes else {
            return NSAttributedString(string: outcome.newName, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let old = Array(outcome.oldName), new = Array(outcome.newName)
        var head = 0
        while head < min(old.count, new.count), old[head] == new[head] { head += 1 }
        // From the first difference to the extension (which stays)
        let tail = min(outcome.item.isFolder ? 0 : (outcome.newName as NSString).pathExtension.count + 1, new.count - head)
        let color: NSColor = outcome.problem == nil ? .labelColor : .systemRed
        let text = NSMutableAttributedString(string: outcome.newName, attributes: [.font: font, .foregroundColor: color])
        let changed = NSRange(location: String(new[..<head]).utf16.count, length: String(new[head..<(new.count - tail)]).utf16.count)
        text.addAttributes([.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                            .foregroundColor: outcome.problem == nil ? NSColor.controlAccentColor : NSColor.systemRed], range: changed)
        return text
    }

    // MARK: Presets

    func menuNeedsUpdate(_ menu: NSMenu) {
        readRules()
        menu.removeAllItems()
        menu.addItem(withTitle: L("Шаблоны"), action: nil, keyEquivalent: "")   // the pull-down's title
        func item(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            return item
        }
        let presets = Self.presets
        for preset in presets {
            let applied = item(preset.name, #selector(applyPreset(_:)), preset.name)
            applied.state = preset.rules == rules ? .on : .off
            menu.addItem(applied)
        }
        if let last = Self.lastRules {
            if !presets.isEmpty { menu.addItem(.separator()) }
            let lastItem = item(L("Как в прошлый раз"), #selector(applyLast(_:)))
            lastItem.state = last == rules ? .on : .off
            menu.addItem(lastItem)
        }
        if menu.items.count > 1 { menu.addItem(.separator()) }
        let save = item(L("Сохранить как шаблон…"), #selector(savePreset(_:)))
        save.isEnabled = rules != BatchRenameRules()
        menu.addItem(save)
        if let name = presetName, let preset = presets.first(where: { $0.name == name }) {
            let update = item(L("Сохранить изменения в «%@»", name), #selector(updatePreset(_:)))
            update.isEnabled = preset.rules != rules
            menu.addItem(update)
            menu.addItem(item(L("Переименовать «%@»…", name), #selector(renamePreset(_:))))
            menu.addItem(item(L("Удалить «%@»", name), #selector(deletePreset(_:))))
        }
    }

    private func apply(_ rules: BatchRenameRules) {
        show(rules)
        update()
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let preset = Self.presets.first(where: { $0.name == name }) else { return }
        presetName = name
        apply(preset.rules)
    }

    @objc private func applyLast(_ sender: Any?) {
        if let last = Self.lastRules { apply(last) }
    }

    @objc private func reset(_ sender: Any?) {
        presetName = nil
        apply(BatchRenameRules())
        window?.makeFirstResponder(findField)
    }

    @objc private func savePreset(_ sender: Any?) {
        askName(L("Сохранить шаблон"), button: L("Сохранить"), initial: presetName ?? "") { [weak self] name in
            guard let self else { return }
            var presets = Self.presets
            // The same name: replaced
            presets.removeAll { $0.name == name }
            presets.append(BatchRenameRules.Preset(name: name, rules: rules))
            Self.presets = presets
            presetName = name
        }
    }

    @objc private func updatePreset(_ sender: Any?) {
        guard let name = presetName else { return }
        readRules()
        Self.presets = Self.presets.map { $0.name == name ? BatchRenameRules.Preset(name: name, rules: rules) : $0 }
    }

    @objc private func renamePreset(_ sender: Any?) {
        guard let old = presetName else { return }
        askName(L("Переименовать шаблон"), button: L("Переименовать"), initial: old) { [weak self] name in
            var presets = Self.presets.filter { $0.name != name || name == old }
            presets = presets.map { $0.name == old ? BatchRenameRules.Preset(name: name, rules: $0.rules) : $0 }
            Self.presets = presets
            self?.presetName = name
        }
    }

    @objc private func deletePreset(_ sender: Any?) {
        guard let name = presetName else { return }
        Self.presets = Self.presets.filter { $0.name != name }
        presetName = nil
    }

    /// A name typed in a sheet (not empty); `done` gets it.
    private func askName(_ title: String, button: String, initial: String, done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L("Отменить"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = L("Название, например «Фото из отпуска»")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            done(name)
        }
    }

    // MARK: Actions

    @objc private func cancel(_ sender: Any?) { window?.close() }

    @objc private func rename(_ sender: Any?) {
        update()
        guard renameButton.isEnabled else { return }
        // «Как в прошлый раз» gives the numbers seen now: «Авто» kept as the digits it made (01 for
        // ten items), a least — more items still get longer numbers
        var last = rules
        if last.digits == 0, last.numbering != .off {
            let width = String(last.startNumber + max(items.count - 1, 0)).count
            if width <= 4 { last.digits = width }
        }
        AppDefaults.store.set(try? JSONEncoder().encode(last), forKey: Self.rulesKey)
        let pairs = outcomes.filter(\.changes).map { (from: $0.item.url, to: $0.destination) }
        isRenaming = true
        update()
        status.stringValue = L("Переименование…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure: Error?
            do { try BatchRename.perform(pairs); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRenaming = false
                if let failure {
                    self.update()
                    if let window = self.window { NSAlert(error: failure).beginSheetModal(for: window) }
                    return
                }
                FileUndo.recordBatchRename(pairs)
                self.done(pairs)
                self.window?.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    #if DEBUG
    nonisolated(unsafe) static weak var debugLast: BatchRenameWindowController?
    func debugSet(find: String = "", replace: String = "", newName: String = "", prefix: String = "", suffix: String = "",
                  numbering: Int = 0, start: Int = 1, separator: Int = 0, textCase: Int = 0, removeNumbers: Bool = false) {
        self.removeNumbers.state = removeNumbers ? .on : .off
        findField.stringValue = find
        replaceField.stringValue = replace
        newNameField.stringValue = newName
        prefixField.stringValue = prefix
        suffixField.stringValue = suffix
        self.numbering.selectItem(at: numbering)
        startField.stringValue = String(start)
        self.separator.selectItem(at: separator)
        self.textCase.selectItem(at: textCase)
        update()
    }
    var debugState: String { "\(status.stringValue); button \(renameButton.isEnabled ? "on" : "off")" }
    var debugNewNames: [String] { outcomes.map(\.newName) }
    func debugRename() { rename(nil) }
    func debugReset() { reset(nil) }
    func debugApplyLast() { applyLast(nil) }
    func debugSavePreset(_ name: String) {
        readRules()
        Self.presets = Self.presets.filter { $0.name != name } + [BatchRenameRules.Preset(name: name, rules: rules)]
        presetName = name
    }
    func debugApplyPreset(_ name: String) {
        let item = NSMenuItem()
        item.representedObject = name
        applyPreset(item)
    }
    var debugPresetMenu: [String] {
        guard let menu = presetsButton.menu else { return [] }
        menuNeedsUpdate(menu)
        return menu.items.dropFirst().map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓" : "") + $0.title + ($0.isEnabled ? "" : " (off)") }
    }
    #endif
}
