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

        for place in [SidebarConfig.Place.recents, .shared] {
            row(place.title, symbol: place.symbol, on: SidebarConfig.shows(place)) { SidebarConfig.setShows(place, $0) }
        }

        heading(L("Избранное"))
        let favorites = SidebarConfig.favoritePaths
        let standard = SidebarConfig.standardFavorites
        for folder in standard {
            row(folder.title, symbol: folder.symbol, on: favorites.contains(SidebarConfig.key(folder.url))) { on in
                if on { SidebarConfig.restore(folder) } else { SidebarConfig.unpin(folder.url) }
            }
        }
        // Folders the user pinned: switching one off unpins it
        for path in favorites where !standard.contains(where: { SidebarConfig.key($0.url) == path }) {
            let url = SidebarConfig.url(forKey: path)
            row(url.displayName, symbol: "folder", on: true) { on in
                if on { SidebarConfig.pin(url) } else { SidebarConfig.unpin(url) }
            }
        }
        stack.addArrangedSubview(SettingsForm.hint(L("Чтобы закрепить папку, перетащите её в «Избранное» в боковой панели. Порядок тоже меняется перетаскиванием.")))

        heading(L("Места"))
        for place in SidebarConfig.Place.allCases where place != .recents && place != .shared {
            row(place.title, symbol: place.symbol, on: SidebarConfig.shows(place)) { SidebarConfig.setShows(place, $0) }
        }

        heading(L("Теги"))
        row(L("Теги"), symbol: "tag", on: SidebarConfig.showsTags) { SidebarConfig.showsTags = $0 }
        stack.addArrangedSubview(SettingsForm.hint(L("Какие теги показывать, выбирается во вкладке «Теги».")))
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
        let icon = NSImageView(image: SidebarConfig.icon(symbol, pointSize: 14) ?? NSImage())
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
        let list = ListBox(scroll, buttons: [
            ListBox.button("plus", L("Новый тег"), target: self, action: #selector(addTag(_:))),
            ListBox.button("minus", L("Удалить тег"), target: self, action: #selector(removeTag(_:)), into: removeButton),
        ])

        let hint = SettingsForm.hint(L("«Сбоку» — показывать тег в боковом меню. «Избранный» — кружок в контекстном меню файлов, общий с Finder; Finder видит только избранные теги и те, что стоят на файлах, поэтому новый тег сразу избранный. Переименование и смена цвета применяются ко всем файлам с тегом."))
        hint.preferredMaxLayoutWidth = SettingsForm.width - 40
        let tint = ClosureCheckbox {
            Settings.tintFoldersByTags = $0
            NotificationCenter.default.post(name: .fileTagsChanged, object: nil)  // redraw the folders
        }
        tint.title = L("Оттенять папки цветом тега")
        tint.state = Settings.tintFoldersByTags ? .on : .off

        let stack = NSStackView(views: [list, hint, tint])
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
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        // A favourite from the start: Finder lists only its favourites and the tags on files, so a
        // new tag shows up there too (untick «Избранный» to keep it out of the colored row)
        setFavorite(name, true)
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

/// Settings ▸ Программы: the apps of "Открыть с помощью" (which show, for what, in the submenu
/// or the menu itself; apps added) and the entries of "Создать".
final class AppsSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let appsTable = NSTableView()
    private let templatesTable = NSTableView()
    private let removeApp = NSButton()
    private let removeTemplate = NSButton()
    private var shownList: [String] = []
    /// Every app macOS offers to open common kinds of files or folders, and the ones added: the
    /// switched-on ones first, each part by name.
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
        stack.addArrangedSubview(SettingsForm.wideHint(L("Отмеченные программы есть в «Открыть с помощью» (программа по умолчанию — всегда). «В меню» — вместо этого отдельный пункт «Открыть в …» прямо в контекстном меню. «+» — программа, которую macOS сама не предлагает.")))
        setUp(appsTable, columns: [("shown", "", 34), ("app", L("Программа"), 200), ("scope", L("Для"), 170), ("ext", L("Расширения"), 120), ("menu", L("В меню"), 70)])
        appsTable.tableColumn(withIdentifier: .init("menu"))?.headerToolTip = L("Отдельный пункт «Открыть в …» в контекстном меню вместо «Открыть с помощью»")
        stack.addArrangedSubview(list(appsTable, height: 290, add: #selector(addApp(_:)), remove: removeApp, action: #selector(removeApp(_:))))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(Self.heading(L("Создать")))
        stack.addArrangedSubview(SettingsForm.wideHint(L("Что предлагать в меню «Создать». Для своего типа укажите название, имя файла и, если хотите, образец — новые файлы будут его копиями.")))
        setUp(templatesTable, columns: [("on", "", 34), ("title", L("Название"), 210), ("file", L("Имя файла"), 230), ("source", L("Образец"), 110)])
        stack.addArrangedSubview(list(templatesTable, height: 240, add: #selector(addTemplate(_:)), remove: removeTemplate, action: #selector(removeTemplate(_:))))

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            widthAnchor.constraint(equalToConstant: SettingsForm.width),
        ])
        for view in stack.arrangedSubviews where view is ListBox {
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

    private func list(_ table: NSTableView, height: CGFloat, add: Selector, remove: NSButton, action: Selector) -> ListBox {
        ListBox(Self.scroll(table, height: height), buttons: [
            ListBox.button("plus", L("Добавить"), target: self, action: add),
            ListBox.button("minus", L("Удалить"), target: self, action: action, into: remove),
        ])
    }

    private func reload() {
        shownList = AppsConfig.shownApps
        if offered.isEmpty { offered = sortedOffered(Self.allApps()) }
        rows = sortedRows(NewItemTemplate.files.map { ($0, nil) } + AppsConfig.templates.map { (nil, $0) })
        [appsTable, templatesTable].forEach { $0.reloadData() }
        updateButtons()
    }

    private func updateButtons() {
        // Only an app added here goes; the ones macOS offers are just switched off
        removeApp.isEnabled = offered.indices.contains(appsTable.selectedRow) && !AppsConfig.isListed(offered[appsTable.selectedRow])
        removeTemplate.isEnabled = rows.indices.contains(templatesTable.selectedRow) && rows[templatesTable.selectedRow].custom != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === appsTable ? offered.count : rows.count
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
            if view is NSTextField || view is ResettableField { view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -4).isActive = true }
            return holder
        }
    }

    private func cell(_ tableView: NSTableView, _ tableColumn: NSTableColumn?, _ row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        if tableView === appsTable {
            let url = offered[row]
            let shown = shownList.contains(AppsConfig.identity(of: url))
            let app = AppsConfig.config(for: url) ?? AppsConfig.App(path: url.path, scope: AppsConfig.isListed(url) ? .system : .all)
            switch id {
            case "shown": return checkbox(shown, tag: row, action: #selector(toggleOffered(_:)))
            case "app": return appCell(url)
            case "scope":
                let popup = NSPopUpButton()
                popup.isBordered = false
                for scope in AppsConfig.Scope.allCases { popup.addItem(withTitle: scope.title) }
                popup.selectItem(at: AppsConfig.Scope.allCases.firstIndex(of: app.scope) ?? 0)
                popup.target = self
                popup.action = #selector(changeScope(_:))
                popup.isEnabled = shown
                return popup
            case "ext":
                let field = editable(app.extensions.joined(separator: ", "), tag: row, placeholder: L("любые"))
                field.isEnabled = shown && app.scope != .folders
                field.identifier = .init("ext")
                markOwnExtensions(field, app: url, extensions: field.isEnabled ? app.extensions : [])
                return field
            default:
                let box = checkbox(app.inMainMenu, tag: row, action: #selector(toggleInMenu(_:)))
                box.isEnabled = shown
                return box
            }
        }
        let entry = rows[row]
        switch id {
        case "on":
            // The user's own types can be switched off too (kept, not shown in «Создать»)
            return checkbox(!AppsConfig.hiddenTemplates.contains(entry.builtin?.id ?? entry.custom?.id ?? ""), tag: row, action: #selector(toggleTemplate(_:)))
        case "title":
            if let builtin = entry.builtin {
                return ResettableField(editable(builtin.title, tag: row, placeholder: builtin.defaultTitle), identifier: "btitle",
                                       changed: builtin.title != builtin.defaultTitle, original: builtin.defaultTitle,
                                       target: self, reset: #selector(resetTemplateName(_:)))
            }
            let field = editable(entry.custom?.title ?? "", tag: row, placeholder: "")
            field.identifier = .init("title")
            return field
        case "file":
            if let builtin = entry.builtin {
                let field = ResettableField(editable(builtin.fileName, tag: row, placeholder: builtin.defaultFileName), identifier: "bfile",
                                            changed: builtin.fileName != builtin.defaultFileName, original: builtin.defaultFileName,
                                            target: self, reset: #selector(resetTemplateName(_:)))
                if !field.changed { field.field.textColor = .secondaryLabelColor }
                return field
            }
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
            button.toolTip = custom.sourcePath ?? L("Новые файлы будут копиями образца; без него — пустыми")
            return button
        }
    }

    /// Extensions `app` opens anyway (it's their default app) change nothing: «Открыть» already
    /// opens them there, and «Открыть в …» isn't added for them. Struck through, the tooltip says why.
    private func markOwnExtensions(_ field: NSTextField, app: URL, extensions: [String]) {
        let identity = AppsConfig.identity(of: app)
        let own = extensions.filter { ext in
            guard let type = UTType(filenameExtension: ext), let opener = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
            return AppsConfig.identity(of: opener) == identity
        }
        guard !own.isEmpty else { return }
        let text = NSMutableAttributedString(string: field.stringValue, attributes: [.font: field.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                                                                                   .foregroundColor: NSColor.labelColor])
        var start = text.string.startIndex
        for ext in extensions {
            guard let range = text.string.range(of: ext, range: start..<text.string.endIndex) else { continue }
            start = range.upperBound
            guard own.contains(ext) else { continue }
            text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.tertiaryLabelColor],
                               range: NSRange(range, in: text.string))
        }
        field.attributedStringValue = text
        field.toolTip = L("%@ и так открывает %@ по умолчанию: это делает пункт «Открыть», отдельный пункт не нужен.",
                          OpenWithMenu.appName(app), own.map { "." + $0 }.joined(separator: ", "))
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

    /// The list's apps: the ones macOS offers for common items, then the ones added here.
    private static func allApps() -> [URL] {
        var apps = AppsConfig.listedApps()
        for app in AppsConfig.apps where FileManager.default.fileExists(atPath: app.path) && !AppsConfig.isListed(app.url) {
            let identity = AppsConfig.identity(of: app.url)
            if !apps.contains(where: { AppsConfig.identity(of: $0) == identity }) { apps.append(app.url) }
        }
        return apps
    }

    /// An app macOS doesn't offer: on, for files and folders; one already in the list is just
    /// switched on. Either way it's selected and shown.
    @objc private func addApp(_ sender: Any?) {
        chooseApp { [weak self] app in
            guard let self else { return }
            let identity = AppsConfig.identity(of: app)
            if AppsConfig.config(for: app) == nil && !AppsConfig.isListed(app) { AppsConfig.change(app) { _ in } }
            if !AppsConfig.shownApps.contains(identity) { AppsConfig.shownApps += [identity] }
            shownList = AppsConfig.shownApps
            if !offered.contains(where: { AppsConfig.identity(of: $0) == identity }) { offered.append(app) }
            offered = sortedOffered(offered)
            reload()
            if let row = offered.firstIndex(where: { AppsConfig.identity(of: $0) == identity }) {
                appsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                appsTable.scrollRowToVisible(row)
            }
        }
    }

    @objc private func removeApp(_ sender: Any?) {
        guard offered.indices.contains(appsTable.selectedRow) else { return }
        let app = offered[appsTable.selectedRow]
        let identity = AppsConfig.identity(of: app)
        AppsConfig.apps = AppsConfig.apps.filter { AppsConfig.identity(of: $0.url) != identity }
        AppsConfig.shownApps = AppsConfig.shownApps.filter { $0 != identity }
        offered.removeAll { AppsConfig.identity(of: $0) == identity }
        reload()
    }

    @objc private func toggleOffered(_ sender: NSButton) {
        // Rows move, so the row is the checkbox's place now, not its tag
        let row = appsTable.row(for: sender)
        guard offered.indices.contains(row) else { return }
        let identity = AppsConfig.identity(of: offered[row])
        var list = AppsConfig.shownApps.filter { $0 != identity }
        if sender.state == .on { list.append(identity) }
        AppsConfig.shownApps = list
        shownList = list
        // Its other settings only matter when it's on
        appsTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(1..<appsTable.numberOfColumns))
        // The row moves to its place a moment later, once the tick has been seen; several quick
        // clicks move together
        reorderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.moveOfferedRows() }
        reorderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private var reorderWork: DispatchWorkItem?

    private func sortedOffered(_ apps: [URL]) -> [URL] {
        let shown = Set(shownList)
        return apps.sorted { a, b in
            let onA = shown.contains(AppsConfig.identity(of: a)), onB = shown.contains(AppsConfig.identity(of: b))
            if onA != onB { return onA }
            return OpenWithMenu.appName(a).localizedStandardCompare(OpenWithMenu.appName(b)) == .orderedAscending
        }
    }

    /// Slides the rows to the new order (switched-on ones on top) without scrolling the list: the
    /// row clicked glides up or down, the others close up behind it.
    private func moveOfferedRows() {
        let old = offered
        offered = sortedOffered(old)
        Self.slide(appsTable, from: old, to: offered, key: AppsConfig.identity(of:))
    }

    /// Moves `table`'s rows from `items`' order to `target`'s, animated, the list not scrolled.
    /// (The table's data must be in `target`'s order already: it draws the moved rows from it.)
    private static func slide<Item>(_ table: NSTableView, from items: [Item], to target: [Item], key: (Item) -> String) {
        guard target.map(key) != items.map(key) else { return }
        var current = items
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            table.beginUpdates()
            for (index, item) in target.enumerated() where key(current[index]) != key(item) {
                guard let from = current.firstIndex(where: { key($0) == key(item) }) else { continue }
                current.insert(current.remove(at: from), at: index)
                table.moveRow(at: from, to: index)
            }
            table.endUpdates()
        }
    }

    // MARK: «Создать»: the ones switched on first

    private static func templateID(_ row: (builtin: NewItemTemplate?, custom: AppsConfig.Template?)) -> String {
        row.builtin?.id ?? row.custom?.id ?? ""
    }

    /// Switched-on types first, each part in its own order (built-ins, then the user's).
    private func sortedRows(_ list: [(builtin: NewItemTemplate?, custom: AppsConfig.Template?)]) -> [(builtin: NewItemTemplate?, custom: AppsConfig.Template?)] {
        let off = Set(AppsConfig.hiddenTemplates)
        return list.filter { !off.contains(Self.templateID($0)) } + list.filter { off.contains(Self.templateID($0)) }
    }

    private var templateReorderWork: DispatchWorkItem?

    private func templateRow(_ view: NSView) -> Int {
        let row = templatesTable.row(for: view)
        return rows.indices.contains(row) ? row : -1
    }

    /// An app chosen in a sheet on the settings window.
    private func chooseApp(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = L("Выбрать")
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .OK, let url = panel.url { done(url) } }
        }
    }

    @objc private func changeScope(_ sender: NSPopUpButton) {
        let row = appsTable.row(for: sender)
        guard offered.indices.contains(row) else { return }
        AppsConfig.change(offered[row]) { $0.scope = AppsConfig.Scope.allCases[max(0, sender.indexOfSelectedItem)] }
        appsTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<appsTable.numberOfColumns))
    }

    @objc private func toggleInMenu(_ sender: NSButton) {
        let row = appsTable.row(for: sender)
        guard offered.indices.contains(row) else { return }
        AppsConfig.change(offered[row]) { $0.inMainMenu = sender.state == .on }
    }

    @objc private func toggleTemplate(_ sender: NSButton) {
        // Rows move, so the row is the checkbox's place now, not its tag
        let row = templateRow(sender)
        guard row >= 0 else { return }
        let id = Self.templateID(rows[row])
        var off = AppsConfig.hiddenTemplates.filter { $0 != id }
        if sender.state == .off { off.append(id) }
        AppsConfig.hiddenTemplates = off
        // As with the apps: the row moves a moment later, several quick clicks together
        templateReorderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let old = rows
            rows = sortedRows(old)
            Self.slide(templatesTable, from: old, to: rows, key: Self.templateID)
        }
        templateReorderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    @objc private func addTemplate(_ sender: Any?) {
        let template = AppsConfig.Template(title: L("Новый тип"), fileName: L("Новый файл.txt"))
        AppsConfig.templates += [template]
        reload()
        let row = rows.firstIndex { $0.custom?.id == template.id } ?? rows.count - 1
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
        let row = templateRow(sender)
        guard row >= 0, let custom = rows[row].custom else { return }
        let panel = NSOpenPanel()
        // WinEx's folder of sample files (made if it isn't there yet)
        let examples = SettingsBackup.samplesFolder
        try? FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
        panel.directoryURL = examples
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = L("Выбрать")
        panel.message = L("Новые файлы будут копиями образца; без него — пустыми")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.useSample(url, for: custom.id)
            }
        }
    }

    private func useSample(_ url: URL, for id: String) {
        AppsConfig.templates = AppsConfig.templates.map { template in
            guard template.id == id else { return template }
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

    /// The ↺ by a renamed built-in: its own title or file name again.
    @objc private func resetTemplateName(_ sender: NSButton) {
        guard let field = (sender.superview as? ResettableField)?.field, case let row = templateRow(field), row >= 0,
              let builtin = rows[row].builtin else { return }
        if field.identifier?.rawValue == "btitle" {
            AppsConfig.templateTitles[builtin.id] = nil
        } else {
            AppsConfig.templateFileNames[builtin.id] = nil
        }
        reload()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch field.identifier?.rawValue {
        case "ext":
            let row = appsTable.row(for: field)
            guard offered.indices.contains(row) else { return }
            AppsConfig.change(offered[row]) {
                $0.extensions = text.lowercased().split(whereSeparator: { ", ;".contains($0) })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
            }
        case "btitle", "bfile":
            let row = templateRow(field)
            guard row >= 0, let builtin = rows[row].builtin else { return }
            let isTitle = field.identifier?.rawValue == "btitle"
            let original = isTitle ? builtin.defaultTitle : builtin.defaultFileName
            // Empty or the built-in text again: back to the built-in one
            var names = isTitle ? AppsConfig.templateTitles : AppsConfig.templateFileNames
            names[builtin.id] = text.isEmpty || text == original ? nil : text
            if isTitle { AppsConfig.templateTitles = names } else { AppsConfig.templateFileNames = names }
        case "title", "file":
            let row = templateRow(field)
            guard row >= 0, let custom = rows[row].custom, !text.isEmpty else { return reload() }
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

/// Settings ▸ Ограды: the look of every fence (radius, colour, opacity, frosted glass) and how they
/// behave (snapping, quick-hide), with a live preview.
final class FenceSettingsView: NSView {
    private let preview = FencePreview()
    private let radiusSlider = NSSlider(value: Double(FenceStyle.cornerRadius), minValue: 0, maxValue: 24, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: Double(FenceStyle.opacity), minValue: 0.05, maxValue: 0.9, target: nil, action: nil)
    private let colorWell = NSColorWell(style: .minimal)
    private let radiusValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        radiusSlider.target = self
        radiusSlider.action = #selector(radiusChanged(_:))
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        for slider in [radiusSlider, opacitySlider] { slider.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        for label in [radiusValue, opacityValue] {
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        colorWell.color = FenceStyle.nsColor(FenceStyle.color) ?? .black
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))

        // Ready-made tints next to the colour well
        let swatches = NSStackView(views: FenceStyle.presets.map { hex in
            let button = SwatchButton(hex: hex) { [weak self] in
                FenceStyle.color = hex
                self?.colorWell.color = FenceStyle.nsColor(hex) ?? .black
                self?.sync()
            }
            return button
        })
        swatches.spacing = 6
        let colorRow = NSStackView(views: [colorWell, swatches])
        colorRow.spacing = 12

        let enabled = ClosureCheckbox { FenceStyle.enabled = $0 }
        enabled.title = L("Зоны на рабочем столе")
        enabled.state = FenceStyle.enabled ? .on : .off
        let blur = ClosureCheckbox { FenceStyle.blur = $0 }
        blur.title = L("Размытие обоев под зоной")
        blur.state = FenceStyle.blur ? .on : .off
        let snapping = ClosureCheckbox { FenceStyle.snapping = $0 }
        snapping.title = L("Прилипание к краям, зонам и сетке значков")
        snapping.state = FenceStyle.snapping ? .on : .off
        let onGrid = ClosureCheckbox { FenceStyle.onGrid = $0 }
        onGrid.title = L("Зоны по сетке значков")
        onGrid.state = FenceStyle.onGrid ? .on : .off
        let quickHide = ClosureCheckbox { FenceStyle.quickHide = $0 }
        quickHide.title = L("Двойной щелчок по рабочему столу скрывает значки и зоны")
        quickHide.state = FenceStyle.quickHide ? .on : .off

        // Settings on the left, a sample zone beside the look-related rows, snapshots underneath
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        func row(_ label: String?, _ view: NSView) {
            let title = NSTextField(labelWithString: label ?? "")
            title.alignment = .right
            grid.addRow(with: [title, view, NSGridCell.emptyContentView]).rowAlignment = .firstBaseline
        }
        func gap() { grid.addRow(with: [NSGridCell.emptyContentView]).height = 6 }
        row(L("Зоны:"), enabled)
        row(nil, SettingsForm.hint(L("Выключено — все значки снова обычные, зоны и порталы скрыты; включите, и они вернутся.")))
        gap()
        let lookRows = grid.numberOfRows
        row(L("Скругление углов:"), NSStackView(views: [radiusSlider, radiusValue]))
        row(L("Цвет:"), colorRow)
        row(L("Непрозрачность:"), NSStackView(views: [opacitySlider, opacityValue]))
        row(nil, blur)
        grid.cell(atColumnIndex: 2, rowIndex: lookRows).contentView = preview
        grid.mergeCells(inHorizontalRange: NSRange(location: 2, length: 1), verticalRange: NSRange(location: lookRows, length: 4))
        gap()
        row(L("Поведение:"), snapping)
        row(nil, SettingsForm.hint(L("⌘ при перетаскивании временно отключает прилипание.")))
        row(nil, onGrid)
        row(nil, SettingsForm.hint(L("Когда значки выровнены по сетке, зоны занимают её ячейки целиком — без щелей и наездов рядом с ними.")))
        row(nil, quickHide)
        row(nil, SettingsForm.hint(L("Создать зону — правый щелчок по рабочему столу WinEx; там же у каждой зоны свой цвет.")))
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        grid.cell(atColumnIndex: 2, rowIndex: lookRows).yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        snapshots.onResize = { [weak self] in self?.refit() }

        // Without WinEx's desktop there are no zones: everything below is locked, with a way there
        let lockIcon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage())
        lockIcon.contentTintColor = .secondaryLabelColor
        let lockText = NSTextField(wrappingLabelWithString: L("Зоны и снимки работают на рабочем столе WinEx, а он сейчас выключен."))
        lockText.preferredMaxLayoutWidth = 440
        let lockButton = NSButton(title: L("Включить в «Finder»…"), target: self, action: #selector(openFinderTab(_:)))
        let lockRow = NSStackView(views: [lockIcon, lockText, lockButton])
        lockRow.spacing = 10
        lockRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        lockRow.wantsLayer = true
        lockRow.layer?.cornerRadius = 10
        lockRow.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.12).cgColor
        banner = lockRow

        body.wantsLayer = true
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 20
        for view in [grid, separator, snapshots] as [NSView] { body.addArrangedSubview(view) }
        body.setCustomSpacing(16, after: separator)
        blocker.isHidden = true
        let stack = NSStackView(views: [lockRow, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 20, right: 20)
        // Neither stack may squeeze its parts (the grid would spill out of it)
        for view in [stack, body] {
            view.setClippingResistancePriority(.required, for: .vertical)
            view.setHuggingPriority(.required, for: .vertical)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        blocker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(blocker)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsForm.width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            lockRow.widthAnchor.constraint(equalToConstant: SettingsForm.width - 40),
            body.widthAnchor.constraint(equalToConstant: SettingsForm.width - 40),
            separator.widthAnchor.constraint(equalTo: body.widthAnchor),
            snapshots.widthAnchor.constraint(equalTo: body.widthAnchor),
            blocker.topAnchor.constraint(equalTo: body.topAnchor),
            blocker.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            blocker.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            blocker.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: 150),
            preview.heightAnchor.constraint(equalToConstant: 100),
        ])
        sync()
        syncLock()
        observers.add(.replaceFinderChanged) { [weak self] in self?.syncLock() }
    }

    private let body = NSStackView()
    private let snapshots = SnapshotsSection()
    private let blocker = ClickBlocker()
    private var banner: NSView?
    private let observers = Observers()

    /// Locked (dimmed, nothing takes clicks) while WinEx doesn't draw the desktop.
    private func syncLock() {
        let locked = !Settings.replaceFinder
        banner?.isHidden = !locked
        blocker.isHidden = !locked

        func setEnabled(_ view: NSView) {
            (view as? NSControl)?.isEnabled = !locked
            view.subviews.forEach(setEnabled)
        }
        setEnabled(body)
        refit()

    }

    /// The window follows the pane's height (the lock note, the first snapshot).
    private func refit() {
        layoutSubtreeIfNeeded()
        let size = fittingSize
        guard let controller = nextResponder as? NSViewController, controller.preferredContentSize != size else { return }
        controller.preferredContentSize = size
        guard let window, window.contentView === self || superview != nil, !isHiddenOrHasHiddenAncestor else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    @objc private func openFinderTab(_ sender: Any?) {
        AppDelegate.shared.showSettings(tab: .finder)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func sync() {
        radiusValue.stringValue = "\(Int(FenceStyle.cornerRadius)) pt"
        opacityValue.stringValue = "\(Int((FenceStyle.opacity * 100).rounded())) %"
        preview.needsDisplay = true
    }

    @objc private func radiusChanged(_ sender: NSSlider) { FenceStyle.cornerRadius = CGFloat(sender.doubleValue.rounded()); sync() }
    @objc private func opacityChanged(_ sender: NSSlider) { FenceStyle.opacity = CGFloat(sender.doubleValue); sync() }
    @objc private func colorChanged(_ sender: NSColorWell) { FenceStyle.color = FenceStyle.hex(sender.color); sync() }
}

/// Covers a locked part of a pane: clicks go nowhere.
private final class ClickBlocker: NSView {
    /// Dims what's under it.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// A fence drawn on a sample of wallpaper, with the current settings.
private final class FencePreview: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let backdrop = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.18, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.42, green: 0.36, blue: 0.30, alpha: 1)])?
            .draw(in: backdrop, angle: 60)
        let fence = bounds.insetBy(dx: 12, dy: 10)
        let radius = min(FenceStyle.cornerRadius, fence.height / 2)
        let shape = NSBezierPath(roundedRect: fence, xRadius: radius, yRadius: radius)
        if FenceStyle.blur {
            NSColor.white.withAlphaComponent(0.08).setFill()
            shape.fill()
        }
        (FenceStyle.nsColor(FenceStyle.color) ?? .black).withAlphaComponent(FenceStyle.opacity).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        shape.stroke()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSRect(x: fence.minX, y: fence.minY, width: fence.width, height: 30).fill()
        NSGraphicsContext.restoreGraphicsState()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        NSAttributedString(string: L("Документы"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]).draw(in: NSRect(x: fence.minX, y: fence.minY + 6, width: fence.width, height: 20))
        let icon = NSWorkspace.shared.icon(for: .folder)
        let fits = max(1, Int((fence.width - 8) / 46))
        let side = (fence.width - CGFloat(fits) * 46) / 2
        for n in 0..<fits {
            icon.draw(in: NSRect(x: fence.minX + side + 6, y: fence.minY + 36, width: 34, height: 34).offsetBy(dx: CGFloat(n) * 46, dy: 0))
        }
    }
}

/// A round colour swatch.
private final class SwatchButton: NSView {
    private let hex: String
    private let action: () -> Void

    init(hex: String, action: @escaping () -> Void) {
        self.hex = hex
        self.action = action
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        toolTip = hex
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        (FenceStyle.nsColor(hex) ?? .black).setFill()
        circle.fill()
        (FenceStyle.color == hex ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.25)).setStroke()
        circle.lineWidth = FenceStyle.color == hex ? 2 : 1
        circle.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        action()
        superview?.subviews.forEach { $0.needsDisplay = true }
    }
}

/// A table cell's text field with a ↺ after it while the text isn't the built-in one.
private final class ResettableField: NSStackView {
    let field: NSTextField
    let changed: Bool

    init(_ field: NSTextField, identifier: String, changed: Bool, original: String, target: AnyObject, reset: Selector) {
        self.field = field
        self.changed = changed
        super.init(frame: .zero)
        field.identifier = .init(identifier)
        spacing = 2
        addArrangedSubview(field)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if changed {
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("Вернуть «%@»", original)) ?? NSImage(),
                                  target: target, action: reset)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = L("Вернуть «%@»", original)
            button.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
