import AppKit

/// Settings, the way Mac apps lay them out: tabs in the toolbar, each a short form
/// ("label: control", labels right-aligned in one column); explanations in "?" popovers.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int { case general, sidebar, tags, apps, finder, keyboard, access, updates }

    private let tabs = NSTabViewController()
    private let tagsView = TagSettingsView()
    // Основные
    private let startPopup = NSPopUpButton()
    private let viewModePopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private let languageHint = SettingsForm.hint("")
    private let hotKeyPopup = NSPopUpButton()
    private let hotKeyHint = SettingsForm.hint("")
    private let hiddenCheckbox = NSButton(checkboxWithTitle: L("Показывать скрытые файлы"), target: nil, action: nil)
    private let terminalCheckbox = NSButton(checkboxWithTitle: L("«Открыть в терминале» в контекстном меню"), target: nil, action: nil)
    private let terminalPopup = NSPopUpButton()
    private let commandBarCheckbox = NSButton(checkboxWithTitle: L("Панель команд под адресной строкой"), target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: L("Открывать WinEx при входе в систему"), target: nil, action: nil)
    private let loginHint = SettingsForm.hint("")
    private let loginApproveButton = NSButton(title: L("Открыть «Объекты входа»…"), target: nil, action: nil)
    // Finder и рабочий стол
    private let replaceCheckbox = NSButton(checkboxWithTitle: L("Использовать WinEx вместо Finder"), target: nil, action: nil)
    private let shellCheckbox = NSButton(checkboxWithTitle: L("Команда open в Терминале открывает папки в WinEx"), target: nil, action: nil)
    private let resetDesktopButton = NSButton(title: L("Сбросить рабочий стол как в Finder…"), target: nil, action: nil)
    // Клавиатура
    private let windowsKeysCheckbox = NSButton(checkboxWithTitle: L("Клавиши как в Windows"), target: nil, action: nil)
    // Доступ
    private let accessIcon = NSImageView()
    private let accessTitle = NSTextField(labelWithString: "")
    private let accessHint = SettingsForm.hint("")
    private let accessButton = NSButton(title: L("Открыть настройки «Полный доступ к диску»…"), target: nil, action: nil)
    // Обновления
    private let updatesCheckbox = NSButton(checkboxWithTitle: L("Проверять обновления автоматически"), target: nil, action: nil)

    private static let startChoices: [(id: String, title: String)] = [
        ("home", L("Домашняя папка")), ("desktop", L("Рабочий стол")), ("downloads", L("Загрузки")),
        ("documents", L("Документы")), ("computer", L("Этот Mac")),
    ]

    private let observers = Observers()

    init() {
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = L("Настройки WinEx")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)

        for (title, symbol, view) in [
            (L("Основные"), "gearshape", generalPane()),
            (L("Боковое меню"), "sidebar.left", SidebarSettingsView()),
            (L("Теги"), "tag", tagsView),
            (L("Программы"), "square.grid.2x2", AppsSettingsView()),
            ("Finder", "macwindow.on.rectangle", finderPane()),
            (L("Клавиатура"), "keyboard", keyboardPane()),
            (L("Доступ"), "lock.shield", accessPane()),
            (L("Обновления"), "arrow.triangle.2.circlepath", updatesPane()),
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
        terminalCheckbox.target = self
        terminalCheckbox.action = #selector(toggleTerminal(_:))
        terminalPopup.target = self
        terminalPopup.action = #selector(changeTerminal(_:))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin(_:))
        loginApproveButton.target = self
        loginApproveButton.action = #selector(openLoginItems(_:))
        loginApproveButton.controlSize = .small
        for language in Localization.Language.allCases {
            languagePopup.addItem(withTitle: language.title)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage(_:))
        for mode in ViewMode.allCases {
            viewModePopup.addItem(withTitle: mode.title)
            viewModePopup.lastItem?.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            viewModePopup.lastItem?.tag = mode.rawValue
        }
        viewModePopup.target = self
        viewModePopup.action = #selector(changeViewMode(_:))
        return SettingsForm.build([
            .row(L("Язык:"), languagePopup),
            .row(nil, languageHint),
            .gap,
            // How windows look and what they show
            .row(L("Новые окна открываются в:"), startPopup),
            .row(L("Вид папок по умолчанию:"), viewModePopup),
            .row(L("Окно:"), commandBarCheckbox),
            .row(L("Файлы:"), hiddenCheckbox),
            .gap,
            .row(L("Окно WinEx из любой программы:"), hotKeyPopup),
            .row(nil, hotKeyHint),
            .gap,
            .row(L("Терминал:"), terminalCheckbox),
            .row(nil, terminalPopup),
            .row(nil, SettingsForm.hint(L("Для папки — она сама, для файла — его папка; на пустом месте — открытая папка или рабочий стол."))),
            .gap,
            .row(L("Запуск:"), loginCheckbox),
            .row(nil, loginNote()),
            .gap,
            .row(L("Настройки:"), settingsButtons()),
            .row(nil, SettingsForm.hint(L("Сохранить все настройки в файл (например, перед переустановкой или для другого Mac), загрузить их обратно или вернуть исходные."))),
        ])
    }

    private func finderPane() -> NSView {
        replaceCheckbox.target = self
        replaceCheckbox.action = #selector(toggleReplace(_:))
        resetDesktopButton.target = self
        resetDesktopButton.action = #selector(resetDesktop(_:))
        shellCheckbox.target = self
        shellCheckbox.action = #selector(toggleShell(_:))
        let help = SettingsForm.helpButton(L("Когда WinEx заменяет Finder:\n• рабочий стол рисует WinEx, папки с него открываются в WinEx;\n• «Показать в Finder» в других программах показывает файл в WinEx;\n• папки, которые другие программы открывают сами, по-прежнему открываются в Finder — macOS не даёт сменить программу для папок (для команды open в Терминале — флажок ниже);\n• «Выйти» в строке меню возвращает всё Finder."))
        let replaceRow = NSStackView(views: [replaceCheckbox, help])
        replaceRow.spacing = 6
        return SettingsForm.build([
            .row(L("Рабочий стол:"), replaceRow),
            .row(nil, SettingsForm.hint(L("Рабочий стол и «Показать в Finder» переходят к WinEx. «Выйти» в строке меню возвращает Finder."))),
            .gap,
            .row(L("Значки:"), resetDesktopButton),
            .row(nil, SettingsForm.hint(L("Расставить значки, их размер и сортировку так, как у Finder."))),
            .gap,
            .row(L("Терминал:"), shellCheckbox),
            .row(nil, SettingsForm.hint(L("«open ~/Documents» и «open .» откроют папку в WinEx; файлы, программы и ссылки — как раньше. WinEx добавит небольшую функцию в ~/.zshrc (снимите флажок — уберёт). Действует в новых окнах Терминала."))),
        ])
    }

    private func keyboardPane() -> NSView {
        windowsKeysCheckbox.target = self
        windowsKeysCheckbox.action = #selector(toggleWindowsKeys(_:))
        return SettingsForm.build([
            .row(L("Клавиши:"), windowsKeysCheckbox),
            .row(nil, SettingsForm.hint(L("Выключено — как в Finder: Enter переименовывает, ⌘↓ или ⌘O открывают, ⌘↑ — вверх."))),
            .gap,
            .row(nil, SettingsForm.keyTable(title: L("С «Клавишами как в Windows»"), [
                ("Enter", L("открыть")), ("F2", L("переименовать")), ("Backspace, ⌥↑", L("на уровень выше")),
                ("⌥←  ⌥→", L("назад / вперёд")), ("F3", L("поиск")), ("F4, ⌥D", L("адресная строка")), ("F5", L("обновить")),
                ("F11", L("полный экран")), ("Delete", L("в Корзину")), ("⇧Delete", L("удалить навсегда")), ("⇧F10", L("контекстное меню")),
            ])),
            .gap,
            .row(nil, SettingsForm.keyTable(title: L("Всегда"), [
                ("⌃Tab, ⌃⇧Tab", L("следующая / предыдущая вкладка")), ("⌃1 … ⌃9", L("вкладка по номеру")),
                (L("⌘ + перетащить"), L("переместить")), (L("⌥ + перетащить"), L("копировать")), (L("⌘⌥ + перетащить"), L("создать псевдоним")),
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
            .row(L("Полный доступ к диску:"), status),
            .row(nil, accessHint),
            .row(nil, accessButton),
        ])
    }

    private func updatesPane() -> NSView {
        updatesCheckbox.target = self
        updatesCheckbox.action = #selector(toggleUpdates(_:))
        let checkNow = NSButton(title: L("Проверить сейчас"), target: AppDelegate.shared, action: #selector(AppDelegate.checkForUpdates(_:)))
        let releases = NSButton(title: L("Страница релизов…"), target: self, action: #selector(openReleases(_:)))
        let version = NSTextField(labelWithString: Updater.shared.currentVersion + (Updater.shared.isDevBuild ? L(" (своя сборка)") : ""))
        return SettingsForm.build([
            .row(L("Версия:"), version),
            .row(L("Обновления:"), updatesCheckbox),
            .row(nil, SettingsForm.hint(Updater.shared.isDevBuild
                ? L("Своя сборка сама не обновляется — только по кнопке «Проверить сейчас».")
                : L("Раз в сутки WinEx проверяет новые версии и предлагает обновиться. Разрешения сохраняются."))),
            .row(nil, NSStackView(views: [checkNow, releases])),
        ])
    }

    /// The hint and, only while macOS waits for approval, the button (a hidden one takes no room).
    private func loginNote() -> NSView {
        let stack = NSStackView(views: [loginHint, loginApproveButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        return stack
    }

    /// The default view for folders (like "Вид ▸ Применить ко всем папкам").
    @objc private func changeViewMode(_ sender: NSPopUpButton) {
        guard let mode = ViewMode(rawValue: sender.selectedTag()) else { return }
        ViewMode.applyToAllFolders(mode)
    }

    private func settingsButtons() -> NSView {
        let save = NSButton(title: L("Сохранить в файл…"), target: self, action: #selector(saveSettings(_:)))
        let load = NSButton(title: L("Загрузить из файла…"), target: self, action: #selector(loadSettings(_:)))
        let reset = NSButton(title: L("По умолчанию…"), target: self, action: #selector(resetSettings(_:)))
        let wizard = NSButton(title: L("Мастер настройки…"), target: AppDelegate.shared, action: #selector(AppDelegate.showSetupWizard(_:)))
        let row = NSStackView(views: [save, load, reset])
        let column = NSStackView(views: [row, wizard])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        row.spacing = 8
        return column
    }

    @objc private func saveSettings(_ sender: Any?) { SettingsBackup.save(from: window) }
    @objc private func loadSettings(_ sender: Any?) { SettingsBackup.load(into: window) }
    @objc private func resetSettings(_ sender: Any?) { SettingsBackup.resetToDefaults(in: window) }

    // MARK: - State

    func select(_ tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }

    private func syncLanguage() {
        languagePopup.selectItem(at: Localization.Language.allCases.firstIndex(of: Localization.chosen) ?? 0)
        languageHint.stringValue = L("«Как в системе»: русский, если macOS на русском, иначе английский.")
    }

    /// A new language: WinEx restarts at once and comes back with the same windows, tabs and
    /// these settings.
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        Localization.chosen = Localization.Language(rawValue: sender.selectedItem?.representedObject as? String ?? "") ?? .system
        syncLanguage()
        guard Localization.needsRestart else { return }
        AppDelegate.shared.restartKeepingWindows(settingsOpen: true)
    }

    func sync() {
        syncLanguage()
        viewModePopup.selectItem(withTag: ViewMode.saved.rawValue)
        tagsView.refresh()
        replaceCheckbox.state = Settings.replaceFinder ? .on : .off
        shellCheckbox.state = ShellIntegration.isInstalled ? .on : .off
        resetDesktopButton.isEnabled = Settings.replaceFinder
        hiddenCheckbox.state = Settings.showHidden ? .on : .off
        commandBarCheckbox.state = Settings.showCommandBar ? .on : .off
        terminalCheckbox.state = Settings.terminalInMenu ? .on : .off
        syncTerminal()
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
            ? L("macOS ждёт разрешения в «Системные настройки ▸ Основные ▸ Объекты входа».")
            : L("Без окна: значок в строке меню и, если WinEx заменяет Finder, рабочий стол.")
        loginApproveButton.isHidden = !LoginItem.needsApproval
    }

    /// Full Disk Access can't be asked for, only checked: the Trash is readable with it.
    private func syncAccess() {
        let granted = (try? FileManager.default.contentsOfDirectory(atPath: Places.trashURL.path)) != nil
        accessIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        accessIcon.contentTintColor = granted ? .systemGreen : .systemOrange
        accessTitle.stringValue = granted ? L("Выдан") : L("Не выдан")
        accessHint.stringValue = granted
            ? L("WinEx видит Корзину, Рабочий стол, Документы, Загрузки и сетевые диски без отдельных вопросов.")
            : L("Без него Корзина не открывается, а про Рабочий стол, Документы, Загрузки и сетевые диски macOS спрашивает отдельно. Включите WinEx в списке и нажмите «Закрыть и открыть снова».")
        accessButton.isHidden = granted
    }

    private func syncHotKey() {
        let preset = GlobalHotKey.preset
        hotKeyPopup.selectItem(at: GlobalHotKey.Preset.allCases.firstIndex(of: preset) ?? 0)
        if GlobalHotKey.shared.isTaken {
            hotKeyHint.stringValue = L("Это сочетание занято другой программой — выберите другое.")
        } else if preset == .commandE {
            hotKeyHint.stringValue = L("Из любой программы. В некоторых программах ⌘E — «Искать выделенное».")
        } else {
            hotKeyHint.stringValue = L("Из любой программы, как Win+E в Windows.")
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
        startPopup.addItem(withTitle: L("Другая папка…"))
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

    @objc private func toggleShell(_ sender: NSButton) {
        do {
            if sender.state == .on { try ShellIntegration.install() } else { try ShellIntegration.uninstall() }
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        sender.state = ShellIntegration.isInstalled ? .on : .off
    }

    @objc private func toggleReplace(_ sender: NSButton) {
        AppDelegate.shared.setReplaceFinder(sender.state == .on)
        resetDesktopButton.isEnabled = Settings.replaceFinder
    }

    @objc private func resetDesktop(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Сбросить рабочий стол WinEx?")
        alert.informativeText = L("Значки встанут туда, где они у Finder, а размер значков и сортировка станут как в Finder. Ваша расстановка на рабочем столе WinEx будет потеряна. Файлы не изменятся.")
        alert.addButton(withTitle: L("Сбросить"))
        alert.addButton(withTitle: L("Отмена"))
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
        } else if sender.selectedItem?.title == L("Другая папка…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = L("Выбрать")
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

    private func syncTerminal() {
        terminalPopup.removeAllItems()
        var apps = TerminalLauncher.installed
        if let chosen = TerminalLauncher.chosen, !apps.contains(chosen) { apps.append(chosen) }
        for app in apps {
            terminalPopup.addItem(withTitle: app.name)
            let icon = NSWorkspace.shared.icon(forFile: app.url.path)
            icon.size = NSSize(width: 16, height: 16)
            terminalPopup.lastItem?.image = icon
            terminalPopup.lastItem?.representedObject = app.url
            if app == TerminalLauncher.chosen { terminalPopup.select(terminalPopup.lastItem) }
        }
        terminalPopup.menu?.addItem(.separator())
        terminalPopup.addItem(withTitle: L("Другая программа…"))
        terminalPopup.isEnabled = Settings.terminalInMenu
    }

    @objc private func toggleTerminal(_ sender: NSButton) {
        Settings.terminalInMenu = sender.state == .on
        terminalPopup.isEnabled = Settings.terminalInMenu
    }

    @objc private func changeTerminal(_ sender: NSPopUpButton) {
        if let url = sender.selectedItem?.representedObject as? URL {
            Settings.terminalApp = url.path
        } else {
            let panel = NSOpenPanel()
            panel.title = L("Терминал для «Открыть в терминале»")
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            if panel.runModal() == .OK, let url = panel.url { Settings.terminalApp = url.path }
        }
        syncTerminal()
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

    static let width: CGFloat = 660
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

    /// A grey explanation across the whole pane.
    static func wideHint(_ text: String) -> NSTextField {
        let label = hint(text)
        label.preferredMaxLayoutWidth = width - 40
        return label
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
