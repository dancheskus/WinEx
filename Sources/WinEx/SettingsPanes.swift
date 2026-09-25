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
        let intro = NSTextField(labelWithString: "Показывать в боковом меню:")
        intro.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        stack.addArrangedSubview(intro)

        heading("Избранное")
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
        stack.addArrangedSubview(SettingsForm.hint("Перетащите папку в «Избранное» боковой панели, чтобы закрепить её; перетаскиванием меняется и порядок."))

        heading("Места")
        for place in SidebarConfig.Place.allCases {
            row(place.title, symbol: place.symbol, on: SidebarConfig.shows(place)) { SidebarConfig.setShows(place, $0) }
        }

        heading("Теги")
        row("Теги", symbol: "tag", on: SidebarConfig.showsTags) { SidebarConfig.showsTags = $0 }
        stack.addArrangedSubview(SettingsForm.hint("Какие именно теги показывать — во вкладке «Теги»."))
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
    private static let colorNames = ["Без цвета", "Серый", "Зелёный", "Лиловый", "Синий", "Жёлтый", "Красный", "Оранжевый"]
    /// Colour popup order, as in Finder's menus.
    private static let colorOrder = [0, 6, 7, 5, 2, 4, 3, 1]

    init() {
        super.init(frame: .zero)
        for (id, title, width) in [("sidebar", "Сбоку", 50.0), ("color", "Цвет", 64.0), ("name", "Тег", 200.0), ("favorite", "Избранный", 96.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.headerToolTip = switch id {
            case "sidebar": "Показывать в боковом меню"
            case "favorite": "Цветной ряд в контекстном меню (как в Finder)"
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

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Новый тег") ?? NSImage(), target: self, action: #selector(addTag(_:)))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Удалить тег")
        removeButton.target = self
        removeButton.action = #selector(removeTag(_:))
        for button in [add, removeButton] {
            button.bezelStyle = .smallSquare
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let buttons = NSStackView(views: [add, removeButton])
        buttons.spacing = 0

        let hint = SettingsForm.hint("«Сбоку» — показывать тег в боковом меню. «Избранный» — кружок в контекстном меню файлов; этот список общий с Finder. Переименование и смена цвета применяются ко всем файлам с тегом.")
        hint.preferredMaxLayoutWidth = SettingsForm.width - 40
        let tint = ClosureCheckbox {
            Settings.tintFoldersByTags = $0
            NotificationCenter.default.post(name: .fileTagsChanged, object: nil)  // redraw the folders
        }
        tint.title = "Оттенять папки цветом тега"
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
        var name = "Новый тег"
        var n = 2
        while names.contains(name) { name = "Новый тег \(n)"; n += 1 }
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
        alert.messageText = "Удалить тег «\(name)»?"
        alert.informativeText = "Тег будет снят со всех файлов, у которых он есть."
        alert.addButton(withTitle: "Удалить тег")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { TagLibrary.delete(name) }
        }
    }
}
