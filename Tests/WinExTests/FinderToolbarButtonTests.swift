import Foundation
import Testing
@testable import WinEx

/// Putting the "Open in WinEx" applet on Finder's toolbar (its stored configuration) and taking it off.
@MainActor @Suite struct FinderToolbarButtonTests {
    let app = URL(fileURLWithPath: "/Users/me/Applications/Open in WinEx.app")
    // A toolbar like a real one: a folder dragged on at position 4, the search field at the end
    let config: [String: Any] = [
        "TB Item Identifiers": ["com.apple.finder.BACK", "com.apple.finder.AirD", "com.apple.finder.SWCH", "NSToolbarSpaceItem",
                                "com.apple.finder.loc ", "com.apple.finder.ARNG", "com.apple.finder.SHAR", "com.apple.finder.LABL",
                                "com.apple.finder.ACTN", "NSToolbarSpaceItem", "NSToolbarSpaceItem", "com.apple.finder.SRCH"],
        "TB Item Plists": ["4": ["_CFURLString": "file:///.file/id=6571367.124218411/", "_CFURLStringType": 15]],
        "TB Display Mode": 2,
    ]

    @Test func addedBeforeTheSearchFieldKeepingTheOtherItem() {
        let added = FinderToolbarButton.adding(app, to: config)
        let ids = added["TB Item Identifiers"] as? [String] ?? []
        let plists = added["TB Item Plists"] as? [String: Any] ?? [:]
        #expect(ids.count == 13)
        #expect(ids[11] == "com.apple.finder.loc " && ids[12] == "com.apple.finder.SRCH")
        #expect((plists["11"] as? [String: Any])?["_CFURLString"] as? String == app.absoluteString)
        #expect((plists["4"] as? [String: Any])?["_CFURLString"] as? String == "file:///.file/id=6571367.124218411/")
        #expect(added["TB Display Mode"] as? Int == 2)
        // Twice: still once
        #expect((FinderToolbarButton.adding(app, to: added)["TB Item Identifiers"] as? [String])?.count == 13)
    }

    @Test func removedAsItWas() {
        let back = FinderToolbarButton.removing(app, from: FinderToolbarButton.adding(app, to: config))
        #expect(back["TB Item Identifiers"] as? [String] == config["TB Item Identifiers"] as? [String])
        #expect(Set((back["TB Item Plists"] as? [String: Any] ?? [:]).keys) == ["4"])
    }

    @Test func aToolbarNeverCustomisedStartsFromTheDefaults() {
        let added = FinderToolbarButton.adding(app, to: ["TB Default Item Identifiers": ["com.apple.finder.BACK", "com.apple.finder.SRCH"]])
        #expect(added["TB Item Identifiers"] as? [String] == ["com.apple.finder.BACK", "com.apple.finder.loc ", "com.apple.finder.SRCH"])
    }
}
