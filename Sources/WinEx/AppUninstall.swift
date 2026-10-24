import Foundation
import Security

/// What an app leaves behind in the Libraries: settings, caches, data, saved windows, login agents.
/// Found by the app's bundle ID (and team ID for shared containers), never by a loose name, so
/// nobody else's files are caught; a folder named exactly like the app is offered unchecked.
enum AppUninstall {
    /// The app being removed.
    struct App: Sendable {
        let url: URL
        /// As the file is named («Visual Studio Code»).
        let name: String
        /// What its folders may be called: the file's name and the bundle's («Code»).
        let names: [String]
        let bundleID: String
        let teamID: String?
    }

    enum Kind: Int, Sendable, Comparable {
        case settings, data, cache, logs, windows, autostart, service

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    struct Leftover: Sendable, Equatable {
        let url: URL
        let kind: Kind
        /// Found by the app's name only: shown, but unchecked.
        let byName: Bool
        /// In /Library or not ours to move: the administrator's password is needed.
        let needsAdmin: Bool
    }

    /// The app at `url`, if it's one that can be uninstalled: a real bundle (not a link to one),
    /// with a bundle ID, not part of macOS, not WinEx itself, not already in the Trash.
    static func app(at url: URL) -> App? {
        guard url.pathExtension.lowercased() == "app",
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return nil }
        let path = url.resolvingSymlinksInPath().path
        guard !path.hasPrefix("/System/"), !path.contains("/.Trash/"),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty,
              id != Bundle.main.bundleIdentifier else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        var names = [name]
        for key in ["CFBundleName", "CFBundleDisplayName"] {
            if let other = bundle.object(forInfoDictionaryKey: key) as? String, !other.isEmpty, !names.contains(other) { names.append(other) }
        }
        return App(url: url, name: name, names: names, bundleID: id, teamID: teamID(of: url))
    }

    /// The team that signed the app (nil: unsigned or signed ad hoc).
    static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Where to look, and what's found there.
    private static let userPlaces: [(String, Kind)] = [
        ("Preferences", .settings), ("Preferences/ByHost", .settings),
        ("Application Support", .data), ("Containers", .data), ("Group Containers", .data),
        ("Application Scripts", .data), ("HTTPStorages", .data), ("WebKit", .data), ("Cookies", .data),
        ("Caches", .cache), ("Logs", .logs),
        ("Saved Application State", .windows),
        ("LaunchAgents", .autostart),
    ]
    private static let systemPlaces: [(String, Kind)] = [
        ("Preferences", .settings), ("Application Support", .data), ("Caches", .cache), ("Logs", .logs),
        ("LaunchAgents", .autostart), ("LaunchDaemons", .service), ("PrivilegedHelperTools", .service),
    ]
    /// Places where apps keep a folder under their own name.
    private static let namedPlaces: Set<String> = ["Application Support", "Caches", "Logs"]

    /// Everything of `app` in `userLibrary` (~/Library) and `systemLibrary` (/Library).
    /// `otherBundleIDs`: the apps that stay (their files are left alone, e.g. «com.google.Chrome.canary»
    /// isn't Chrome's); `otherTeamApps`: another app of the same team stays (shared containers too).
    static func leftovers(of app: App, userLibrary: URL, systemLibrary: URL?,
                          otherBundleIDs: Set<String>, otherNames: Set<String>, otherTeamApps: Bool) -> [Leftover] {
        let id = app.bundleID.lowercased()
        let others = otherBundleIDs.map { $0.lowercased() }.filter { $0 != id }
        let appNames = Set(app.names.map { $0.lowercased() })
        let taken = Set(otherNames.map { $0.lowercased() })
        let fm = FileManager.default

        /// The name belongs to `id`: the ID itself, or the ID and one word after a dot
        /// («com.foo.app.plist», «com.foo.app.savedState», «com.foo.app.ShipIt.<UUID>.plist») —
        /// not more words: «com.google.chrome.for.testing» is another app.
        func belongs(_ file: String, to id: String) -> Bool {
            if file == id { return true }
            guard file.hasPrefix(id + ".") else { return false }
            var rest = file.dropFirst(id.count + 1).split(separator: ".").map(String.init)
            if let last = rest.last, ["plist", "savedstate", "binarycookies", "db", "log"].contains(last) { rest.removeLast() }
            // (A Mac's ID in ByHost settings)
            rest.removeAll { $0.count >= 8 && $0.allSatisfy { $0.isHexDigit || $0 == "-" } }
            return rest.count <= 1
        }
        func isOurs(_ file: String) -> Bool {
            let file = file.lowercased()
            guard belongs(file, to: id) else { return false }
            // …unless a longer ID that stays claims it
            return !others.contains { $0.hasPrefix(id + ".") && belongs(file, to: $0) }
        }
        /// A group container: «TEAM.com.foo.app», «group.com.foo.app.shared»; one only of the team
        /// («TEAM.shared») when no other app of that team stays.
        func isOurGroup(_ file: String) -> Bool {
            let file = file.lowercased()
            let parts = file.split(separator: ".").map(String.init)
            let idParts = id.split(separator: ".").map(String.init)
            if parts.count >= idParts.count {
                for start in 0...(parts.count - idParts.count) where Array(parts[start..<(start + idParts.count)]) == idParts {
                    // (the rest mustn't be another app's ID)
                    let rest = parts[start...].joined(separator: ".")
                    if !others.contains(where: { $0.hasPrefix(id + ".") && belongs(rest, to: $0) }) { return true }
                }
            }
            if let team = app.teamID?.lowercased(), file.hasPrefix(team + "."), !otherTeamApps { return true }
            return false
        }

        var found: [Leftover] = []
        var seen = Set<String>()
        func scan(_ library: URL, _ places: [(String, Kind)], system: Bool) {
            for (place, kind) in places {
                let folder = library.appendingPathComponent(place, isDirectory: true)
                guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
                let parentWritable = fm.isWritableFile(atPath: folder.path)
                for file in names {
                    let byID = place == "Group Containers" ? isOurGroup(file) : isOurs(file)
                    let byName = !byID && namedPlaces.contains(place) && appNames.contains(file.lowercased())
                        && !taken.contains(file.lowercased())
                    guard byID || byName else { continue }
                    let url = folder.appendingPathComponent(file)
                    guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                    found.append(Leftover(url: url, kind: kind, byName: byName, needsAdmin: system && !parentWritable))
                }
            }
        }
        scan(userLibrary, userPlaces, system: false)
        if let systemLibrary { scan(systemLibrary, systemPlaces, system: true) }
        return found.sorted { ($0.kind, $0.url.path) < ($1.kind, $1.url.path) }
    }

    /// The installed apps besides `app` (in the Applications folders, one level of subfolders):
    /// their bundle IDs, names and whether one has the same team.
    static func otherApps(than app: App) -> (ids: Set<String>, names: Set<String>, sameTeam: Bool) {
        let fm = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        if !app.url.path.contains("/.Trash/") { roots.append(app.url.deletingLastPathComponent()) }
        var apps: [URL] = []
        var seen = Set<String>()
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                let url = root.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    if seen.insert(url.path).inserted { apps.append(url) }
                } else if !name.hasPrefix("."), url.isBrowsableDirectory {
                    for inner in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        let innerURL = url.appendingPathComponent(inner)
                        if seen.insert(innerURL.path).inserted { apps.append(innerURL) }
                    }
                }
            }
        }
        let own = app.url.standardizedFileURL.path
        var ids = Set<String>(), names = Set<String>()
        var sameTeam = false
        for url in apps where url.standardizedFileURL.path != own {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            ids.insert(id)
            names.insert(url.deletingPathExtension().lastPathComponent)
            if !sameTeam, let team = app.teamID, teamID(of: url) == team { sameTeam = true }
        }
        return (ids, names, sameTeam)
    }

    /// The path as the system knows it (`realpath`: «/private/var/…», not Foundation's «/var/…»);
    /// a path that's gone, as it is.
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is one of `bundles` or inside one (a helper app, a login item, a tool).
    static func isInside(_ path: String, _ bundles: [String]) -> Bool {
        bundles.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The processes running from inside `bundles` (paths), WinEx aside: helpers that aren't apps
    /// macOS lists (background tools, agents).
    static func processes(inside bundles: [String]) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(found, 0)).filter { pid in
            guard pid > 0, pid != getpid(), proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return isInside(String(cString: path), bundles)
        }
    }

    /// Other copies of the same app (same bundle ID) that stay: their settings are the same files.
    static func otherCopies(of app: App, launchServices: [URL]) -> [URL] {
        let own = app.url.resolvingSymlinksInPath().standardizedFileURL.path
        return launchServices.filter {
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            // (A disk image it was installed from doesn't count)
            let readOnly = (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
            return path != own && !path.contains("/.Trash/") && !readOnly && FileManager.default.fileExists(atPath: path)
        }
    }

    /// A shell command line that moves `urls` into `trash` as root (the items out of the user's
    /// reach), unloading launch daemons and agents first; names already in the Trash get a suffix.
    /// Also returns where each one goes (to put it back later).
    static func adminScript(moving urls: [URL], to trash: URL) -> (script: String, moved: [(from: URL, to: URL)]) {
        let quoted = Administrator.quoted
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [])
        var commands: [String] = []
        var moved: [(from: URL, to: URL)] = []
        for url in urls {
            let folder = url.deletingLastPathComponent().lastPathComponent
            if url.pathExtension == "plist", folder == "LaunchDaemons" || folder == "LaunchAgents" {
                commands.append("launchctl bootout system \(quoted(url.path)) 2>/dev/null")
            }
            let name = url.lastPathComponent
            var target = name
            var n = 2
            while taken.contains(target) {
                let ext = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                target = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            taken.insert(target)
            moved.append((url, trash.appendingPathComponent(target)))
            commands.append("mv -n \(quoted(url.path)) \(quoted(trash.appendingPathComponent(target).path))")
        }
        return (commands.joined(separator: "; "), moved)
    }
}
