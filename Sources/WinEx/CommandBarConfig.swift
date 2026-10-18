import AppKit

/// A command the command bar can show. Which ones and in what order is the user's choice
/// (`CommandBarConfig`); "…" is always there, last.
enum BarCommand: String, CaseIterable {
    case new, newFolder, cut, copy, paste, rename, duplicate, share, airDrop, delete
    case compress, copyPath, addToFavorites, terminal, quickLook, properties
    case selectAll, selectNone, invertSelection, undo, redo
    case sort, group, view, hiddenFiles, newTab, settings

    /// What the command is called in the "…" menu and in the set to choose from.
    var title: String {
        switch self {
        case .new: L("Создать")
        case .newFolder: L("Новая папка")
        case .cut: L("Вырезать")
        case .copy: L("Копировать")
        case .paste: L("Вставить")
        case .rename: L("Переименовать")
        case .duplicate: L("Дублировать")
        case .share: L("Поделиться")
        case .airDrop: L("Отправить через AirDrop")
        case .delete: L("Удалить")
        case .compress: L("Сжать в ZIP-файл")
        case .copyPath: L("Скопировать путь")
        case .addToFavorites: L("Добавить в избранное")
        case .terminal: L("Открыть в терминале")
        case .quickLook: L("Быстрый просмотр")
        case .properties: L("Свойства")
        case .selectAll: L("Выделить всё")
        case .selectNone: L("Снять выделение")
        case .invertSelection: L("Обратить выделение")
        case .undo: L("Отменить")
        case .redo: L("Повторить")
        case .sort: L("Сортировать")
        case .group: L("Группировать")
        case .view: L("Просмотреть")
        case .hiddenFiles: L("Скрытые файлы")
        case .newTab: L("Новая вкладка")
        case .settings: L("Параметры")
        }
    }

    /// The explanation under the mouse (with the shortcut, where there is one).
    var tip: String {
        switch self {
        case .new: L("Создать папку или документ")
        case .cut: L("Вырезать (⌘X)")
        case .copy: L("Копировать (⌘C)")
        case .paste: L("Вставить (⌘V)")
        case .delete: L("Удалить (⌘⌫)")
        case .sort: L("Порядок файлов")
        case .group: L("Группы файлов")
        case .view: L("Вид")
        case .undo: L("Отменить (⌘Z)")
        case .redo: L("Повторить (⇧⌘Z)")
        case .hiddenFiles: L("Показывать скрытые файлы (⇧⌘.)")
        case .newTab: L("Новая вкладка (⌘T)")
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .new: "plus.circle"
        case .newFolder: "folder.badge.plus"
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .rename: "character.cursor.ibeam"
        case .duplicate: "plus.square.on.square"
        case .share: "square.and.arrow.up"
        case .airDrop: "finder:SidebarAirDrop"
        case .delete: "trash"
        case .compress: "archivebox"
        case .copyPath: "link"
        case .addToFavorites: "star"
        case .terminal: "terminal"
        case .quickLook: "eye"
        case .properties: "info.circle"
        case .selectAll: "checkmark.circle"
        case .selectNone: "circle"
        case .invertSelection: "circle.lefthalf.filled"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .sort: "arrow.up.arrow.down"
        case .group: "square.grid.3x1.below.line.grid.1x2"
        case .view: "square.grid.2x2"
        case .hiddenFiles: "eye.slash"
        case .newTab: "macwindow.badge.plus"
        case .settings: "gearshape"
        }
    }

    /// A pull-down (its menu is built when it opens); shown with its title, the rest as icons.
    var isMenu: Bool { [.new, .sort, .group, .view].contains(self) }
}

/// The command bar's contents: commands and dividers, in the user's order (dragged in
/// «Настроить панель команд…», or ⌘-dragged on the bar itself).
enum CommandBarConfig {
    static let didChange = Notification.Name("WinExCommandBarItemsChanged")
    /// A divider between commands (there may be several).
    static let divider = "divider"

    /// The bar as it comes: Explorer's commands.
    static let defaultItems = [
        BarCommand.new.rawValue, divider,
        BarCommand.cut.rawValue, BarCommand.copy.rawValue, BarCommand.paste.rawValue, BarCommand.rename.rawValue,
        BarCommand.share.rawValue, BarCommand.airDrop.rawValue, BarCommand.delete.rawValue, divider,
        BarCommand.sort.rawValue, BarCommand.group.rawValue, BarCommand.view.rawValue,
    ]

    private static var defaults: UserDefaults { AppDefaults.store }

    static var items: [String] {
        get { (defaults.stringArray(forKey: "commandBarItems")).map(sanitized) ?? defaultItems }
        set {
            let items = sanitized(newValue)
            if items == defaultItems { defaults.removeObject(forKey: "commandBarItems") } else { defaults.set(items, forKey: "commandBarItems") }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var commands: [BarCommand] { items.compactMap(BarCommand.init(rawValue:)) }

    /// Known commands once each (a newer version's commands dropped), no divider at an end or
    /// next to another.
    static func sanitized(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            if item == divider {
                if let last = result.last, last != divider { result.append(item) }
            } else if BarCommand(rawValue: item) != nil, seen.insert(item).inserted {
                result.append(item)
            }
        }
        if result.last == divider { result.removeLast() }
        return result
    }

    /// `item` dropped at `index` (a position in `items`): moved there from `source` (its index,
    /// when it comes from the bar itself) or added; a command already on the bar moves.
    static func dropping(_ item: String, from source: Int?, at index: Int, into items: [String]) -> [String] {
        var items = items
        var index = min(max(index, 0), items.count)
        if let source, items.indices.contains(source), items[source] == item {
            items.remove(at: source)
            if source < index { index -= 1 }
        } else if item != divider, let current = items.firstIndex(of: item) {
            items.remove(at: current)
            if current < index { index -= 1 }
        }
        items.insert(item, at: index)
        return items
    }

    static func removing(at index: Int, from items: [String]) -> [String] {
        var items = items
        if items.indices.contains(index) { items.remove(at: index) }
        return items
    }
}
