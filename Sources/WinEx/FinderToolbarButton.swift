import AppKit

/// "Открыть в WinEx" for Finder's toolbar: a tiny AppleScript applet (in ~/Applications) the user
/// ⌘-drags onto the toolbar of a Finder window. A click closes that Finder window and opens the same
/// folder in WinEx, with the same items selected — for the places that always open Finder (the
/// Dock's stacks, apps that talk to Finder directly). The first click asks, once, to let it control
/// Finder (it has to read which folder the window shows and close it).
enum FinderToolbarButton {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(L("Открыть в WinEx")).app")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The applet's script: the front Finder window's folder (and its selection) → WinEx.
    static func script(bundleID: String) -> String {
        """
        on run
        \ttell application "Finder"
        \t\tif (count of Finder windows) is 0 then return
        \t\tset theWindow to front Finder window
        \t\ttry
        \t\t\tset theFolder to (target of theWindow) as alias
        \t\ton error
        \t\t\treturn
        \t\tend try
        \t\tset theItems to selection as alias list
        \t\tclose theWindow
        \tend tell
        \tset args to ""
        \tif (count of theItems) is 0 then
        \t\tset args to quoted form of POSIX path of theFolder
        \telse
        \t\trepeat with anItem in theItems
        \t\t\tset args to args & " " & quoted form of POSIX path of anItem
        \t\tend repeat
        \tend if
        \tdo shell script "/usr/bin/open -b \(bundleID) " & args
        end run
        """
    }

    /// Builds the applet at `destination` (replacing an older one): compiled, WinEx's icon, no Dock
    /// icon while it runs, why it wants Finder, signed again after those changes.
    static func install(at destination: URL = url) throws {
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.winex.WinEx"
        let source = fm.temporaryDirectory.appendingPathComponent("winex-finder-button.applescript")
        try script(bundleID: bundleID).write(to: source, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: source) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try run("/usr/bin/osacompile", "-o", destination.path, source.path)

        let contents = destination.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Info.plist")
        if let plist = NSMutableDictionary(contentsOf: plistURL) {
            plist["CFBundleIdentifier"] = bundleID + ".finder-button"
            plist["LSUIElement"] = true
            plist["NSAppleEventsUsageDescription"] = L("Чтобы узнать, какая папка открыта в окне Finder, закрыть его и открыть ту же папку в WinEx.")
            plist.write(to: plistURL, atomically: true)
        }
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            let target = contents.appendingPathComponent("Resources/applet.icns")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: icon, to: target)
        }
        try run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", destination.path)
        NSWorkspace.shared.noteFileSystemChanged(destination.path)
    }

    static func remove() {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Shows the applet in a Finder window (not WinEx's): from there it's ⌘-dragged onto the toolbar.
    static func showInFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Finder", "-R", url.path]
        try? process.run()
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "WinEx", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? tool : message])
        }
    }
}
