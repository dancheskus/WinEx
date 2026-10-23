import Foundation
import Testing
@testable import WinEx

struct AppsConfigTests {
    @Test func typedExtensionsOfferAnAppMacOSDoesNot() {
        // TextEdit doesn't say it opens .xyz: the extension typed in offers it anyway
        let app = AppsConfig.App(path: "/System/Applications/TextEdit.app", scope: .system, extensions: ["xyz"])
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("заметка.xyz"), other = dir.appendingPathComponent("заметка.abc")
        for url in [file, other] { FileManager.default.createFile(atPath: url.path, contents: Data()) }
        #expect(app.applies(to: [file]))
        #expect(!app.applies(to: [other]))
        // No extensions: only what macOS offers it for
        #expect(!AppsConfig.App(path: "/System/Applications/TextEdit.app", scope: .system).applies(to: [file]))
    }
}
