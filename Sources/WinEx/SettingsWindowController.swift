import AppKit

/// Settings, the way Mac apps lay them out: tabs in the toolbar, each a short form
/// ("label: control", labels right-aligned in one column); explanations in "?" popovers.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int { case general, sidebar, tags, finder, keyboard, access, updates }

    private let tabs = NSTabViewController()
    private let tagsView = TagSettingsView()
    // Основные
    private let startPopup = NSPopUpButton()
    private let hotKeyPopup = NSPopUpButton()
    private let hotKeyHint = SettingsForm.hint("")
    private let hiddenCheckbox = NSButton(checkboxWithTitle: "Показывать скрытые файлы", target: nil, action: nil)
    private let commandBarCheckbox = NSButton(checkboxWithTitle: "Панель команд под адресной строкой", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Открывать WinEx при входе в систему", target: nil, action: nil)
    private let loginHint = SettingsForm.hint("")
    private let loginApproveButton = NSButton(title: "Открыть «Объекты входа»…", target: nil, action: nil)
    // Finder и рабочий стол
    private let replaceCheckbox = NSButton(checkboxWithTitle: "Использовать WinEx вместо Finder", target: nil, action: nil)
    private let resetDesktopButton = NSButton(title: "Сбросить рабочий стол как в Finder…", target: nil, action: nil)
    // Клавиатура
    private let windowsKeysCheckbox = NSButton(checkboxWithTitle: "Клавиши как в Windows", target: nil, action: nil)
    // Доступ
    private let accessIcon = NSImageView()
    private let accessTitle = NSTextField(labelWithString: "")
    private let accessHint = SettingsForm.hint("")
    private let accessButton = NSButton(title: "Открыть настройки «Полный доступ к диску»…", target: nil, action: nil)
    // Обновления
    private let updatesCheckbox = NSButton(checkboxWithTitle: "Проверять обновления автоматически", target: nil, action: nil)

    private static let startChoices: [(id: String, title: String)] = [
        ("home", "Домашняя папка"), ("desktop", "Рабочий стол"), ("downloads", "Загрузки"),
        ("documents", "Документы"), ("computer", "Этот Mac"),
    ]

    private let observers = Observers()

    init() {
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Настройки WinEx"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)

        for (title, symbol, view) in [
            ("Основные", "gearshape", generalPane()),
            ("Боковое меню", "sidebar.left", SidebarSettingsView()),
            ("Теги", "tag", tagsView),
            ("Finder", "macwindow.on.rectangle", finderPane()),
            ("Клавиатура", "keyboard", keyboardPane()),
            ("Доступ", "lock.shield", accessPane()),
            ("Обновления", "arrow.triangle.2.circlepath", updatesPane()),
        ] {
            let controller = NSViewController()
            controller.view = view
            controller.title = title
            controller.preferredContentSize = view.fittingSize
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.center()
        // Back from System Settings: show whether access was granted meanwhile
        observers.add(NSApplication.didBecomeActiveNotification) { [weak self] in self?.syncAccess() }
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Panes

    private func generalPane() -> NSView {
        startPopup.target = self
        startPopup.action = #selector(changeStartFolder(_:))
        for preset in GlobalHotKey.Preset.allCases { hotKeyPopup.addItem(withTitle: preset.title) }
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(changeHotKey(_:))
        hiddenCheckbox.target = self
        hiddenCheckbox.action = #selector(toggleHidden(_:))
        commandBarCheckbox.target = self
        commandBarCheckbox.action = #selector(toggleCommandBar(_:))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin(_:))
        loginApproveButton.target = self
        loginApproveButton.action = #selector(openLoginItems(_:))
        loginApproveButton.controlSize = .small
        return SettingsForm.build([
            .row("Новые окна открываются в:", startPopup),
            .row("Окно WinEx из любой программы:", hotKeyPopup),
            .row(nil, hotKeyHint),
            .gap,
            .row("Показ:", hiddenCheckbox),
            .row(nil, commandBarCheckbox),
            .row("Запуск:", loginCheckbox),
            .row(nil, loginHint),
            .row(nil, loginApproveButton),
        ])
    }

    private func finderPane() -> NSView {
        replaceCheckbox.target = self
        replaceCheckbox.action = #selector(toggleReplace(_:))
        resetDesktopButton.target = self
        resetDesktopButton.action = #selector(resetDesktop(_:))
        let help = SettingsForm.helpButton("""
            Когда WinEx заменяет Finder:
            • рабочий стол рисует WinEx, папки с него открываются в WinEx;
            • «Показать в Finder» в других программах показывает файл в WinEx;
            • папки, которые другие программы открывают сами, по-прежнему открываются в Finder — macOS не даёт сменить программу для папок;
            • «Выйти» в строке меню возвращает всё Finder.
            """)
        let replaceRow = NSStackView(views: [replaceCheckbox, help])
        replaceRow.spacing = 6
        return SettingsForm.build([
            .row("Рабочий стол:", replaceRow),
            .row(nil, SettingsForm.hint("Рабочий стол и «Показать в Finder» переходят к WinEx. «Выйти» в строке меню возвращает Finder.")),
            .gap,
            .row("Значки:", resetDesktopButton),
            .row(nil, SettingsForm.hint("Расставить значки, их размер и сортировку так, как у Finder.")),
        ])
    }

    private func keyboardPane() -> NSView {
        windowsKeysCheckbox.target = self
        windowsKeysCheckbox.action = #selector(toggleWindowsKeys(_:))
        return SettingsForm.build([
            .row("Клавиши:", windowsKeysCheckbox),
            .row(nil, SettingsForm.hint("Выключено — как в Finder: Enter переименовывает, ⌘↓ или ⌘O открывают, ⌘↑ — вверх.")),
            .gap,
            .row(nil, SettingsForm.keyTable(title: "С «Клавишами как в Windows»", [
                ("Enter", "открыть"), ("F2", "переименовать"), ("Backspace, ⌥↑", "на уровень выше"),
                ("⌥←  ⌥→", "назад / вперёд"), ("F3", "поиск"), ("F4, ⌥D", "адресная строка"), ("F5", "обновить"),
                ("F11", "полный экран"), ("Delete", "в Корзину"), ("⇧Delete", "удалить навсегда"), ("⇧F10", "контекстное меню"),
            ])),
            .gap,
            .row(nil, SettingsForm.keyTable(title: "Всегда", [
                ("⌃Tab, ⌃⇧Tab", "следующая / предыдущая вкладка"), ("⌃1 … ⌃9", "вкладка по номеру"),
                ("⌘ + перетащить", "переместить"), ("⌥ + перетащить", "копировать"), ("⌘⌥ + перетащить", "создать псевдоним"),
            ])),
        ])
    }

    private func accessPane() -> NSView {
        accessTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        accessIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        accessButton.target = self
        accessButton.action = #selector(openFullDiskAccess(_:))
        let status = NSStackView(views: [accessIcon, accessTitle])
        status.spacing = 6
        return SettingsForm.build([
            .row("Полный доступ к диску:", status),
            .row(nil, accessHint),
            .row(nil, accessButton),
        ])
    }

    private func updatesPane() -> NSView {
        updatesCheckbox.target = self
        updatesCheckbox.action = #selector(toggleUpdates(_:))
        let checkNow = NSButton(title: "Проверить сейчас", target: AppDelegate.shared, action: #selector(AppDelegate.checkForUpdates(_:)))
        let releases = NSButton(title: "Страница релизов…", target: self, action: #selector(openReleases(_:)))
        let version = NSTextField(labelWithString: Updater.shared.currentVersion + (Updater.shared.isDevBuild ? " (своя сборка)" : ""))
        return SettingsForm.build([
            .row("Версия:", version),
            .row("Обновления:", updatesCheckbox),
            .row(nil, SettingsForm.hint(Updater.shared.isDevBuild
                ? "Своя сборка сама не обновляется — только по кнопке «Проверить сейчас»."
                : "Раз в сутки WinEx проверяет новые версии и предлагает обновиться. Разрешения сохраняются.")),
            .row(nil, NSStackView(views: [checkNow, releases])),
        ])
    }

    // MARK: - State

    func select(_ tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }

    func sync() {
        tagsView.refresh()
        replaceCheckbox.state = Settings.replaceFinder ? .on : .off
        resetDesktopButton.isEnabled = Settings.replaceFinder
        hiddenCheckbox.state = Settings.showHidden ? .on : .off
        commandBarCheckbox.state = Settings.showCommandBar ? .on : .off
        windowsKeysCheckbox.state = Settings.windowsKeys ? .on : .off
        updatesCheckbox.state = Updater.automaticChecks ? .on : .off
        syncHotKey()
        syncStartFolder()
        syncLogin()
        syncAccess()
    }

    /// The checkbox mirrors the system (the user can also switch it off in System Settings).
    private func syncLogin() {
        loginCheckbox.state = LoginItem.isEnabled || LoginItem.needsApproval ? .on : .off
        loginHint.stringValue = LoginItem.needsApproval
            ? "macOS ждёт разрешения в «Системные настройки ▸ Основные ▸ Объекты входа»."
            : "Без окна: значок в строке меню и, если WinEx заменяет Finder, рабочий стол."
        loginApproveButton.isHidden = !LoginItem.needsApproval
    }

    /// Full Disk Access can't be asked for, only checked: the Trash is readable with it.
    private func syncAccess() {
        let granted = (try? FileManager.default.contentsOfDirectory(atPath: Places.trashURL.path)) != nil
        accessIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        accessIcon.contentTintColor = granted ? .systemGreen : .systemOrange
        accessTitle.stringValue = granted ? "Выдан" : "Не выдан"
        accessHint.stringValue = granted
            ? "WinEx видит Корзину, Рабочий стол, Документы, Загрузки и сетевые диски без отдельных вопросов."
            : "Без него Корзина не открывается, а про Рабочий стол, Документы, Загрузки и сетевые диски macOS спрашивает отдельно. Включите WinEx в списке и нажмите «Закрыть и открыть снова»."
        accessButton.isHidden = granted
    }

    private func syncHotKey() {
        let preset = GlobalHotKey.preset
        hotKeyPopup.selectItem(at: GlobalHotKey.Preset.allCases.firstIndex(of: preset) ?? 0)
        if GlobalHotKey.shared.isTaken {
            hotKeyHint.stringValue = "Это сочетание занято другой программой — выберите другое."
        } else if preset == .commandE {
            hotKeyHint.stringValue = "Из любой программы. В некоторых программах ⌘E — «Искать выделенное»."
        } else {
            hotKeyHint.stringValue = "Из любой программы, как Win+E в Windows."
        }
    }

    private func syncStartFolder() {
        startPopup.removeAllItems()
        for choice in Self.startChoices { startPopup.addItem(withTitle: choice.title) }
        startPopup.menu?.addItem(.separator())
        let current = Settings.startFolder
        if let index = Self.startChoices.firstIndex(where: { $0.id == current }) {
            startPopup.selectItem(at: index)
        } else {
            // A folder of the user's choice: shown by name, selected
            startPopup.addItem(withTitle: FileManager.default.displayName(atPath: current))
            startPopup.lastItem?.toolTip = current
            startPopup.select(startPopup.lastItem)
        }
        startPopup.addItem(withTitle: "Другая папка…")
    }

    // MARK: - Actions

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            try LoginItem.set(sender.state == .on)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        syncLogin()
    }

    @objc private func openLoginItems(_ sender: Any?) { LoginItem.openLoginItemsSettings() }
    @objc private func openFullDiskAccess(_ sender: Any?) { Places.openFullDiskAccessSettings() }

    @objc private func openReleases(_ sender: Any?) {
        if let url = URL(string: "https://github.com/\(Updater.repository)/releases") { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleReplace(_ sender: NSButton) {
        AppDelegate.shared.setReplaceFinder(sender.state == .on)
        resetDesktopButton.isEnabled = Settings.replaceFinder
    }

    @objc private func resetDesktop(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Сбросить рабочий стол WinEx?"
        alert.informativeText = "Значки встанут туда, где они у Finder, а размер значков и сортировка станут как в Finder. Ваша расстановка на рабочем столе WinEx будет потеряна. Файлы не изменятся."
        alert.addButton(withTitle: "Сбросить")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { AppDelegate.shared.resetDesktopToFinder() }
        }
    }

    @objc private func changeStartFolder(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if Self.startChoices.indices.contains(index) {
            Settings.startFolder = Self.startChoices[index].id
        } else if sender.selectedItem?.title == "Другая папка…" {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Выбрать"
            if panel.runModal() == .OK, let url = panel.url { Settings.startFolder = url.path }
        }
        syncStartFolder()
    }

    @objc private func toggleUpdates(_ sender: NSButton) {
        Updater.automaticChecks = sender.state == .on
        Updater.shared.startAutomaticChecks()
    }

    @objc private func changeHotKey(_ sender: NSPopUpButton) {
        GlobalHotKey.preset = GlobalHotKey.Preset.allCases[max(0, sender.indexOfSelectedItem)]
        GlobalHotKey.shared.apply()
        syncHotKey()
    }

    @objc private func toggleWindowsKeys(_ sender: NSButton) {
        Settings.windowsKeys = sender.state == .on
        NotificationCenter.default.post(name: .keyboardSettingsChanged, object: nil)
    }

    @objc private func toggleCommandBar(_ sender: NSButton) {
        Settings.showCommandBar = sender.state == .on
        NotificationCenter.default.post(name: .commandBarSettingChanged, object: nil)
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        AppDelegate.shared.setShowHidden(sender.state == .on)
    }
}

/// Builds the settings forms: a two-column grid (right-aligned labels, controls in one column).
@MainActor
enum SettingsForm {
    enum Row {
        case row(String?, NSView)
        /// Spans both columns.
        case full(NSView)
        /// Extra space between groups.
        case gap
    }

    static let width: CGFloat = 540
    static let controlWidth: CGFloat = 330

    static func build(_ rows: [Row]) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        for row in rows {
            switch row {
            case .row(let label, let view):
                let title = NSTextField(labelWithString: label ?? "")
                title.alignment = .right
                let gridRow = grid.addRow(with: [title, view])
                gridRow.rowAlignment = .firstBaseline
            case .full(let view):
                let gridRow = grid.addRow(with: [view])
                grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: grid.numberOfRows - 1, length: 1))
                gridRow.topPadding = 2
            case .gap:
                let gridRow = grid.addRow(with: [NSGridCell.emptyContentView])
                gridRow.height = 6
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        return container
    }

    /// Small grey explanation under a control.
    static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = controlWidth
        return label
    }

    /// "?" that shows `text` in a popover.
    static func helpButton(_ text: String) -> NSButton {
        let button = HelpButton(text: text)
        return button
    }

    /// A titled two-column list of keys and what they do.
    static func keyTable(title: String, _ rows: [(key: String, action: String)]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 14
        for row in rows {
            let key = NSTextField(labelWithString: row.key)
            key.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            key.alignment = .right
            let action = NSTextField(labelWithString: row.action)
            action.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            action.textColor = .secondaryLabelColor
            grid.addRow(with: [key, action])
        }
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [heading, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }
}

/// The round "?" button; shows its text in a popover.
private final class HelpButton: NSButton {
    private var text = ""
    private var popover: NSPopover?

    convenience init(text: String) {
        self.init(frame: .zero)
        self.text = text
        bezelStyle = .helpButton
        title = ""
        target = self
        action = #selector(show(_:))
    }

    @objc private func show(_ sender: Any?) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 320
        let controller = NSViewController()
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.widthAnchor.constraint(equalToConstant: 320),
        ])
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}
