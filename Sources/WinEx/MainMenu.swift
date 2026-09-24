import AppKit

/// The menu is never shown (WinEx is an LSUIElement app), but it still provides
/// keyboard shortcuts and routes Cut/Copy/Paste to the focused view.
enum MainMenu {
    /// "Переименовать": F2 only with Windows keys (Finder renames with Return).
    private static let renameItem = NSMenuItem(title: "Переименовать", action: #selector(FileListViewController.renameSelected(_:)), keyEquivalent: "")

    static func updateRenameShortcut() {
        renameItem.keyEquivalent = Settings.windowsKeys ? String(Character(UnicodeScalar(NSF2FunctionKey)!)) : ""
        renameItem.keyEquivalentModifierMask = []
    }

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
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        func key(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

        submenu("WinEx", [
            item("Настройки…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Выйти из WinEx", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Файл", [
            item("Новое окно", #selector(AppDelegate.newWindow(_:)), "n"),
            item("Новая вкладка", #selector(ExplorerWindowController.newTab(_:)), "t"),
            item("Закрыть вкладку", #selector(ExplorerWindowController.closeCurrentTab(_:)), "w"),
            .separator(),
            item("Открыть", #selector(FileListViewController.openSelected(_:)), key(NSDownArrowFunctionKey)),
            {
                let alternate = item("Открыть", #selector(FileListViewController.openSelected(_:)), "o")
                alternate.isHidden = true
                alternate.allowsKeyEquivalentWhenHidden = true
                return alternate
            }(),
            item("Новая папка", #selector(FileListViewController.newFolder(_:)), "n", [.command, .shift]),
            renameItem,
            item("Переместить в корзину", #selector(FileListViewController.moveToTrash(_:)), key(NSBackspaceCharacter)),
            .separator(),
            item("Свойства", #selector(FileListViewController.showProperties(_:)), "i"),
            {
                // Alt+Enter from Windows
                let alternate = item("Свойства", #selector(FileListViewController.showProperties(_:)), "\r", [.option])
                alternate.isHidden = true
                alternate.allowsKeyEquivalentWhenHidden = true
                return alternate
            }(),
        ])
        submenu("Правка", [
            item("Вырезать", #selector(NSText.cut(_:)), "x"),
            item("Копировать", #selector(NSText.copy(_:)), "c"),
            item("Вставить", #selector(NSText.paste(_:)), "v"),
            item("Выделить всё", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Копировать путь", #selector(FileListViewController.copyPath(_:)), "c", [.command, .option]),
        ])
        let viewModes = ViewMode.allCases.map { mode -> NSMenuItem in
            let item = item(mode.title, #selector(ExplorerWindowController.selectViewMode(_:)), "\(mode.rawValue + 1)")
            item.tag = mode.rawValue
            return item
        }
        submenu("Вид", viewModes + [
            .separator(),
            item("Показывать скрытые файлы", #selector(AppDelegate.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("Обновить", #selector(ExplorerWindowController.refresh(_:)), "r"),
        ])
        submenu("Переход", [
            item("Назад", #selector(ExplorerWindowController.goBack(_:)), "["),
            item("Вперёд", #selector(ExplorerWindowController.goForward(_:)), "]"),
            item("Вверх", #selector(ExplorerWindowController.goUp(_:)), key(NSUpArrowFunctionKey)),
            item("Перейти к пути…", #selector(ExplorerWindowController.focusPathField(_:)), "l"),
            .separator(),
            item("Следующая вкладка", #selector(ExplorerWindowController.selectNextTab(_:)), "]", [.command, .shift]),
            item("Предыдущая вкладка", #selector(ExplorerWindowController.selectPreviousTab(_:)), "[", [.command, .shift]),
        ])
        let windowMenu = NSMenu(title: "Окно")
        [item("Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m"),
         item("Масштаб", #selector(NSWindow.performZoom(_:)), ""),
         .separator(),
         item("Все окна — на передний план", #selector(NSApplication.arrangeInFront(_:)), "")].forEach(windowMenu.addItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
