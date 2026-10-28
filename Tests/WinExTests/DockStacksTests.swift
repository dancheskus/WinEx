import Foundation
import Testing
@testable import WinEx

struct DockStacksTests {
    let app = URL(fileURLWithPath: "/Users/me/Library/Application Support/WinEx/Dock.noindex/abc/Загрузки.app")
    let downloads = URL(fileURLWithPath: "/Users/me/Downloads")

    func folderTile(_ url: URL) -> [String: Any] {
        ["tile-type": "directory-tile",
         "tile-data": ["file-data": ["_CFURLString": url.absoluteString + "/", "_CFURLStringType": 15], "arrangement": 2, "showas": 1] as [String: Any]]
    }

    @Test func takesThePlaceOfTheDocksOwnStack() {
        let documents = folderTile(URL(fileURLWithPath: "/Users/me/Documents"))
        let others = [documents, folderTile(downloads)]
        let result = DockStacks.adding(app, label: "Загрузки", replacing: downloads, to: others)
        #expect(result.others.count == 2)
        #expect(DockStacks.index(of: app, in: result.others) == 1)
        #expect(result.replaced?["tile-type"] as? String == "directory-tile")
        // Taken away: the Dock's own stack back in its place, with its settings
        let back = DockStacks.removing(app, restoring: result.replaced, from: result.others)
        #expect(back.count == 2)
        #expect(DockStacks.index(of: downloads, in: back) == 1)
        #expect((back[1]["tile-data"] as? [String: Any])?["arrangement"] as? Int == 2)
    }

    @Test func goesAtTheEndWithoutAStackToReplace() {
        let others = [folderTile(URL(fileURLWithPath: "/Users/me/Documents"))]
        let result = DockStacks.adding(app, label: "Загрузки", replacing: downloads, to: others)
        #expect(result.others.count == 2)
        #expect(result.replaced == nil)
        #expect(DockStacks.url(of: result.others[1])?.path == app.path)
        // Added twice: once
        #expect(DockStacks.adding(app, label: "Загрузки", replacing: downloads, to: result.others).others.count == 2)
        #expect(DockStacks.removing(app, restoring: nil, from: result.others).count == 1)
    }

    @Test func theFolderBackInTheDockMeanwhileIsntDoubled() {
        let result = DockStacks.adding(app, label: "Загрузки", replacing: downloads, to: [folderTile(downloads)])
        let withFolderAgain = result.others + [folderTile(downloads)]
        let back = DockStacks.removing(app, restoring: result.replaced, from: withFolderAgain)
        #expect(back.count == 1)
    }

    @Test func sortsNewestFirstByDates() {
        var stack = DockStack(id: "x", path: "/tmp")
        stack.sort = .added
        #expect(stack.sortOrder == FileItem.SortOrder(key: "added", ascending: false))
        stack.sort = .name
        #expect(stack.sortOrder.ascending)
    }

    @Test func keepsTheDocksStackViewAndOrder() {
        let tile = folderTile(downloads)  // arrangement 2 (date added), showas 1 (fan)
        #expect(DockStacks.settings(of: tile)?.view == .fan)
        #expect(DockStacks.settings(of: tile)?.sort == .added)
        #expect(DockStacks.settings(of: ["tile-data": [String: Any]()])?.view == .automatic)
    }

    @Test func findsTheTileJustDroppedEvenWhenTheFolderIsThereTwice() {
        var old = folderTile(downloads)
        old["GUID"] = 1
        var dropped = folderTile(downloads)
        dropped["GUID"] = 2
        let known = Set([old].compactMap(DockStacks.tileKey))
        let found = DockStacks.newTiles(in: [old, dropped], known: known)
        #expect(found.count == 1)
        #expect(found.first?.key.hasPrefix("2|") == true)
        #expect(found.first?.path == downloads.path)
        // Apps and files in the Dock aren't folder stacks
        #expect(DockStacks.newTiles(in: [DockStacks.tile(for: app, label: "x")], known: []).isEmpty)
    }
}
