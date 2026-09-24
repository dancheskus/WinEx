import AppKit

/// The menu is never shown (WinEx is an LSUIElement app), but it still provides
/// keyboard shortcuts and routes Cut/Copy/Paste to the focused view.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

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
            item("Новая папка", #selector(FileListViewController.newFolder(_:)), "n", [.command, .shift]),
            item("Переименовать", #selector(FileListViewController.renameSelected(_:)), key(NSF2FunctionKey), []),
            item("Переместить в корзину", #selector(FileListViewController.moveToTrash(_:)), key(NSBackspaceCharacter)),
        ])
        submenu("Правка", [
            item("Вырезать", #selector(NSText.cut(_:)), "x"),
            item("Копировать", #selector(NSText.copy(_:)), "c"),
            item("Вставить", #selector(NSText.paste(_:)), "v"),
            item("Выделить всё", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Копировать путь", #selector(FileListViewController.copyPath(_:)), "c", [.command, .option]),
        ])
        submenu("Вид", [
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
        return main
    }
}
