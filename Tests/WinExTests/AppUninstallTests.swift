import Foundation
import Testing
@testable import WinEx

struct AppUninstallTests {
    let fm = FileManager.default

    /// A made-up ~/Library with `files` (paths inside it; a trailing "/" makes a folder).
    func library(_ files: [String]) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)", isDirectory: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            if file.hasSuffix("/") {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
        }
        return root
    }

    let app = AppUninstall.App(url: URL(fileURLWithPath: "/Applications/Foo.app"), name: "Foo", names: ["Foo", "FooApp"],
                               bundleID: "com.example.Foo", teamID: "ABCDE12345")

    func found(_ files: [String], others: Set<String> = [], otherNames: Set<String> = [], sameTeam: Bool = false) throws -> [String] {
        let root = try library(files)
        defer { try? fm.removeItem(at: root) }
        return AppUninstall.leftovers(of: app, userLibrary: root, systemLibrary: nil, otherBundleIDs: others,
                                      otherNames: otherNames, otherTeamApps: sameTeam)
            .map { String($0.url.path.dropFirst(root.path.count + 1)) + ($0.byName ? " (name)" : "") }
    }

    @Test func findsTheAppsFilesByItsID() throws {
        let result = try found([
            "Preferences/com.example.Foo.plist", "Preferences/ByHost/com.example.Foo.0F1E.plist",
            "Preferences/ByHost/com.example.Foo.ShipIt.0F0DCE92-C16A-522C-AC24-12BD2F670188.plist",
            "Application Support/com.example.Foo/", "Caches/com.example.foo/", "Caches/com.example.Foo.ShipIt/",
            "Containers/com.example.Foo/", "Saved Application State/com.example.Foo.savedState/",
            "LaunchAgents/com.example.Foo.helper.plist", "HTTPStorages/com.example.Foo.binarycookies",
            // Not its own
            "Preferences/com.example.Foobar.plist", "Caches/com.example/", "Preferences/com.other.Foo.plist",
            "Preferences/com.example.Foo.for.testing.plist",
        ])
        #expect(Set(result) == [
            "Preferences/com.example.Foo.plist", "Preferences/ByHost/com.example.Foo.0F1E.plist",
            "Preferences/ByHost/com.example.Foo.ShipIt.0F0DCE92-C16A-522C-AC24-12BD2F670188.plist",
            "Application Support/com.example.Foo", "Caches/com.example.foo", "Caches/com.example.Foo.ShipIt",
            "Containers/com.example.Foo", "Saved Application State/com.example.Foo.savedState",
            "LaunchAgents/com.example.Foo.helper.plist", "HTTPStorages/com.example.Foo.binarycookies",
        ])
    }

    @Test func leavesAnotherAppsLongerID() throws {
        // «com.example.Foo.Beta» is installed: its files aren't Foo's
        let result = try found(["Preferences/com.example.Foo.plist", "Preferences/com.example.Foo.Beta.plist",
                                "Caches/com.example.Foo.Beta/"], others: ["com.example.Foo.Beta"])
        #expect(result == ["Preferences/com.example.Foo.plist"])
    }

    @Test func groupContainersByIDAndTeam() throws {
        let files = ["Group Containers/ABCDE12345.com.example.Foo/", "Group Containers/group.com.example.Foo.shared/",
                     "Group Containers/ABCDE12345.shared/", "Group Containers/ZZZZZ99999.com.other/"]
        #expect(Set(try found(files)) == ["Group Containers/ABCDE12345.com.example.Foo",
                                          "Group Containers/group.com.example.Foo.shared", "Group Containers/ABCDE12345.shared"])
        // Another app of the team stays: the team's own container is shared, left alone
        #expect(Set(try found(files, sameTeam: true)) == ["Group Containers/ABCDE12345.com.example.Foo",
                                                         "Group Containers/group.com.example.Foo.shared"])
    }

    @Test func folderNamedLikeTheAppIsOfferedByName() throws {
        let files = ["Application Support/Foo/", "Caches/fooapp/", "Logs/Foo/", "Preferences/Foo/", "Application Support/Google/"]
        #expect(Set(try found(files)) == ["Application Support/Foo (name)", "Caches/fooapp (name)", "Logs/Foo (name)"])
        // …unless another app has that name
        #expect(Set(try found(files, otherNames: ["Foo"])) == ["Caches/fooapp (name)"])
    }

    @Test func systemLibraryNeedsTheAdministrator() throws {
        let user = try library([])
        let system = try library(["LaunchDaemons/com.example.Foo.helper.plist", "PrivilegedHelperTools/com.example.Foo.helper"])
        defer {
            try? fm.removeItem(at: user)
            try? fm.removeItem(at: system)
        }
        let result = AppUninstall.leftovers(of: app, userLibrary: user, systemLibrary: system, otherBundleIDs: [], otherNames: [], otherTeamApps: false)
        #expect(result.map(\.kind) == [.service, .service])
        // (Writable here: no password needed for a folder the user may change)
        #expect(result.allSatisfy { !$0.needsAdmin })
    }

    @Test func adminScriptQuotesAndKeepsNamesFree() throws {
        let trash = try library(["a.plist"])
        defer { try? fm.removeItem(at: trash) }
        let (script, moved) = AppUninstall.adminScript(moving: [URL(fileURLWithPath: "/Library/LaunchDaemons/a.plist"),
                                                                URL(fileURLWithPath: "/Library/It's here")], to: trash)
        #expect(moved.map(\.to.lastPathComponent) == ["a 2.plist", "It's here"])
        #expect(script.contains("launchctl bootout system '/Library/LaunchDaemons/a.plist'"))
        #expect(script.contains("'\(trash.path)/a 2.plist'"))
        #expect(script.contains("'/Library/It'\\''s here'"))
    }

    @Test func onlyRealAppsCanBeUninstalled() {
        #expect(AppUninstall.app(at: URL(fileURLWithPath: "/System/Applications/Notes.app")) == nil)
        #expect(AppUninstall.app(at: URL(fileURLWithPath: "/Applications/Safari.app")) == nil)   // (a link into the system)
        #expect(AppUninstall.app(at: URL(fileURLWithPath: "/tmp/nothing.app")) == nil)
    }

    @Test func findsHelpersRunningFromInsideTheBundle() throws {
        let root = try library([])
        defer { try? fm.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Foo.app")
        let helper = bundle.appendingPathComponent("Contents/MacOS/Foo Menu.app/Contents/MacOS/helper")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: helper)
        // (A copy of a system tool runs only signed anew)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", helper.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let path = AppUninstall.realPath(bundle)
        #expect(AppUninstall.processes(inside: [path]).contains(process.processIdentifier))
        #expect(!AppUninstall.processes(inside: [path + "x"]).contains(process.processIdentifier))
        #expect(AppUninstall.isInside("/A/Foo.app/Contents/x", ["/A/Foo.app"]) && !AppUninstall.isInside("/A/Foo.apps", ["/A/Foo.app"]))
    }

    @Test func permissionErrorsAskForTheAdministrator() throws {
        // Moving a folder of root's out of its parent: the error a put-back of an App Store app gets
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(Administrator.isPermissionError(error))
        #expect(Administrator.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        #expect(!Administrator.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)))
        #expect(Administrator.quoted("it's") == "'it'\\''s'")
    }
}
