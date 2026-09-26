import AppKit

/// The menu is never shown (WinEx is an LSUIElement app), but it still provides
/// keyboard shortcuts and routes Cut/Copy/Paste to the focused view.
enum MainMenu {
    /// "Переименовать": F2 only with Windows keys (Finder renames with Return).
    private static let renameItem = NSMenuItem(title: L("Переименовать"), action: #selector(FileListViewController.renameSelected(_:)), keyEquivalent: "")

    static func updateRenameShortcut() {
        renameItem.keyEquivalent = Settings.windowsKeys ? String(Character(UnicodeScalar(NSF2FunctionKey)!)) : ""
        renameItem.keyEquivalentModifierMask = []
    }

    /// US-layout Shift characters for the punctuation used in shortcuts.
    private static let shiftedKeys = [".": ">", ",": "<", "[": "{", "]": "}", "/": "?", "=": "+", "-": "_", ";": ":"]

    static func build() -> NSMenu {
        let main = NSMenu()
        updateRenameShortcut()
        NotificationCenter.default.addObserver(forName: .keyboardSettingsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { updateRenameShortcut() }
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }

        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            // A real keyboard sends ⇧⌘N as "N" and ⇧⌘. as ">": NSMenu compares those characters, so
            // "n" + Shift never matches. Write Shift chords with the shifted character instead.
            var key = key, modifiers = modifiers
            if modifiers.contains(.shift), let shifted = shiftedKeys[key] ?? (key.count == 1 && key.lowercased() == key && key.uppercased() != key ? key.uppercased() : nil) {
                key = shifted
                modifiers.remove(.shift)
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        func key(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

        submenu("WinEx", [
            item(L("Настройки…"), #selector(AppDelegate.showSettings(_:)), ","),
            item(L("Мастер настройки…"), #selector(AppDelegate.showSetupWizard(_:)), ""),
            item(L("Проверить обновления…"), #selector(AppDelegate.checkForUpdates(_:)), ""),
            .separator(),
            item(L("Выйти из WinEx"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(L("Файл"), [
            item(L("Новое окно"), #selector(AppDelegate.newWindow(_:)), "n"),
            item(L("Новая вкладка"), #selector(ExplorerWindowController.newTab(_:)), "t"),
            item(L("Закрыть вкладку"), #selector(ExplorerWindowController.closeCurrentTab(_:)), "w"),
            .separator(),
            item(L("Открыть"), #selector(FileListViewController.openSelected(_:)), key(NSDownArrowFunctionKey)),
            {
                let alternate = item(L("Открыть"), #selector(FileListViewController.openSelected(_:)), "o")
                alternate.isHidden = true
                alternate.allowsKeyEquivalentWhenHidden = true
                return alternate
            }(),
            item(L("Новая папка"), #selector(FileListViewController.newFolder(_:)), "n", [.command, .shift]),
            item(L("Дублировать"), #selector(FileListViewController.duplicate(_:)), "d"),
            item(L("Создать псевдоним"), #selector(FileListViewController.makeAlias(_:)), "a", [.command, .control]),
            item(L("Показать оригинал"), #selector(FileListViewController.showOriginal(_:)), ""),
            item(L("Показать содержимое пакета"), #selector(FileListViewController.showPackageContents(_:)), ""),
            item(L("Сжать"), #selector(FileListViewController.compress(_:)), ""),
            item(L("Распаковать"), #selector(FileListViewController.extractArchive(_:)), ""),
            item(L("Найти"), #selector(ExplorerWindowController.focusSearchField(_:)), "f"),
            renameItem,
            item(L("Переместить в корзину"), #selector(FileListViewController.moveToTrash(_:)), key(NSBackspaceCharacter)),
            .separator(),
            item(L("Свойства"), #selector(FileListViewController.showProperties(_:)), "i"),
            {
                // Alt+Enter from Windows
                let alternate = item(L("Свойства"), #selector(FileListViewController.showProperties(_:)), "\r", [.option])
                alternate.isHidden = true
                alternate.allowsKeyEquivalentWhenHidden = true
                return alternate
            }(),
        ])
        submenu(L("Правка"), [
            // ⌘Z / ⇧⌘Z: text while editing a name, otherwise file operations (the window's undo manager)
            item(L("Отменить"), Selector(("undo:")), "z"),
            item(L("Повторить"), Selector(("redo:")), "Z"),  // capital Z = ⇧⌘Z, as in Apple's menus
            .separator(),
            item(L("Вырезать"), #selector(NSText.cut(_:)), "x"),
            item(L("Копировать"), #selector(NSText.copy(_:)), "c"),
            item(L("Вставить"), #selector(NSText.paste(_:)), "v"),
            item(L("Выделить всё"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L("Копировать путь"), #selector(FileListViewController.copyPath(_:)), "c", [.command, .option]),
        ])
        let viewModes = ViewMode.allCases.map { mode -> NSMenuItem in
            let item = item(mode.title, #selector(ExplorerWindowController.selectViewMode(_:)), "\(mode.rawValue + 1)")
            item.tag = mode.rawValue
            return item
        }
        submenu(L("Вид"), viewModes + [
            .separator(),
            item(L("Показывать скрытые файлы"), #selector(AppDelegate.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item(L("Обновить"), #selector(ExplorerWindowController.refresh(_:)), "r"),
        ])
        submenu(L("Переход"), [
            item(L("Назад"), #selector(ExplorerWindowController.goBack(_:)), "["),
            item(L("Вперёд"), #selector(ExplorerWindowController.goForward(_:)), "]"),
            item(L("Вверх"), #selector(ExplorerWindowController.goUp(_:)), key(NSUpArrowFunctionKey)),
            item(L("Перейти к пути…"), #selector(ExplorerWindowController.focusPathField(_:)), "l"),
            .separator(),
            item(L("Сеть"), #selector(ExplorerWindowController.goToNetwork(_:)), "k", [.command, .shift]),
            item("AirDrop", #selector(ExplorerWindowController.openAirDrop(_:)), "r", [.command, .shift]),
            item(L("Корзина"), #selector(ExplorerWindowController.goToTrash(_:)), ""),
            item(L("Подключиться к серверу…"), #selector(ExplorerWindowController.connectToServer(_:)), "k"),
            .separator(),
            item(L("Следующая вкладка"), #selector(ExplorerWindowController.selectNextTab(_:)), "]", [.command, .shift]),
            item(L("Предыдущая вкладка"), #selector(ExplorerWindowController.selectPreviousTab(_:)), "[", [.command, .shift]),
        ])
        let windowMenu = NSMenu(title: L("Окно"))
        [item(L("Свернуть"), #selector(NSWindow.performMiniaturize(_:)), "m"),
         item(L("Масштаб"), #selector(NSWindow.performZoom(_:)), ""),
         .separator(),
         item(L("Все окна — на передний план"), #selector(NSApplication.arrangeInFront(_:)), "")].forEach(windowMenu.addItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
