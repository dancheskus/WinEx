import AppKit

final class SettingsWindowController: NSWindowController {
    private let replaceCheckbox = NSButton(checkboxWithTitle: "Использовать WinEx вместо Finder", target: nil, action: nil)
    private let hiddenCheckbox = NSButton(checkboxWithTitle: "Показывать скрытые файлы", target: nil, action: nil)
    private let windowsKeysCheckbox = NSButton(checkboxWithTitle: "Клавиши как в Windows", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Открывать WinEx при входе в систему", target: nil, action: nil)
    private let loginHint = NSTextField(wrappingLabelWithString: "")
    private let loginApproveButton = NSButton(title: "Открыть «Объекты входа»…", target: nil, action: nil)
    private let hotKeyPopup = NSPopUpButton()
    private let hotKeyHint = NSTextField(wrappingLabelWithString: "")
    private let resetDesktopButton = NSButton(title: "Сбросить рабочий стол как в Finder…", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Настройки WinEx"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        replaceCheckbox.target = self
        replaceCheckbox.action = #selector(toggleReplace(_:))
        hiddenCheckbox.target = self
        hiddenCheckbox.action = #selector(toggleHidden(_:))
        windowsKeysCheckbox.target = self
        windowsKeysCheckbox.action = #selector(toggleWindowsKeys(_:))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin(_:))
        loginHint.font = .systemFont(ofSize: 12)
        loginHint.textColor = .secondaryLabelColor
        loginHint.preferredMaxLayoutWidth = 420
        loginApproveButton.target = self
        loginApproveButton.action = #selector(openLoginItems(_:))
        loginApproveButton.controlSize = .small
        resetDesktopButton.target = self
        resetDesktopButton.action = #selector(resetDesktop(_:))
        let keysHint = NSTextField(wrappingLabelWithString: """
            Enter — открыть, F2 — переименовать, Backspace или ⌥↑ — вверх, ⌥← ⌥→ — назад / вперёд,             F3 — поиск, F4 или ⌥D — адресная строка, F5 — обновить, F11 — полный экран, Delete — в Корзину,             ⇧Delete — удалить навсегда, ⇧F10 — контекстное меню. Выключено: как в Finder — Enter переименовывает,             ⌘↓ или ⌘O открывают, ⌘↑ — вверх. Всегда: ⌃Tab / ⌃⇧Tab и ⌃1…9 — вкладки, перетаскивание с ⌘ —             переместить, с ⌥ — копировать, с ⌘⌥ — создать псевдоним.
            """)
        keysHint.font = .systemFont(ofSize: 12)
        keysHint.textColor = .secondaryLabelColor
        keysHint.preferredMaxLayoutWidth = 420

        let explanation = NSTextField(wrappingLabelWithString: """
            • Рабочий стол рисует WinEx: папки с рабочего стола открываются в WinEx.
            • «Показать в Finder» в других приложениях показывает файл в WinEx.
            • Папки, которые другие приложения открывают напрямую, по-прежнему открываются в Finder — macOS не даёт сменить программу для папок.
            • При выходе из WinEx (строка меню → «Выйти») всё возвращается Finder.
            """)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 420

        let separator = NSBox()
        separator.boxType = .separator

        // Win+E: a WinEx window from any app
        for preset in GlobalHotKey.Preset.allCases { hotKeyPopup.addItem(withTitle: preset.title) }
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(changeHotKey(_:))
        let hotKeyRow = NSStackView(views: [NSTextField(labelWithString: "Открыть окно WinEx из любой программы:"), hotKeyPopup])
        hotKeyRow.spacing = 8
        hotKeyHint.font = .systemFont(ofSize: 12)
        hotKeyHint.textColor = .secondaryLabelColor
        hotKeyHint.preferredMaxLayoutWidth = 420

        let separator2 = NSBox()
        separator2.boxType = .separator
        let stack = NSStackView(views: [loginCheckbox, loginHint, loginApproveButton, separator2,
                                        replaceCheckbox, explanation, resetDesktopButton, separator, hotKeyRow, hotKeyHint, hiddenCheckbox, windowsKeysCheckbox, keysHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: replaceCheckbox)
        stack.setCustomSpacing(6, after: windowsKeysCheckbox)
        stack.setCustomSpacing(6, after: hotKeyRow)
        stack.setCustomSpacing(6, after: loginCheckbox)
        separator2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        window.center()
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    func sync() {
        replaceCheckbox.state = Settings.replaceFinder ? .on : .off
        hiddenCheckbox.state = Settings.showHidden ? .on : .off
        windowsKeysCheckbox.state = Settings.windowsKeys ? .on : .off
        syncHotKey()
        syncLogin()
    }

    /// The checkbox mirrors the system (the user can also switch it off in System Settings).
    private func syncLogin() {
        loginCheckbox.state = LoginItem.isEnabled || LoginItem.needsApproval ? .on : .off
        if LoginItem.needsApproval {
            loginHint.stringValue = "macOS ждёт разрешения: включите WinEx в «Системные настройки ▸ Основные ▸ Объекты входа»."
        } else {
            loginHint.stringValue = "При входе WinEx запускается без окна: значок в строке меню и, если он заменяет Finder, рабочий стол."
        }
        loginApproveButton.isHidden = !LoginItem.needsApproval
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            try LoginItem.set(sender.state == .on)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        syncLogin()
    }

    @objc private func openLoginItems(_ sender: Any?) {
        LoginItem.openLoginItemsSettings()
    }

    @objc private func toggleReplace(_ sender: NSButton) {
        AppDelegate.shared.setReplaceFinder(sender.state == .on)
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

    private func syncHotKey() {
        let preset = GlobalHotKey.preset
        hotKeyPopup.selectItem(at: GlobalHotKey.Preset.allCases.firstIndex(of: preset) ?? 0)
        if preset != .off && !GlobalHotKey.shared.isRegistered {
            hotKeyHint.stringValue = "Это сочетание уже занято другой программой — выберите другое."
        } else if preset == .commandE {
            hotKeyHint.stringValue = "⌘E во многих программах означает «Искать выделенное» — там оно перестанет работать."
        } else {
            hotKeyHint.stringValue = "Как Win+E в Windows: новое окно WinEx поверх любой программы."
        }
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

    @objc private func toggleHidden(_ sender: NSButton) {
        AppDelegate.shared.setShowHidden(sender.state == .on)
    }
}
