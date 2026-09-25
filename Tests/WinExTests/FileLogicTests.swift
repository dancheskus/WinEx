import AppKit
import Testing
@testable import WinEx

/// A throwaway folder per test.
func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("winex-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct NamingTests {
    @Test func copyNamesCountUp() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileOps.uniqueDestination(for: "a.txt", in: dir).lastPathComponent == "a.txt")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: nil)
        #expect(FileOps.uniqueDestination(for: "a.txt", in: dir).lastPathComponent == "a - копия.txt")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a - копия.txt").path, contents: nil)
        #expect(FileOps.uniqueDestination(for: "a.txt", in: dir).lastPathComponent == "a - копия (2).txt")
    }

    @Test func newItemNamesKeepExtension() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileOps.newFolderURL(in: dir).lastPathComponent == "Новая папка")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Новая папка"), withIntermediateDirectories: false)
        #expect(FileOps.newFolderURL(in: dir).lastPathComponent == "Новая папка (2)")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Документ.txt").path, contents: nil)
        #expect(FileOps.newItemURL(named: "Документ.txt", in: dir).lastPathComponent == "Документ (2).txt")
    }

    @Test func renameSelectsNameWithoutExtension() {
        #expect(FileOps.baseNameRange(of: "report.final.docx", isFolder: false) == NSRange(location: 0, length: 12))
        #expect(FileOps.baseNameRange(of: "archive.zip", isFolder: true) == NSRange(location: 0, length: 11))
        #expect(FileOps.baseNameRange(of: "README", isFolder: false) == NSRange(location: 0, length: 6))
    }

    @Test(arguments: [(1, "элемент"), (2, "элемента"), (5, "элементов"), (11, "элементов"), (21, "элемент"), (104, "элемента"), (112, "элементов")])
    func russianPlural(_ n: Int, _ expected: String) {
        #expect(plural(n, "элемент", "элемента", "элементов") == expected)
    }
}

struct TabHistoryTests {
    @Test func backForwardUp() {
        let tab = ExplorerTab(url: URL(fileURLWithPath: "/Users"))
        tab.navigate(to: URL(fileURLWithPath: "/Users/Shared"))
        #expect(tab.canGoBack && !tab.canGoForward)
        tab.goBack()
        #expect(tab.url.path == "/Users" && tab.canGoForward)
        tab.goForward()
        tab.goUp()
        #expect(tab.url.path == "/Users")
        #expect(tab.pendingSelection.map(\.path) == ["/Users/Shared"])
    }

    @Test func tagLocationsAreNotFolders() {
        let url = Location.tagURL("Лиловый")
        #expect(Location(url) == .tag("Лиловый"))
        let tab = ExplorerTab(url: url)
        #expect(tab.title == "Лиловый" && !tab.canGoUp)
        // A folder whose path looks like the tag is still a different place
        tab.navigate(to: URL(fileURLWithPath: "/Лиловый"))
        #expect(tab.canGoBack)
    }

    @Test func locationsDecodeFromURLs() {
        #expect(Location(Places.networkURL) == .network)
        #expect(Location(Places.trashURL) == .trash)
        #expect(Location(Places.trashURL.appendingPathComponent("x")) != .trash)
        #expect(Location(URL(fileURLWithPath: "/Users/")) == Location(URL(fileURLWithPath: "/Users")))
        #expect(Location(Location.tagURL("Проект")).addressText == "Теги: Проект")
        #expect(Location(URL(fileURLWithPath: "/Users")).directory?.path == "/Users")
        #expect(Location(Places.networkURL).directory == nil)
    }
}

@MainActor
struct TagTests {
    @Test func tagsRoundTripWithColors() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        try FileTags.setTags([.init(name: "Лиловый", color: 3), .init(name: "Проект", color: 0)], on: file)
        #expect(FileTags.tags(of: file) == [.init(name: "Лиловый", color: 3), .init(name: "Проект", color: 0)])
        // Readable by the system too
        #expect((try file.resourceValues(forKeys: [.tagNamesKey])).tagNames == ["Лиловый", "Проект"])
        try FileTags.setTags([], on: file)
        #expect(FileTags.tags(of: file).isEmpty)
    }

    @Test func folderCustomizationUsesFindersFormat() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FolderCustomization.write(.symbol("star.fill"), to: dir)
        #expect(FolderCustomization.read(dir) == .symbol("star.fill"))
        try FolderCustomization.write(.emoji("🐱"), to: dir)
        #expect(FolderCustomization.read(dir) == .emoji("🐱"))
        try FolderCustomization.write(nil, to: dir)
        #expect(FolderCustomization.read(dir) == nil)
    }
}

@MainActor
struct UndoTests {
    /// Registers inside an explicit group (there's no event loop in tests).
    func step(_ body: () -> Void) {
        FileUndo.manager.groupsByEvent = false
        FileUndo.manager.beginUndoGrouping()
        body()
        FileUndo.manager.endUndoGrouping()
    }

    @Test func renameUndoRedo() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("a.txt"), new = dir.appendingPathComponent("b.txt")
        FileManager.default.createFile(atPath: old.path, contents: nil)
        try FileManager.default.moveItem(at: old, to: new)
        step { FileUndo.recordRename(from: old, to: new) }
        #expect(FileUndo.manager.undoActionName == "Переименование")
        FileUndo.manager.undo(); FileUndo.waitForFileWork()
        #expect(FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: new.path))
        FileUndo.manager.redo(); FileUndo.waitForFileWork()
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test func moveUndo() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let from = dir.appendingPathComponent("x.txt"), to = sub.appendingPathComponent("x.txt")
        FileManager.default.createFile(atPath: from.path, contents: nil)
        try FileManager.default.moveItem(at: from, to: to)
        step { FileUndo.recordMove([(from, to)]) }
        FileUndo.manager.undo(); FileUndo.waitForFileWork()
        #expect(FileManager.default.fileExists(atPath: from.path))
    }
}

@MainActor
struct ShortcutTests {
    /// A real keyboard sends ⇧⌘N as "N": every Shift chord must be written with the shifted character.
    @Test func shiftChordsUseShiftedCharacters() {
        _ = NSApplication.shared  // the menu builder registers the Window menu with NSApp
        let menu = MainMenu.build()
        let items = menu.items.compactMap(\.submenu).flatMap(\.items).filter { !$0.keyEquivalent.isEmpty }
        for item in items where item.keyEquivalentModifierMask.contains(.shift) {
            Issue.record("«\(item.title)» still uses \(item.keyEquivalent) + Shift")
        }
        #expect(items.contains { $0.title == "Новая папка" && $0.keyEquivalent == "N" })
        #expect(items.contains { $0.title == "Повторить" && $0.keyEquivalent == "Z" })
    }
}

@MainActor
struct ContextMenuTests {
    final class Actions: NSObject, FileMenuActions {
        func openSelected(_ sender: Any?) {}
        func quickLook(_ sender: Any?) {}
        func cut(_ sender: Any?) {}
        func copy(_ sender: Any?) {}
        func copyPath(_ sender: Any?) {}
        func renameSelected(_ sender: Any?) {}
        func moveToTrash(_ sender: Any?) {}
        func share(_ sender: Any?) {}
        func toggleTag(_ sender: NSMenuItem) {}
        func customizeFolder(_ sender: Any?) {}
        func showProperties(_ sender: Any?) {}
    }

    /// Folder windows and the desktop build the file menu the same way; every action reaches the target.
    @Test func fileMenuItemsAreWiredToTheTarget() {
        let target = Actions()
        let menu = NSMenu()
        FileContextMenu.addItems(to: menu, for: [URL(fileURLWithPath: "/Users")], target: target, folderTabs: true, customizableFolder: true)
        let titles = menu.items.map(\.title)
        for title in ["Открыть", "Открыть в новой вкладке", "Вырезать", "Переименовать", "Настроить папку…", "Свойства"] {
            #expect(titles.contains(title))
        }
        for item in menu.items where item.action != nil && item.submenu == nil {
            #expect(item.target === target, "«\(item.title)»")
        }
        let desktop = NSMenu()
        FileContextMenu.addItems(to: desktop, for: [URL(fileURLWithPath: "/Users")], target: target, folderTabs: false, customizableFolder: false)
        #expect(!desktop.items.contains { $0.title == "Открыть в новой вкладке" || $0.title == "Настроить папку…" })
    }
}

struct WindowPlacementTests {
    let left = WindowPlacement.Screen(id: "L", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050))
    let right = WindowPlacement.Screen(id: "R", frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
                                       visibleFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1410))
    let onRight = WindowPlacement.Saved(frame: CGRect(x: 2100, y: 200, width: 1000, height: 640), screenID: "R",
                                        screenFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))

    @Test func sameMonitorSameSpot() {
        #expect(WindowPlacement.frame(for: onRight, screens: [left, right]) == onRight.frame)
    }

    @Test func followsTheMonitorWhenRearranged() {
        var moved = right
        moved.frame.origin.x = -2560
        moved.visibleFrame.origin.x = -2560
        #expect(WindowPlacement.frame(for: onRight, screens: [left, moved]) == CGRect(x: -2380, y: 200, width: 1000, height: 640))
    }

    @Test func missingMonitorFallsBackToMainAndFits() {
        var big = onRight
        big.frame = CGRect(x: 1920 + 2000, y: 100, width: 2400, height: 1300)
        let frame = WindowPlacement.frame(for: big, screens: [left])
        #expect(frame == CGRect(x: 0, y: 0, width: 1920, height: 1050))
    }
}
