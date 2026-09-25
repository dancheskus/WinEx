import UniformTypeIdentifiers
import AppKit

/// Settings ▸ Боковое меню: what the sidebar lists, like Finder's own list of checkboxes.
final class SidebarSettingsView: NSView {
    private let stack = NSStackView()
    private let observers = Observers()

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            widthAnchor.constraint(equalToConstant: SettingsForm.width),
        ])
        // Pinned by dragging, removed from the sidebar's menu: keep the list current
        observers.add(SidebarConfig.didChange) { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let intro = NSTextField(labelWithString: L("Показывать в боковом меню:"))
        intro.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        stack.addArrangedSubview(intro)

        heading(L("Избранное"))
        let favorites = SidebarConfig.favoritePaths
        let standard = SidebarConfig.standardFavorites
        for folder in standard {
            row(folder.title, symbol: folder.symbol, on: favorites.contains(folder.url.path)) { on in
                if on { SidebarConfig.restore(folder) } else { SidebarConfig.unpin(folder.url) }
            }
        }
        // Folders the user pinned: switching one off unpins it
        for path in favorites where !standard.contains(where: { $0.url.path == path }) {
            let url = URL(fileURLWithPath: path)
            row(url.displayName, symbol: "folder", on: true) { on in
                if on { SidebarConfig.pin(url) } else { SidebarConfig.unpin(url) }
            }
        }
        stack.addArrangedSubview(SettingsForm.hint(L("Перетащите папку в «Избранное» боковой панели, чтобы закрепить её; перетаскиванием меняется и порядок.")))

        heading(L("Места"))
        for place in SidebarConfig.Place.allCases {
            row(place.title, symbol: place.symbol, on: SidebarConfig.shows(place)) { SidebarConfig.setShows(place, $0) }
        }

        heading(L("Теги"))
        row(L("Теги"), symbol: "tag", on: SidebarConfig.showsTags) { SidebarConfig.showsTags = $0 }
        stack.addArrangedSubview(SettingsForm.hint(L("Какие именно теги показывать — во вкладке «Теги».")))
        // A folder pinned or unpinned meanwhile: the window follows the new height
        (nextResponder as? NSViewController)?.preferredContentSize = fittingSize
    }

    private func heading(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews[max(stack.arrangedSubviews.count - 2, 0)])
    }

    /// Checkbox, symbol, title — clicking the title toggles too.
    private func row(_ title: String, symbol: String, on: Bool, _ change: @escaping (Bool) -> Void) {
        let checkbox = ClosureCheckbox(change)
        checkbox.state = on ? .on : .off
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let label = NSTextField(labelWithString: title)
        label.addGestureRecognizer(NSClickGestureRecognizer(target: checkbox, action: #selector(ClosureCheckbox.toggle(_:))))
        let line = NSStackView(views: [checkbox, icon, label])
        line.spacing = 6
        stack.addArrangedSubview(line)
        line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
    }
}

/// A checkbox that reports its new state to a closure.
private final class ClosureCheckbox: NSButton {
    private var change: ((Bool) -> Void)?

    convenience init(_ change: @escaping (Bool) -> Void) {
        self.init(checkboxWithTitle: "", target: nil, action: nil)
        self.change = change
        target = self
        action = #selector(changed(_:))
    }

    @objc private func changed(_ sender: Any?) {
        change?(state == .on)
    }

    @objc func toggle(_ sender: Any?) {
        state = state == .on ? .off : .on
        changed(sender)
    }
}

/// Settings ▸ Теги: every tag — its colour, its name (renaming changes it on every file), whether
/// the sidebar shows it and whether it's a favourite (the coloured row in context menus, shared
/// with Finder).
final class TagSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let table = NSTableView()
    private let removeButton = NSButton()
    private var entries: [TagLibrary.Entry] = []
    private var favorites: [String] = []
    private let observers = Observers()
    private static let colorNames = [L("Без цвета"), L("Серый"), L("Зелёный"), L("Лиловый"), L("Синий"), L("Жёлтый"), L("Красный"), L("Оранжевый")]
    /// Colour popup order, as in Finder's menus.
    private static let colorOrder = [0, 6, 7, 5, 2, 4, 3, 1]

    init() {
        super.init(frame: .zero)
        for (id, title, width) in [("sidebar", L("Сбоку"), 50.0), ("color", L("Цвет"), 64.0), ("name", L("Тег"), 200.0), ("favorite", L("Избранный"), 96.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.headerToolTip = switch id {
            case "sidebar": L("Показывать в боковом меню")
            case "favorite": L("Цветной ряд в контекстном меню (как в Finder)")
            default: nil
            }
            // The name takes whatever room is left
            column.resizingMask = id == "name" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L("Новый тег")) ?? NSImage(), target: self, action: #selector(addTag(_:)))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: L("Удалить тег"))
        removeButton.target = self
        removeButton.action = #selector(removeTag(_:))
        for button in [add, removeButton] {
            button.bezelStyle = .smallSquare
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let buttons = NSStackView(views: [add, removeButton])
        buttons.spacing = 0

        let hint = SettingsForm.hint(L("«Сбоку» — показывать тег в боковом меню. «Избранный» — кружок в контекстном меню файлов; этот список общий с Finder. Переименование и смена цвета применяются ко всем файлам с тегом."))
        hint.preferredMaxLayoutWidth = SettingsForm.width - 40
        let tint = ClosureCheckbox {
            Settings.tintFoldersByTags = $0
            NotificationCenter.default.post(name: .fileTagsChanged, object: nil)  // redraw the folders
        }
        tint.title = L("Оттенять папки цветом тега")
        tint.state = Settings.tintFoldersByTags ? .on : .off

        let stack = NSStackView(views: [scroll, buttons, hint, tint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 300),
            widthAnchor.constraint(equalToConstant: SettingsForm.width),
        ])
        observers.add(TagLibrary.didChange) { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Also picks up tags from files and changes made in Finder meanwhile.
    func refresh() {
        TagLibrary.merge(TagLibrary.favoriteNames.map { FileTags.tag(named: $0, knownTags: []) })
        TagLibrary.discover()
        reload()
    }

    private func reload() {
        let selected = table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow].name : nil
        entries = TagLibrary.entries
        favorites = TagLibrary.favoriteNames
        table.reloadData()
        if let selected, let row = entries.firstIndex(where: { $0.name == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        removeButton.isEnabled = table.selectedRow >= 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        switch tableColumn?.identifier.rawValue {
        case "sidebar":
            let box = ClosureCheckbox { [weak self] on in self?.update(entry.name) { $0.inSidebar = on } }
            box.state = entry.inSidebar ? .on : .off
            return centered(box)
        case "favorite":
            let box = ClosureCheckbox { [weak self] on in self?.setFavorite(entry.name, on) }
            box.state = favorites.contains(entry.name) ? .on : .off
            return centered(box)
        case "color":
            let popup = NSPopUpButton()
            popup.isBordered = false
            for color in Self.colorOrder {
                popup.addItem(withTitle: "")
                popup.lastItem?.image = FileTags.dotImage(color: color, size: 14)
                popup.lastItem?.toolTip = Self.colorNames[color]
                popup.lastItem?.tag = color
            }
            popup.selectItem(withTag: entry.color)
            popup.target = self
            popup.action = #selector(changeColor(_:))
            popup.identifier = .init(entry.name)
            return centered(popup)
        default:
            let field = NSTextField(string: entry.name)
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.delegate = self
            field.identifier = .init(entry.name)
            field.lineBreakMode = .byTruncatingTail
            let cell = NSTableCellView()
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    private func centered(_ view: NSView) -> NSView {
        let cell = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Changes

    private func update(_ name: String, _ change: (inout TagLibrary.Entry) -> Void) {
        var list = TagLibrary.entries
        guard let index = list.firstIndex(where: { $0.name == name }) else { return }
        change(&list[index])
        TagLibrary.entries = list
    }

    private func setFavorite(_ name: String, _ on: Bool) {
        var names = TagLibrary.favoriteNames.filter { $0 != name }
        if on {
            // Keeps the order of the list
            let order = TagLibrary.entries.map(\.name)
            let rank = order.firstIndex(of: name) ?? order.count
            let index = names.firstIndex { (order.firstIndex(of: $0) ?? order.count) > rank } ?? names.count
            names.insert(name, at: index)
        }
        TagLibrary.favoriteNames = names
    }

    @objc private func changeColor(_ sender: NSPopUpButton) {
        guard let name = sender.identifier?.rawValue, let color = sender.selectedItem?.tag else { return }
        TagLibrary.change(name, to: name, color: color)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let name = field.identifier?.rawValue,
              let entry = TagLibrary.entries.first(where: { $0.name == name }) else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != name else { return field.stringValue = name }
        if TagLibrary.entries.contains(where: { $0.name == newName }) {
            NSSound.beep()
            return field.stringValue = name
        }
        TagLibrary.change(name, to: newName, color: entry.color)
    }

    @objc private func addTag(_ sender: Any?) {
        let names = Set(TagLibrary.entries.map(\.name))
        var name = L("Новый тег")
        var n = 2
        while names.contains(name) { name = L("Новый тег %@", n); n += 1 }
        TagLibrary.entries += [TagLibrary.Entry(name: name, color: 0, inSidebar: true)]
        guard let row = entries.firstIndex(where: { $0.name == name }) else { return }
        table.scrollRowToVisible(row)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.editColumn(table.column(withIdentifier: .init("name")), row: row, with: nil, select: true)
    }

    @objc private func removeTag(_ sender: Any?) {
        guard table.selectedRow >= 0, table.selectedRow < entries.count, let window else { return }
        let name = entries[table.selectedRow].name
        let alert = NSAlert()
        alert.messageText = L("Удалить тег «%@»?", name)
        alert.informativeText = L("Тег будет снят со всех файлов, у которых он есть.")
        alert.addButton(withTitle: L("Удалить тег"))
        alert.addButton(withTitle: L("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { TagLibrary.delete(name) }
        }
    }
}

/// Settings ▸ Программы: "Открыть с помощью" (added apps, where they're offered, an item of their
/// own in the context menu; apps left out) and the entries of "Создать".
final class AppsSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let appsTable = NSTableView()
    private let hiddenTable = NSTableView()
    private let templatesTable = NSTableView()
    private let removeApp = NSButton()
    private let removeTemplate = NSButton()
    private var apps: [AppsConfig.App] = []
    private var hiddenList: [String] = []
    /// Every app macOS offers to open common kinds of files or folders, by name.
    private var offered: [URL] = []
    /// Built-ins first (they can only be switched off), then the user's own.
    private var rows: [(builtin: NewItemTemplate?, custom: AppsConfig.Template?)] = []

    init() {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        stack.addArrangedSubview(Self.heading(L("Открыть с помощью")))
        stack.addArrangedSubview(SettingsForm.wideHint(L("Свои программы — для каких объектов и типов файлов их предлагать; «В меню» — отдельный пункт «Открыть в …» в контекстном меню.")))
        setUp(appsTable, columns: [("app", L("Программа"), 205), ("scope", L("Для"), 150), ("ext", L("Расширения"), 140), ("menu", L("В меню"), 90)])
        stack.addArrangedSubview(Self.scroll(appsTable, height: 130))
        stack.addArrangedSubview(buttons(add: #selector(addApp(_:)), remove: removeApp, action: #selector(removeApp(_:))))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(SettingsForm.wideHint(L("Программы, которые macOS предлагает в «Открыть с помощью» (снимите флажок — не предлагать):")))
        setUp(hiddenTable, columns: [("shown", "", 34), ("hidden", L("Программа"), 560)])
        hiddenTable.headerView = nil
        stack.addArrangedSubview(Self.scroll(hiddenTable, height: 200))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(Self.heading(L("Создать")))
        stack.addArrangedSubview(SettingsForm.wideHint(L("Какие файлы предлагать в «Создать ▸». Свой тип — название, имя нового файла с расширением и, если нужно, файл-образец, который будет копироваться.")))
        setUp(templatesTable, columns: [("on", "", 34), ("title", L("Название"), 210), ("file", L("Имя файла"), 230), ("source", L("Образец"), 110)])
        stack.addArrangedSubview(Self.scroll(templatesTable, height: 240))
        stack.addArrangedSubview(buttons(add: #selector(addTemplate(_:)), remove: removeTemplate, action: #selector(removeTemplate(_:))))

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            widthAnchor.constraint(equalToConstant: SettingsForm.width),
        ])
        for view in stack.arrangedSubviews where view is NSScrollView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private static func scroll(_ table: NSTableView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func setUp(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
    }

    private func buttons(add: Selector, remove: NSButton, action: Selector) -> NSView {
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L("Добавить")) ?? NSImage(), target: self, action: add)
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: L("Удалить"))
        remove.target = self
        remove.action = action
        for button in [plus, remove] {
            button.bezelStyle = .smallSquare
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let row = NSStackView(views: [plus, remove])
        row.spacing = 0
        return row
    }

    private func reload() {
        apps = AppsConfig.apps
        hiddenList = AppsConfig.hiddenApps
        if offered.isEmpty { offered = Self.offeredApps() }
        rows = NewItemTemplate.files.map { ($0, nil) } + AppsConfig.templates.map { (nil, $0) }
        [appsTable, hiddenTable, templatesTable].forEach { $0.reloadData() }
        updateButtons()
    }

    private func updateButtons() {
        removeApp.isEnabled = appsTable.selectedRow >= 0
        removeTemplate.isEnabled = rows.indices.contains(templatesTable.selectedRow) && rows[templatesTable.selectedRow].custom != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === appsTable ? apps.count : tableView === hiddenTable ? offered.count : rows.count
    }

    // MARK: Cells

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        cell(tableView, tableColumn, row).map { view in
            // Vertically centred in the row, a little inset
            let holder = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(view)
            let centreX = view is NSButton && (view as? NSButton)?.title.isEmpty == true
            NSLayoutConstraint.activate([
                view.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                centreX ? view.centerXAnchor.constraint(equalTo: holder.centerXAnchor)
                        : view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
                view.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -4),
            ])
            if view is NSTextField { view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -4).isActive = true }
            return holder
        }
    }

    private func cell(_ tableView: NSTableView, _ tableColumn: NSTableColumn?, _ row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        if tableView === hiddenTable {
            let app = offered[row]
            if id == "shown" { return checkbox(!hiddenList.contains(AppsConfig.identity(of: app)), tag: row, action: #selector(toggleOffered(_:))) }
            return appCell(app)
        }
        if tableView === appsTable {
            let app = apps[row]
            switch id {
            case "app": return appCell(app.url)
            case "scope":
                let popup = NSPopUpButton()
                popup.isBordered = false
                for scope in AppsConfig.Scope.allCases { popup.addItem(withTitle: scope.title) }
                popup.selectItem(at: AppsConfig.Scope.allCases.firstIndex(of: app.scope) ?? 0)
                popup.tag = row
                popup.target = self
                popup.action = #selector(changeScope(_:))
                return popup
            case "ext":
                let field = editable(app.extensions.joined(separator: ", "), tag: row, placeholder: L("любые"))
                field.isEnabled = app.scope != .folders
                field.identifier = .init("ext")
                return field
            default:
                return checkbox(app.inMainMenu, tag: row, action: #selector(toggleInMenu(_:)))
            }
        }
        let entry = rows[row]
        switch id {
        case "on":
            let box = checkbox(!AppsConfig.hiddenTemplates.contains(entry.builtin?.id ?? ""), tag: row, action: #selector(toggleTemplate(_:)))
            box.isEnabled = entry.builtin != nil
            return box
        case "title":
            if let builtin = entry.builtin { return label(builtin.title) }
            let field = editable(entry.custom?.title ?? "", tag: row, placeholder: "")
            field.identifier = .init("title")
            return field
        case "file":
            if let builtin = entry.builtin { return label(builtin.fileName, secondary: true) }
            let field = editable(entry.custom?.fileName ?? "", tag: row, placeholder: "")
            field.identifier = .init("file")
            return field
        default:
            guard let custom = entry.custom else { return label(L("пустой"), secondary: true) }
            let button = NSButton(title: custom.sourcePath.map { ($0 as NSString).lastPathComponent } ?? L("Выбрать…"),
                                  target: self, action: #selector(chooseSample(_:)))
            button.isBordered = false
            button.contentTintColor = .linkColor
            button.tag = row
            button.toolTip = custom.sourcePath ?? L("Файл, который будет копироваться; без него создаётся пустой файл")
            return button
        }
    }

    private func appCell(_ url: URL) -> NSView {
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let name = NSTextField(labelWithString: OpenWithMenu.appName(url))
        name.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, name])
        stack.spacing = 6
        return stack
    }

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if secondary { label.textColor = .secondaryLabelColor }
        return label
    }

    private func editable(_ text: String, tag: Int, placeholder: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.placeholderString = placeholder
        field.tag = tag
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func checkbox(_ on: Bool, tag: Int, action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: "", target: self, action: action)
        box.state = on ? .on : .off
        box.tag = tag
        return box
    }

    // MARK: Changes

    @objc private func addApp(_ sender: Any?) {
        guard let app = chooseApp() else { return }
        var list = AppsConfig.apps
        guard !list.contains(where: { $0.path == app.path }) else { return }
        list.append(AppsConfig.App(path: app.path))
        AppsConfig.apps = list
        reload()
    }

    @objc private func removeApp(_ sender: Any?) {
        guard apps.indices.contains(appsTable.selectedRow) else { return }
        var list = apps
        list.remove(at: appsTable.selectedRow)
        AppsConfig.apps = list
        reload()
    }

    @objc private func toggleOffered(_ sender: NSButton) {
        guard offered.indices.contains(sender.tag) else { return }
        let identity = AppsConfig.identity(of: offered[sender.tag])
        var list = AppsConfig.hiddenApps.filter { $0 != identity }
        if sender.state == .off { list.append(identity) }
        AppsConfig.hiddenApps = list
        hiddenList = list
    }

    /// The apps of "Открыть с помощью" for folders and the usual kinds of files (text, documents,
    /// pictures, sound, video, archives, code, web pages), without WinEx, each once.
    private static func offeredApps() -> [URL] {
        let types: [UTType] = [.folder, .plainText, .rtf, .pdf, .image, .png, .jpeg, .movie, .mpeg4Movie, .audio, .mp3,
                               .html, .json, .xml, .zip, .sourceCode, .shellScript, .spreadsheet, .presentation,
                               UTType("org.openxmlformats.wordprocessingml.document"), UTType("net.daringfireball.markdown")].compactMap { $0 }
        var seen = Set<String>()
        var apps: [URL] = []
        for type in types {
            for app in NSWorkspace.shared.urlsForApplications(toOpen: type) {
                let identity = AppsConfig.identity(of: app)
                guard app.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL, seen.insert(identity).inserted else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { OpenWithMenu.appName($0).localizedStandardCompare(OpenWithMenu.appName($1)) == .orderedAscending }
    }

    private func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = L("Выбрать")
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc private func changeScope(_ sender: NSPopUpButton) {
        guard apps.indices.contains(sender.tag) else { return }
        var list = apps
        list[sender.tag].scope = AppsConfig.Scope.allCases[max(0, sender.indexOfSelectedItem)]
        AppsConfig.apps = list
        reload()
    }

    @objc private func toggleInMenu(_ sender: NSButton) {
        guard apps.indices.contains(sender.tag) else { return }
        var list = apps
        list[sender.tag].inMainMenu = sender.state == .on
        AppsConfig.apps = list
        apps = list
    }

    @objc private func toggleTemplate(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), let id = rows[sender.tag].builtin?.id else { return }
        var off = AppsConfig.hiddenTemplates.filter { $0 != id }
        if sender.state == .off { off.append(id) }
        AppsConfig.hiddenTemplates = off
    }

    @objc private func addTemplate(_ sender: Any?) {
        AppsConfig.templates += [AppsConfig.Template(title: L("Новый тип"), fileName: L("Новый файл.txt"))]
        reload()
        let row = rows.count - 1
        templatesTable.scrollRowToVisible(row)
        templatesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        templatesTable.editColumn(templatesTable.column(withIdentifier: .init("title")), row: row, with: nil, select: true)
    }

    @objc private func removeTemplate(_ sender: Any?) {
        guard rows.indices.contains(templatesTable.selectedRow), let custom = rows[templatesTable.selectedRow].custom else { return }
        AppsConfig.templates = AppsConfig.templates.filter { $0.id != custom.id }
        reload()
    }

    @objc private func chooseSample(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), let custom = rows[sender.tag].custom else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = L("Выбрать")
        panel.message = L("Файл, который будет копироваться; без него создаётся пустой файл")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppsConfig.templates = AppsConfig.templates.map { template in
            guard template.id == custom.id else { return template }
            var changed = template
            changed.sourcePath = url.path
            // The new file gets the sample's extension
            if (changed.fileName as NSString).pathExtension.lowercased() != url.pathExtension.lowercased() {
                changed.fileName = ((changed.fileName as NSString).deletingPathExtension as NSString).appendingPathExtension(url.pathExtension) ?? changed.fileName
            }
            return changed
        }
        reload()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch field.identifier?.rawValue {
        case "ext":
            guard apps.indices.contains(field.tag) else { return }
            var list = apps
            list[field.tag].extensions = text.lowercased().split(whereSeparator: { ", ;".contains($0) })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
            AppsConfig.apps = list
        case "title", "file":
            guard rows.indices.contains(field.tag), let custom = rows[field.tag].custom, !text.isEmpty else { return reload() }
            AppsConfig.templates = AppsConfig.templates.map { template in
                guard template.id == custom.id else { return template }
                var changed = template
                if field.identifier?.rawValue == "title" { changed.title = text } else { changed.fileName = text }
                return changed
            }
        default: return
        }
        reload()
    }
}
