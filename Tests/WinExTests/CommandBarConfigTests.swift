import Testing
@testable import WinEx

/// The command bar's list: what's kept, where a dragged command lands.
@Suite struct CommandBarConfigTests {
    let d = CommandBarConfig.divider

    @Test func unknownAndRepeatedCommandsAndStrayDividersGo() {
        #expect(CommandBarConfig.sanitized([d, "cut", "cut", "future", d, d, "copy", d]) == ["cut", d, "copy"])
    }

    @Test func theDefaultSetIsClean() {
        #expect(CommandBarConfig.sanitized(CommandBarConfig.defaultItems) == CommandBarConfig.defaultItems)
    }

    @Test func aCommandMovesToTheRight() {
        // "cut" from 0 dropped before "paste" (index 2): after "copy"
        #expect(CommandBarConfig.dropping("cut", from: 0, at: 2, into: ["cut", "copy", "paste"]) == ["copy", "cut", "paste"])
    }

    @Test func aCommandMovesToTheLeft() {
        #expect(CommandBarConfig.dropping("paste", from: 2, at: 0, into: ["cut", "copy", "paste"]) == ["paste", "cut", "copy"])
    }

    @Test func aNewCommandIsAdded() {
        #expect(CommandBarConfig.dropping("terminal", from: nil, at: 1, into: ["cut", "copy"]) == ["cut", "terminal", "copy"])
    }

    @Test func aCommandAlreadyThereMovesInsteadOfDoubling() {
        #expect(CommandBarConfig.dropping("copy", from: nil, at: 0, into: ["cut", "copy"]) == ["copy", "cut"])
    }

    @Test func dividersMayRepeat() {
        #expect(CommandBarConfig.dropping(d, from: nil, at: 1, into: ["cut", d, "copy"]) == ["cut", d, d, "copy"])
    }

    @Test func aDividerMovesItself() {
        #expect(CommandBarConfig.dropping(d, from: 1, at: 3, into: ["cut", d, "copy", "paste"]) == ["cut", "copy", d, "paste"])
    }

    @Test func everyCommandHasAnAction() {
        // Pull-downs have menus; the rest have something to show and say
        for command in BarCommand.allCases {
            #expect(!command.symbol.isEmpty && !command.title.isEmpty)
        }
    }
}
