import AppKit

/// ⌘Z / ⇧⌘Z for file operations, one history for all windows and the desktop (like Finder).
/// Every action registers its inverse; when an undo runs, the inverse registers the original
/// again, so redo comes for free.
@MainActor
enum FileUndo {
    static let manager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        return manager
    }()

    /// The history ⌘Z works on in `window` right now: while a name or the address bar is being
    /// edited, the text's own history (the field editor keeps it); otherwise file operations.
    static func manager(for window: NSWindow) -> UndoManager {
        if let editor = window.firstResponder as? NSTextView, let textHistory = editor.undoManager, textHistory !== manager {
            return textHistory
        }
        return manager
    }

    /// Menu validation for windows that route ⌘Z / ⇧⌘Z here ("Отменить «Переименование»").
    /// Returns nil for other items.
    static func validate(_ item: NSMenuItem, in window: NSWindow) -> Bool? {
        let history = manager(for: window)
        switch item.action {
        case Selector(("undo:")):
            item.title = history.undoMenuItemTitle
            return history.canUndo
        case Selector(("redo:")):
            item.title = history.redoMenuItemTitle
            return history.canRedo
        default:
            return nil
        }
    }

    private final class Target {}
    private static let target = Target()

    /// Registers `undo` (and, through it, `redo`) under a menu name ("Отменить «Переименование»").
    private static func register(_ name: String, undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        manager.registerUndo(withTarget: target) { _ in
            MainActor.assumeIsolated {
                undo()
                register(name, undo: redo, redo: undo)
            }
        }
        manager.setActionName(name)
    }

    /// File work of undo / redo runs here, in order: a move across volumes or a copy can take long.
    nonisolated private static let queue = DispatchQueue(label: "dev.winex.undo", qos: .userInitiated)

    /// Runs `work` off the main thread; the first error stops it and is shown.
    private static func perform(_ work: @escaping @Sendable () throws -> Void) {
        queue.async {
            do {
                try work()
            } catch {
                let error = error as NSError
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Waits until undo / redo file work in progress is done (tests).
    nonisolated static func waitForFileWork() {
        queue.sync {}
    }

    /// Moves files; on failure shows the error and stops.
    private static func move(_ pairs: [(from: URL, to: URL)]) {
        perform {
            for pair in pairs { try FileManager.default.moveItem(at: pair.from, to: pair.to) }
        }
    }

    // MARK: Operations

    static func recordRename(from old: URL, to new: URL) {
        register(L("Переименование"), undo: { move([(new, old)]) }, redo: { move([(old, new)]) })
    }

    /// Cut & paste or drag: files went from `from` to `to`.
    static func recordMove(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        register(L("Перемещение"), undo: { move(pairs.map { ($0.to, $0.from) }) }, redo: { move(pairs) })
    }

    /// Copies are undone by sending them to the Trash (like Finder); redo copies again.
    static func recordCopy(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        register(L("Копирование"), undo: {
            silentlyTrash(pairs.map(\.to))
        }, redo: {
            perform {
                for pair in pairs { try FileManager.default.copyItem(at: pair.from, to: pair.to) }
            }
        })
    }

    /// Trashed items (original → where it is in the Trash): undo puts them back.
    static func recordTrash(_ moved: [URL: URL]) {
        guard !moved.isEmpty else { return }
        let pairs = moved.map { (from: $0.key, to: $0.value) }
        register(L("Перемещение в Корзину"), undo: { move(pairs.map { ($0.to, $0.from) }) }, redo: { move(pairs) })
    }

    /// A new folder / file: undo sends it to the Trash; redo brings it back.
    static func recordCreate(_ url: URL) {
        var trashed: URL?
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        register(isFolder ? L("Создание папки") : L("Создание файла"), undo: {
            trashed = silentlyTrash([url]).first
        }, redo: {
            if let trashed { move([(trashed, url)]) }
        })
    }

    /// Tags before a change; undo restores them, redo restores the tags after it.
    static func recordTags(before: [URL: [FileTags.Tag]]) {
        guard !before.isEmpty else { return }
        let after = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, FileTags.tags(of: $0)) })
        func apply(_ tags: [URL: [FileTags.Tag]]) {
            for (url, list) in tags { try? FileTags.setTags(list, on: url) }
            NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
        }
        register(L("Изменение тегов"), undo: { apply(before) }, redo: { apply(after) })
    }

    /// Moves to the Trash right away and returns the new locations.
    @discardableResult
    private static func silentlyTrash(_ urls: [URL]) -> [URL] {
        waitForFileWork()  // an earlier undo may still be moving these files
        return urls.compactMap { url in
            var result: NSURL?
            do { try FileManager.default.trashItem(at: url, resultingItemURL: &result) } catch { NSAlert(error: error).runModal() }
            return result as URL?
        }
    }
}
