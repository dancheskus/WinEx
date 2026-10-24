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
    /// `owner`: a step of its own that can be taken back out of the history (see `lastTrash`).
    private static func register(_ name: String, owner: Target? = nil,
                                 undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        lastTrash = nil
        let owner = owner ?? target
        manager.registerUndo(withTarget: owner) { _ in
            MainActor.assumeIsolated {
                undo()
                register(name, owner: owner, undo: redo, redo: undo)
            }
        }
        manager.setActionName(name)
    }

    /// The last step, when it's a move to the Trash: what's trashed right after it as part of the
    /// same thing (an app's files after the app) joins it — one ⌘Z for both.
    private static var lastTrash: (owner: Target, moved: [URL: URL])?

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

    /// Moves files — apps first, each on its own: one that can't move (another app's protected
    /// folder) doesn't hold back the rest; root's ones are moved with the administrator's password;
    /// those that still didn't are named at the end.
    private static func move(_ pairs: [(from: URL, to: URL)]) {
        let ordered = pairs.filter { $0.to.pathExtension == "app" } + pairs.filter { $0.to.pathExtension != "app" }
        queue.async {
            var failed: [(name: String, error: Error)] = []
            var forbidden: [(from: URL, to: URL)] = []
            for pair in ordered {
                do { try FileManager.default.moveItem(at: pair.from, to: pair.to) } catch {
                    if Administrator.isPermissionError(error) { forbidden.append(pair) } else { failed.append((pair.to.lastPathComponent, error)) }
                }
            }
            // Root's items (an App Store app): with the administrator's password
            if !forbidden.isEmpty, !Administrator.move(forbidden) {
                let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
                failed += forbidden.filter { FileManager.default.fileExists(atPath: $0.from.path) }.map { ($0.to.lastPathComponent, error) }
            }
            guard let first = failed.first else { return }
            let names = failed.map(\.name).joined(separator: ", ")
            let detail = (first.error as NSError).localizedDescription
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = failed.count == 1 ? L("Не удалось вернуть «%@»", names) : L("Не удалось вернуть: %@", names)
                alert.informativeText = detail
                alert.runModal()
            }
        }
    }

    // MARK: Operations

    static func recordRename(from old: URL, to new: URL) {
        register(L("Переименование"), undo: { move([(new, old)]) }, redo: { move([(old, new)]) })
    }

    /// «Переименовать N объектов»: one step for all of them, in two passes (names may be swapped).
    static func recordBatchRename(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        let back = pairs.map { (from: $0.to, to: $0.from) }
        register(L("Переименование"), undo: { perform { try BatchRename.perform(back) } },
                 redo: { perform { try BatchRename.perform(pairs) } })
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
    /// `joining`: items trashed just before as the same thing; if that's still the last step, the
    /// two become one.
    static func recordTrash(_ moved: [URL: URL], joining earlier: [URL: URL]? = nil) {
        guard !moved.isEmpty else { return }
        var all = moved
        if let earlier, let last = lastTrash, !earlier.isEmpty, earlier.allSatisfy({ last.moved[$0.key] == $0.value }) {
            manager.removeAllActions(withTarget: last.owner)
            all.merge(last.moved) { new, _ in new }
        }
        let pairs = all.map { (from: $0.key, to: $0.value) }
        let owner = Target()
        register(L("Перемещение в Корзину"), owner: owner, undo: { move(pairs.map { ($0.to, $0.from) }) }, redo: { move(pairs) })
        lastTrash = (owner, all)
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
            if let trashed = result as URL? { Places.rememberTrashed([(url, trashed)]) }
            return result as URL?
        }
    }
}
