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
            // The icon: WinEx's file (the compiled asset catalog, which macOS prefers, goes)
            plist.removeObject(forKey: "CFBundleIconName")
            plist["CFBundleIconFile"] = "applet"
            plist["CFBundleIdentifier"] = bundleID + ".finder-button"
            plist["LSUIElement"] = true
            plist["NSAppleEventsUsageDescription"] = L("Чтобы узнать, какая папка открыта в окне Finder, закрыть его и открыть ту же папку в WinEx.")
            plist.write(to: plistURL, atomically: true)
        }
        try? fm.removeItem(at: contents.appendingPathComponent("Resources/Assets.car"))
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            let target = contents.appendingPathComponent("Resources/applet.icns")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: icon, to: target)
        }
        try run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", destination.path)
        NSWorkspace.shared.noteFileSystemChanged(destination.path)
    }

    static func remove() {
        if isOnToolbar { setOnToolbar(false) }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: Finder's toolbar

    private static let finder = "com.apple.finder" as CFString
    private static let toolbarKey = "NSToolbar Configuration Browser" as CFString
    private static let locationItem = "com.apple.finder.loc "

    private static var toolbar: [String: Any]? {
        CFPreferencesAppSynchronize(finder)
        return CFPreferencesCopyAppValue(toolbarKey, finder) as? [String: Any]
    }

    /// Whether the button is on Finder's toolbar (put there by hand or by WinEx).
    static var isOnToolbar: Bool {
        guard let config = toolbar else { return false }
        return index(of: url, in: config) != nil
    }

    /// The toolbar configuration with the applet at `app` added before the search field (or at the
    /// end) — as Finder stores an app ⌘-dragged onto it.
    static func adding(_ app: URL, to config: [String: Any]) -> [String: Any] {
        guard index(of: app, in: config) == nil else { return config }
        var config = config
        var identifiers = config["TB Item Identifiers"] as? [String] ?? (config["TB Default Item Identifiers"] as? [String]) ?? []
        var plists = config["TB Item Plists"] as? [String: Any] ?? [:]
        // Items after the insertion point would shift, and their stored details are keyed by position
        let search = identifiers.firstIndex(of: "com.apple.finder.SRCH") ?? identifiers.count
        let lastKeyed = plists.keys.compactMap(Int.init).max() ?? -1
        let at = search > lastKeyed ? search : identifiers.count
        identifiers.insert(locationItem, at: at)
        plists[String(at)] = ["_CFURLString": app.absoluteString, "_CFURLStringType": 15]
        config["TB Item Identifiers"] = identifiers
        config["TB Item Plists"] = plists
        return config
    }

    /// The toolbar configuration without the applet at `app` (later items' details moved up).
    static func removing(_ app: URL, from config: [String: Any]) -> [String: Any] {
        guard let at = index(of: app, in: config) else { return config }
        var config = config
        var identifiers = config["TB Item Identifiers"] as? [String] ?? []
        let plists = config["TB Item Plists"] as? [String: Any] ?? [:]
        identifiers.remove(at: at)
        var moved: [String: Any] = [:]
        for (key, value) in plists {
            guard let n = Int(key), n != at else { continue }
            moved[String(n > at ? n - 1 : n)] = value
        }
        config["TB Item Identifiers"] = identifiers
        config["TB Item Plists"] = moved
        return config
    }

    private static func index(of app: URL, in config: [String: Any]) -> Int? {
        let plists = config["TB Item Plists"] as? [String: Any] ?? [:]
        let identifiers = config["TB Item Identifiers"] as? [String] ?? []
        let wanted = app.standardizedFileURL.path
        for (key, value) in plists {
            guard let n = Int(key), identifiers.indices.contains(n), identifiers[n] == locationItem,
                  let string = (value as? [String: Any])?["_CFURLString"] as? String,
                  let itemURL = URL(string: string), itemURL.isFileURL,
                  itemURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == wanted.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { continue }
            return n
        }
        return nil
    }

    /// Puts the button on Finder's toolbar (or takes it off) and restarts Finder, which reads its
    /// toolbar only when it starts (its windows close and come back).
    static func setOnToolbar(_ on: Bool) {
        let current = toolbar ?? [:]
        let changed = on ? adding(url, to: current) : removing(url, from: current)
        CFPreferencesSetAppValue(toolbarKey, changed as CFDictionary, finder)
        CFPreferencesAppSynchronize(finder)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
        process.waitUntilExit()
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
