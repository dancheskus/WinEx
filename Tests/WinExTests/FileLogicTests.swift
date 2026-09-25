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
        func duplicate(_ sender: Any?) {}
        func compress(_ sender: Any?) {}
        func extractArchive(_ sender: Any?) {}
        func makeAlias(_ sender: Any?) {}
        func showOriginal(_ sender: Any?) {}
        func showPackageContents(_ sender: Any?) {}
    }

    /// Folder windows and the desktop build the file menu the same way; every action reaches the target.
    @Test func fileMenuItemsAreWiredToTheTarget() {
        let target = Actions()
        let menu = NSMenu()
        FileContextMenu.addItems(to: menu, for: [URL(fileURLWithPath: "/Users")], target: target, folderTabs: true, customizableFolder: true)
        // Titles carry their icon (an attachment) in front
        // …and the shortcut after a tab
        let titles = menu.items.map { ($0.title.components(separatedBy: "\t").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFC} ")) }
        for title in ["Открыть", "Открыть в новой вкладке", "Копировать путь", "Настроить папку…", "Свойства"] {
            #expect(titles.contains(title))
        }
        // Cut / copy / rename / share / delete are the row of buttons on top
        #expect(menu.items.first?.view != nil && !titles.contains("Вырезать"))
        #expect(menu.items.first { $0.title.contains("Свойства") }?.title.hasSuffix("\t⌘I") == true)
        #expect(menu.items.first { $0.title.contains("Дублировать") }?.attributedTitle?.containsAttachments == true)
        for item in menu.items where item.action != nil && item.submenu == nil {
            #expect(item.target === target, "«\(item.title)»")
        }
        let desktop = NSMenu()
        FileContextMenu.addItems(to: desktop, for: [URL(fileURLWithPath: "/Users")], target: target, folderTabs: false, customizableFolder: false)
        #expect(!desktop.items.contains { $0.title.contains("Открыть в новой вкладке") || $0.title.contains("Настроить папку…") })
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

struct FinderDesktopOptionsTests {
    @Test func mapsFindersViewOptions() {
        func options(_ size: Int, _ arrange: String) -> FinderDesktopLayout.ViewOptions {
            FinderDesktopLayout.viewOptions(["IconViewSettings": ["iconSize": size, "arrangeBy": arrange]])
        }
        #expect(options(64, "grid") == .init(iconSize: .medium, alignToGrid: true, autoArrange: false, sortKey: .name))
        #expect(options(100, "none") == .init(iconSize: .large, alignToGrid: false, autoArrange: false, sortKey: .name))
        #expect(options(36, "kind") == .init(iconSize: .small, alignToGrid: true, autoArrange: true, sortKey: .type))
        #expect(options(64, "dateAdded").sortKey == .date)
        #expect(FinderDesktopLayout.viewOptions(nil) == .init())
    }
}

@MainActor
struct WindowConstrainTests {
    /// Shown while another monitor is "current", a window must stay on its own monitor.
    @Test func staysOnItsOwnMonitor() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }  // needs two monitors
        let second = screens[1].visibleFrame
        let frame = NSRect(x: second.minX + 100, y: second.minY + 100, width: 800, height: 500)
        let window = ExplorerWindow(contentRect: .zero, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        #expect(window.constrainFrameRect(frame, to: screens[0]) == frame)
    }
}

struct DesktopLabelTests {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]
    func lines(_ name: String, width: CGFloat = 96) -> [String] {
        DesktopLabel.lines(NSAttributedString(string: name, attributes: attributes), width: width).map(\.string)
    }

    @Test func shortNamesStayOnOneLine() {
        #expect(lines("mafia") == ["mafia"])
    }

    @Test func breaksAfterAWord() {
        #expect(lines("Tabletop Simulator.docx") == ["Tabletop", "Simulator.docx"])
    }

    @Test func longWordsBreakInside() {
        let result = lines("account_confirmation.pdf")
        #expect(result.count == 2 && result.joined() == "account_confirmation.pdf")
    }

    /// The rest goes to the second line whole; drawing shortens it in the middle.
    @Test func secondLineIsMiddleTruncated() {
        let text = DesktopLabel.lines(NSAttributedString(string: "Снимок экрана — 2026-08-18 в 12.34.56.png", attributes: attributes), width: 96)
        #expect(text.count == 2)
        let style = text.last?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byTruncatingMiddle)
        #expect(text.last?.string.hasSuffix(".png") == true)
    }

    /// As many characters per line as Finder's desktop (usual 64 pt icons).
    @Test func finderWidthOfDesktopLabels() {
        let width = DesktopIconSize.medium.cellSize.width - 4
        #expect(lines("TorrServerMacInstaller", width: width) == ["TorrServerMacInst", "aller"])
        let tagged = NSMutableAttributedString(attributedString: FileTags.dots(for: [FileTags.Tag(name: "Зелёный", color: 2)], attributes: attributes))
        tagged.append(NSAttributedString(string: "Lugsy_icon.png", attributes: attributes))
        #expect(DesktopLabel.lines(tagged, width: width).count == 1)
    }

    /// Finder keeps the tag dot in front of the name, not alone on the line above it.
    @Test func tagDotStaysWithTheName() {
        let text = NSMutableAttributedString(attributedString: FileTags.dots(for: [FileTags.Tag(name: "Зелёный", color: 2)], attributes: attributes))
        text.append(NSAttributedString(string: "Lugsy_icon.png", attributes: attributes))
        for name in ["Lugsy_icon.png", "Tabletop Simulator.docx"] {
            text.replaceCharacters(in: NSRange(location: 2, length: text.length - 2), with: name)
            let result = DesktopLabel.lines(text, width: 96).map(\.string)
            #expect(result.first?.hasPrefix("●\u{00A0}") == true && (result.first?.count ?? 0) > 2)
        }
    }
}

struct SearchRequestTests {
    @Test func survivesTheTabURL() {
        let request = SearchRequest(text: "отчёт 2024", folder: URL(fileURLWithPath: "/Users/me/Документы"), wholeMac: false, contents: false)
        #expect(SearchRequest(url: request.url) == request)
        #expect(Location(request.url) == .search(request))
        #expect(Location(request.url).title == "Поиск «отчёт 2024»")
        #expect(Location(request.url).directory == nil)
    }

    @Test func everyWordMustBeInTheName() {
        let request = SearchRequest(text: "отчет 2024", folder: nil)
        #expect(request.nameMatches("Годовой ОТЧЁТ за 2024.pdf"))  // case and diacritics don't matter
        #expect(!request.nameMatches("Отчёт 2023.pdf"))
    }

    @Test func predicateMatchesNamesAndOptionallyContents() {
        let names = SearchRequest(text: "a*b", folder: nil, contents: false).predicate.predicateFormat
        #expect(names.contains("kMDItemFSName LIKE[cd]") && names.contains("a\\\\*b"))
        let both = SearchRequest(text: "план", folder: nil).predicate.predicateFormat
        #expect(both.contains("kMDItemTextContent CONTAINS[cd]"))
    }

    @Test func tooShortForTheWholeMac() {
        #expect(SearchRequest(text: "a", folder: nil, wholeMac: true).isTooShort)
        #expect(!SearchRequest(text: "a", folder: URL(fileURLWithPath: "/tmp")).isTooShort)
    }
}

/// NSMetadataQuery throws (and takes the app down) on predicates it can't translate to Spotlight:
/// start real queries with every shape of request.
@MainActor
struct SpotlightPredicateTests {
    @Test(arguments: ["отчёт", "годовой отчёт 2024", "a*b?c"], [true, false])
    func spotlightAcceptsThePredicate(_ text: String, _ contents: Bool) async {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let query = NSMetadataQuery()
        query.predicate = SearchRequest(text: text, folder: dir, contents: contents).predicate
        query.searchScopes = [dir]
        #expect(query.start())
        query.stop()
    }
}

@MainActor
struct UpdaterTests {
    @Test func versionOrder() {
        #expect(Updater.isVersion("1.10.0", newerThan: "1.9.2"))
        #expect(Updater.isVersion("1.0.1", newerThan: "1.0"))
        #expect(!Updater.isVersion("1.0", newerThan: "1.0.0"))
        #expect(!Updater.isVersion("0.9", newerThan: "1.0"))
    }

    @Test func readsGitHubReleases() throws {
        let json = """
            {"tag_name": "v1.2.0", "body": "Поиск", "html_url": "https://github.com/dancheskus/WinEx/releases/tag/v1.2.0",
             "assets": [{"name": "WinEx-1.2.0.zip", "browser_download_url": "https://example.com/WinEx-1.2.0.zip"},
                        {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"}]}
            """
        let release = try JSONDecoder().decode(Updater.Release.self, from: Data(json.utf8))
        #expect(release.version == "1.2.0" && release.archive?.name == "WinEx-1.2.0.zip")
    }
}
