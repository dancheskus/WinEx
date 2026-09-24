import AppKit
import Network
import NetFS

/// Sidebar "Места" that aren't plain folders: the network, the Trash, AirDrop.
enum Places {
    // MARK: Network location

    static let networkURL = URL(string: "x-winex-network://network")!

    static func isNetwork(_ url: URL) -> Bool { url.scheme == networkURL.scheme }

    /// smb:// / afp:// server addresses (items of the "Сеть" location).
    static func isServer(_ url: URL) -> Bool { ["smb", "afp", "nfs", "ftp"].contains(url.scheme ?? "") }

    // MARK: Trash

    static var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    static func isTrash(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.standardizedFileURL.path == trashURL.standardizedFileURL.path
    }

    /// Original locations of trashed items, from the Trash's .DS_Store (`ptbL` folder + `ptbN` name).
    static func putBackLocations() -> [String: URL] {
        guard let data = try? Data(contentsOf: trashURL.appendingPathComponent(".DS_Store")) else { return [:] }
        var folders: [String: String] = [:], names: [String: String] = [:]
        try? FinderDesktopLayout.DSStore(bytes: [UInt8](data)).forEachRecord({ _, _, _ in }, strings: { name, structure, value in
            if structure == "ptbL" { folders[name] = value }
            if structure == "ptbN" { names[name] = value }
        })
        var result: [String: URL] = [:]
        for (item, folder) in folders {
            // ptbL is relative to the volume root ("Users/me/Desktop/")
            result[item] = URL(fileURLWithPath: "/" + folder).appendingPathComponent(names[item] ?? item)
        }
        return result
    }

    /// Moves items back to where they were deleted from. Returns the ones that couldn't be restored.
    @discardableResult
    static func putBack(_ urls: [URL]) -> [URL] {
        let locations = putBackLocations()
        var failed: [URL] = []
        for url in urls {
            guard let original = locations[url.lastPathComponent] else { failed.append(url); continue }
            let folder = original.deletingLastPathComponent()
            let destination = FileManager.default.fileExists(atPath: original.path)
                ? FileOps.uniqueDestination(for: original.lastPathComponent, in: folder) : original
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                failed.append(url)
            }
        }
        return failed
    }

    /// "Очистить корзину" / "Удалить навсегда", after confirmation.
    static func deleteForever(_ urls: [URL], emptying: Bool) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = emptying ? "Очистить Корзину?" : "Удалить \(urls.count == 1 ? "«\(urls[0].lastPathComponent)»" : "\(urls.count) объектов") навсегда?"
        alert.informativeText = "Это действие нельзя отменить."
        alert.alertStyle = .warning
        alert.addButton(withTitle: emptying ? "Очистить Корзину" : "Удалить")
        alert.addButton(withTitle: "Отменить")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls {
                do { try FileManager.default.removeItem(at: url) } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                    return
                }
            }
        }
    }

    /// Reading ~/.Trash needs Full Disk Access; this opens that pane of System Settings.
    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: AirDrop

    /// The system AirDrop window (it lives inside Finder).
    static func openAirDrop() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Network volumes

    /// For a mounted network share: the server it comes from ("NAS" for smb://user@NAS._smb._tcp.local/Daniel).
    static func serverName(ofVolume url: URL) -> String? {
        guard let remount = (try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting,
              let host = remount.host else { return nil }
        return host.components(separatedBy: ".").first
    }

    static func unmount(_ volume: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }
}

/// Finds file servers on the local network (Bonjour), like Finder's "Сеть".
@MainActor
final class NetworkBrowser {
    static let shared = NetworkBrowser()
    static let didChange = Notification.Name("WinExNetworkServersChanged")

    struct Server: Hashable {
        let name: String
        let url: URL
    }

    private(set) var servers: [Server] = []
    private var browsers: [NWBrowser] = []
    private var found: [String: Set<String>] = [:]  // type → names

    func start() {
        guard browsers.isEmpty else { return }
        for type in ["_smb._tcp", "_afpovertcp._tcp"] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names = Set(results.compactMap { result -> String? in
                    if case let .service(name, _, _, _) = result.endpoint { return name }
                    return nil
                })
                DispatchQueue.main.async { self?.update(type: type, names: names) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    private func update(type: String, names: Set<String>) {
        found[type] = names
        // One entry per server; prefer SMB, like Finder
        var byName: [String: Server] = [:]
        for name in found["_afpovertcp._tcp"] ?? [] { byName[name] = Server(name: name, url: Self.url("afp", name)) }
        for name in found["_smb._tcp"] ?? [] { byName[name] = Server(name: name, url: Self.url("smb", name)) }
        servers = byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func url(_ scheme: String, _ name: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = name.replacingOccurrences(of: " ", with: "-") + ".local"
        return components.url!
    }
}

/// Mounts a server with the system UI (login and, for a bare server, the share picker).
enum NetworkMounter {
    static func mount(_ url: URL, completion: @escaping @MainActor (URL?) -> Void) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, nil, &request, .main) { status, _, mountPoints in
            let path = (mountPoints as? [String])?.first
            MainActor.assumeIsolated {
                if status != 0, status != Int32(ECANCELED), status != Int32(EEXIST) {
                    NSAlert(error: NSError(domain: NSPOSIXErrorDomain, code: Int(status),
                                           userInfo: [NSLocalizedDescriptionKey: "Не удалось подключиться к «\(url.host ?? url.absoluteString)»."])).runModal()
                }
                completion(path.map { URL(fileURLWithPath: $0) } ?? existingMount(for: url))
            }
        }
        if status != 0 { MainActor.assumeIsolated { completion(nil) } }
    }

    /// Already mounted (NetFS answers EEXIST): find the share by server host.
    private static func existingMount(for url: URL) -> URL? {
        let host = url.host?.lowercased().replacingOccurrences(of: ".local", with: "")
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey]) ?? []).first { volume in
            let remount = (try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
            return remount?.host?.lowercased().hasPrefix(host ?? "\u{0}") == true
        }
    }

    /// "Подключиться к серверу…" (⌘K).
    @MainActor
    static func askAndMount(completion: @escaping @MainActor (URL?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Подключение к серверу"
        alert.informativeText = "Например: smb://NAS.local или afp://192.168.1.10/Share"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "lastServerAddress") ?? "smb://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Подключиться")
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "smb://" + text }
        guard let url = URL(string: text), url.host != nil else { NSSound.beep(); return }
        UserDefaults.standard.set(text, forKey: "lastServerAddress")
        mount(url, completion: completion)
    }
}
