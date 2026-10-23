import AppKit
import DiskArbitration
import Network
import NetFS
import SystemConfiguration

/// Sidebar "Места" that aren't plain folders: the network, the Trash, AirDrop.
enum Places {
    // MARK: Network location

    static let networkURL = URL(string: "x-winex-network://network")!
    /// "Этот Mac": every drive with its free space, like "This PC".
    static let computerURL = URL(string: "x-winex-computer://computer")!
    /// «Недавние»: files opened lately, newest first, like Finder's Recents.
    static let recentsURL = URL(string: "x-winex-recents://recents")!
    /// «Общий доступ»: iCloud Drive items shared with others or with you, like Finder's Shared.
    static let sharedURL = URL(string: "x-winex-shared://shared")!
    /// An iPhone or iPad: its page (`x-winex-device://<UDID>`).
    static let deviceScheme = "x-winex-device"

    static func deviceURL(_ udid: String, path: String = "") -> URL {
        var components = URLComponents()
        components.scheme = deviceScheme
        components.host = udid
        components.path = path
        return components.url ?? computerURL
    }

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
        var moved: [(from: URL, to: URL)] = []
        defer { MainActor.assumeIsolated { FileUndo.recordMove(moved) } }
        for url in urls {
            guard let original = locations[url.lastPathComponent] else { failed.append(url); continue }
            let folder = original.deletingLastPathComponent()
            let destination = FileManager.default.fileExists(atPath: original.path)
                ? FileOps.uniqueDestination(for: original.lastPathComponent, in: folder) : original
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                moved.append((url, destination))
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
        alert.messageText = emptying ? L("Очистить Корзину?") : L("Удалить %@ навсегда?", urls.count == 1 ? "«\(urls[0].lastPathComponent)»" : L("%@ объектов", urls.count))
        alert.informativeText = L("Это действие нельзя отменить.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: emptying ? L("Очистить Корзину") : L("Удалить"))
        alert.addButton(withTitle: L("Отменить"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MainActor.assumeIsolated { FileOperations.start(.delete, urls) }
    }

    /// "Очистить Корзину": everything in the Trash, after the usual question.
    static func emptyTrash() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent != ".DS_Store" } ?? []
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        deleteForever(urls, emptying: true)
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
        remountURL(of: url).flatMap(serverName(of:))
    }

    /// A server's name as Finder shows it: "NAS" for NAS._smb._tcp.local and for NAS.local
    /// (the same server reached by its Bonjour name or its host name); an address stays as it is.
    static func serverName(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", ".local"] where host.lowercased().hasSuffix(suffix) {
            return String(host.dropLast(suffix.count))
        }
        return host
    }

    /// The server of a mounted share, as a location (smb://NAS._smb._tcp.local).
    static func serverURL(ofVolume url: URL) -> URL? {
        remountURL(of: url).flatMap(serverRoot)
    }

    /// `url` without its user and share: the server itself.
    static func serverRoot(_ url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host(percentEncoded: true), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.percentEncodedHost = host
        components.port = url.port
        return components.url
    }

    /// A server's address with no share: shown as a list of its shares.
    static func isServerRoot(_ url: URL) -> Bool {
        isServer(url) && url.host != nil && (url.path.isEmpty || url.path == "/")
    }

    /// A whole SMB or AFP server: shown as the list of its shares (other kinds mount as given).
    static func listsShares(_ url: URL) -> Bool {
        ["smb", "afp"].contains(url.scheme ?? "") && isServerRoot(url)
    }

    /// The same server, however it's spelled (by name, Bonjour name, case).
    static func sameServer(_ a: URL, _ b: URL) -> Bool {
        guard let x = serverName(of: a), let y = serverName(of: b) else { return false }
        return x.caseInsensitiveCompare(y) == .orderedSame
    }

    /// The network shares mounted now (Finder's or WinEx's), with the address each was mounted from.
    /// (From the mount table: a share whose server is gone doesn't hold anything up.)
    static func mountedShares() -> [(volume: URL, remount: URL)] {
        MountTable.networkMounts().compactMap { mount in
            guard !mount.isHidden, let remount = mount.remount else { return nil }
            return (mount.volume, remount)
        }
    }

    /// The server of each mounted share, remembered: once ejected, a share can't say where it was from.
    @MainActor private static var serverOfShare: [String: URL] = [:]

    /// Notes the servers of the shares mounted now (at launch and after each mount).
    @MainActor
    static func rememberShareServers() {
        for share in mountedShares() {
            if let server = serverRoot(share.remount) { serverOfShare[share.volume.standardizedFileURL.path] = server }
        }
    }

    /// The server an ejected share came from.
    @MainActor
    static func server(ofEjected volume: URL) -> URL? {
        serverOfShare.removeValue(forKey: volume.standardizedFileURL.path)
    }

    /// The shares of `server` that are mounted now.
    static func mountedShares(on server: URL) -> [(volume: URL, remount: URL)] {
        mountedShares().filter { sameServer($0.remount, server) }
    }

    /// "Daniel" for smb://user@NAS/Daniel.
    static func shareName(of url: URL) -> String {
        url.path(percentEncoded: false).trimmingCharacters(in: ["/"])
    }

    private static func remountURL(of volume: URL) -> URL? {
        MountTable.networkMount(at: volume)?.remount
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

    /// "⏏" on a server, «Отключить», «Извлечь «NAS»»: every share of it ejected, the login
    /// forgotten, and windows showing it go to "Сеть" — as Finder does.
    @MainActor
    static func disconnect(_ server: URL) {
        for share in mountedShares(on: server) { unmount(share.volume) }
        ServerShares.setConnected(server, false)
        for controller in AppDelegate.shared.windowControllers { controller.leaveServer(server) }
    }
}

/// The mounted volumes as the kernel lists them, read without waiting for any of them: which are
/// network shares and where each came from. Asking a share itself (its name, whether it's local,
/// its address) goes to its server, and when the server is gone — another network, the NAS off —
/// every such question waits seconds for it; the mount table answers at once.
enum MountTable {
    struct Mount {
        let volume: URL
        /// Not shown in Finder (mounted "nobrowse").
        let isHidden: Bool
        /// smb://user@NAS._smb._tcp.local/Daniel: the address it was mounted from.
        let remount: URL?
    }

    private static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "ftp"]

    /// The network shares mounted now.
    static func networkMounts() -> [Mount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // (Room for a few more, mounted meanwhile; getfsstat fills what fits)
        let capacity = Int(count) + 8
        let table = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { table.deallocate() }
        let filled = getfsstat(table, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return (0..<Int(min(filled, Int32(capacity)))).compactMap { index in
            var entry = table[index]
            let type = string(&entry.f_fstypename)
            guard networkTypes.contains(type) else { return nil }
            return Mount(volume: URL(fileURLWithPath: string(&entry.f_mntonname), isDirectory: true),
                         isHidden: entry.f_flags & UInt32(MNT_DONTBROWSE) != 0,
                         remount: remountURL(type: type, from: string(&entry.f_mntfromname)))
        }
    }

    /// The network share mounted at `volume`, if it is one.
    static func networkMount(at volume: URL) -> Mount? {
        let path = volume.standardizedFileURL.path
        return networkMounts().first { $0.volume.standardizedFileURL.path == path }
    }

    /// What the mount table says a share was mounted from ("//user@NAS._smb._tcp.local/Daniel"),
    /// as an address (smb://user@NAS._smb._tcp.local/Daniel).
    static func remountURL(type: String, from source: String) -> URL? {
        // (The login method, "user;AUTH=…@host", isn't part of the address)
        let source = source.replacingOccurrences(of: ";AUTH=[^@]*", with: "", options: [.regularExpression, .caseInsensitive])
        let address: String
        switch type {
        case "smbfs": address = "smb:" + source
        case "afpfs": address = "afp:" + source
        case "nfs":
            // host:/path
            guard let colon = source.firstIndex(of: ":") else { return nil }
            address = "nfs://" + source[..<colon] + source[source.index(after: colon)...]
        default: address = source   // webdav, ftp: the address itself
        }
        guard address.contains("://") else { return nil }
        return URL(string: address)
            ?? address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }

    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The shares a server offers, mounted or not (Finder's server window). Read as Finder reads them:
/// macOS's NetAuth logs in to the server (with the password saved in the keychain, else its own
/// login window) and lists the shares, mounting nothing.
enum ServerShares {
    struct Share: Equatable {
        let name: String
        /// Where it is mounted, if it is.
        let volume: URL?
        /// smb://user@server/share, to mount it.
        let url: URL
    }

    struct Listing {
        let shares: [Share]
        /// Who the server let in ("dancheskus"); nil for a guest.
        let user: String?
    }

    /// How to log in: only with a saved password (refreshing a shown list), with the system login
    /// window when there's none (opening the server, as Finder does), or always asking
    /// («Подключиться как…»).
    enum Login: String {
        case silent = "NoUI", allowed = "AllowUI", ask = "ForceUI"
    }

    /// Servers logged in to (their shares listed), as Finder's "connected" ones: shown in the
    /// sidebar even with nothing mounted, until disconnected — after WinEx restarts too.
    @MainActor private(set) static var connected: [URL] =
        (AppDefaults.store.stringArray(forKey: connectedKey) ?? []).compactMap(URL.init(string:))
    private static let connectedKey = "connectedServers"
    static let connectionsChanged = Notification.Name("WinExServerConnectionsChanged")

    @MainActor
    static func setConnected(_ server: URL, _ isConnected: Bool) {
        let known = connected.contains { Places.sameServer($0, server) }
        guard known != isConnected else { return }
        if isConnected { connected.append(server) } else { connected.removeAll { Places.sameServer($0, server) } }
        AppDefaults.store.set(connected.map(\.absoluteString), forKey: connectedKey)
        NotificationCenter.default.post(name: connectionsChanged, object: nil)
    }

    /// Runs `handler` on the main thread whenever a server is connected or disconnected.
    static func observeConnections(_ handler: @escaping @MainActor () -> Void) {
        NotificationCenter.default.addObserver(forName: connectionsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Last lists read, by server name: shown at once while a fresh one is read.
    @MainActor private static var known: [String: (names: [String], user: String?)] = [:]

    @MainActor
    static func cached(_ server: URL) -> Listing? {
        guard let key = Places.serverName(of: server)?.lowercased(), let entry = known[key] else { return nil }
        return listing(entry.names, user: entry.user, on: server)
    }

    /// Reads the list in the background; `nil` when the server didn't let us in (or the login was cancelled).
    @MainActor
    static func list(_ server: URL, login: Login, completion: @escaping @MainActor (Listing?) -> Void) {
        guard let key = Places.serverName(of: server)?.lowercased() else { return completion(nil) }
        // The user it's mounted as, so the same account is used
        let mountedUser = Places.mountedShares(on: server).lazy.compactMap { $0.remount.user(percentEncoded: true) }.first
        var components = URLComponents()
        components.scheme = server.scheme
        components.percentEncodedUser = mountedUser
        components.percentEncodedHost = server.host(percentEncoded: true)
        components.port = server.port
        let address = components.url ?? server
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NetAuth.shares(of: address, login: login)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let result else { return completion(nil) }
                    setConnected(server, true)
                    ServerReachability.reached(server)
                    let user = result.user ?? mountedUser?.removingPercentEncoding
                    known[key] = (result.names, user)
                    completion(listing(result.names, user: user, on: server))
                }
            }
        }
    }

    @MainActor
    private static func listing(_ names: [String], user: String?, on server: URL) -> Listing {
        let mounted = Places.mountedShares(on: server)
        let shares = names.map { name in
            let volume = mounted.first { Places.shareName(of: $0.remount).caseInsensitiveCompare(name) == .orderedSame }?.volume
            var components = URLComponents()
            components.scheme = server.scheme
            components.user = user
            components.percentEncodedHost = server.host(percentEncoded: true)
            components.port = server.port
            components.path = "/" + name
            return Share(name: name, volume: volume, url: components.url ?? server)
        }
        return Listing(shares: shares, user: user)
    }

    /// NetAuth's share list → the names of the disk shares (not IPC$ and other hidden ones).
    static func diskShares(_ list: [String: Any]) -> [String] {
        list.compactMap { name, info in
            let type = (info as? [String: Any])?["NetShareTypeStr"] as? String
            return name.isEmpty || name.hasSuffix("$") || (type != nil && type != "Disk") ? nil : name
        }
    }
}

/// The few calls of macOS's NetAuth (a private framework: it's what Finder uses to log in to a
/// server and list its shares). Looked up at run time: if a macOS release drops them, servers
/// show no list instead of WinEx failing to start.
private enum NetAuth {
    private typealias Connection = UnsafeMutableRawPointer
    private typealias OpenSession = @convention(c) (CFURL, CFDictionary?, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?,
                                                    UnsafeMutablePointer<Connection?>) -> Int32
    private typealias EnumerateShares = @convention(c) (Connection?, CFDictionary?, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int32
    private typealias CloseSession = @convention(c) (Connection?) -> Int32

    private static let library = dlopen("/System/Library/PrivateFrameworks/NetAuth.framework/NetAuth", RTLD_NOW)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// Logs in (blocking: run it off the main thread), lists the shares, logs out.
    static func shares(of server: URL, login: ServerShares.Login) -> (names: [String], user: String?)? {
        guard let open = function("NAOpenSessionSync", as: OpenSession.self),
              let enumerate = function("NAEnumerateSharesSync", as: EnumerateShares.self),
              let close = function("NACloseSessionSync", as: CloseSession.self) else { return nil }
        var connection: Connection?
        var sessionInfo: Unmanaged<CFDictionary>?
        // (SuggestedIcon: the login window shows a server, as Finder's does, not a network disk)
        let options = ["UIOption": login.rawValue, "SuggestedIcon": "com.apple.xserve"] as CFDictionary
        guard open(server as CFURL, options, &sessionInfo, &connection) == 0, connection != nil else { return nil }
        defer { _ = close(connection) }
        let session = sessionInfo?.takeRetainedValue() as? [String: Any]
        var list: Unmanaged<CFDictionary>?
        guard enumerate(connection, nil, &list) == 0, let shares = list?.takeRetainedValue() as? [String: Any] else { return nil }
        return (ServerShares.diskShares(shares), session?["MountedByUser"] as? String)
    }
}

/// Whether the servers logged in to with nothing mounted answer from here. Away from home the NAS
/// leaves the sidebar — still remembered, it comes back once it answers again. Checked at launch
/// and when the network changes (Wi‑Fi, VPN, waking elsewhere): one short connection attempt per
/// server, nothing in between.
@MainActor
enum ServerReachability {
    static let didChange = Notification.Name("WinExServerReachabilityChanged")

    /// Server names (lowercased) that didn't answer at the last check.
    private static var unreachable: Set<String> = []
    private static var monitor: NWPathMonitor?
    private static var pendingCheck: DispatchWorkItem?
    private static var generation = 0

    static func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        // (Called once at the start too: the first check)
        monitor.pathUpdateHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { scheduleCheck() } }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
        ServerShares.observeConnections { scheduleCheck() }
    }

    static func isReachable(_ server: URL) -> Bool {
        guard let key = Places.serverName(of: server)?.lowercased() else { return true }
        return !unreachable.contains(key)
    }

    /// The server just let us in: it's here.
    static func reached(_ server: URL) {
        guard let key = Places.serverName(of: server)?.lowercased(), unreachable.remove(key) != nil else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// A network changing comes in several steps (Wi‑Fi joins, the address comes, the VPN follows):
    /// checked once it has settled.
    private static func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { check() } }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private static func check() {
        generation += 1
        let token = generation
        // (One per server name: the same server reached two ways is asked once)
        var servers: [String: URL] = [:]
        for server in ServerShares.connected {
            if let key = Places.serverName(of: server)?.lowercased(), servers[key] == nil { servers[key] = server }
        }
        var answers: [String: Bool] = [:]
        func apply() {
            guard token == generation else { return }
            let now = Set(answers.filter { !$0.value }.keys)
            guard now != unreachable else { return }
            unreachable = now
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        guard !servers.isEmpty else { return apply() }
        for (key, server) in servers {
            probe(server) { answered in
                answers[key] = answered
                if answers.count == servers.count { apply() }
            }
        }
    }

    /// One TCP connection to the server's file-sharing port, given up after a few seconds.
    private static func probe(_ server: URL, completion: @escaping @MainActor (Bool) -> Void) {
        guard let host = server.host(percentEncoded: false), !host.isEmpty else { return completion(true) }
        let endpoint: NWEndpoint
        let lowered = host.lowercased()
        if let type = ["._smb._tcp.local": "_smb._tcp", "._afpovertcp._tcp.local": "_afpovertcp._tcp"]
            .first(where: { lowered.hasSuffix($0.key) }) {
            // A Bonjour name: found the way Finder finds it, on the network the Mac is on
            endpoint = .service(name: String(host.dropLast(type.key.count)), type: type.value, domain: "local.", interface: nil)
        } else {
            let standard: Int = server.scheme == "afp" ? 548 : server.scheme == "nfs" ? 2049 : 445
            endpoint = .hostPort(host: .init(host), port: NWEndpoint.Port(rawValue: UInt16(server.port ?? standard)) ?? 445)
        }
        let connection = NWConnection(to: endpoint, using: .tcp)
        var finished = false
        func finish(_ answered: Bool) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(answered)
        }
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: finish(true)
                // (Local network access not allowed: whether it's there can't be told — not hidden)
                case .failed(let error), .waiting(let error): finish(error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { finish(false) } }
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

    /// The servers found, and those connected to by address (shown in "Сеть" too, like Finder).
    var serversWithConnected: [Server] {
        var result = servers
        for share in Places.mountedShares() {
            guard let root = Places.serverRoot(share.remount), let name = Places.serverName(of: root),
                  !result.contains(where: { Places.sameServer($0.url, root) }) else { continue }
            result.append(Server(name: name, url: root))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var browsers: [NWBrowser] = []
    private var found: [String: Set<String>] = [:]  // type → names

    func start() {
        guard browsers.isEmpty else { return }
        for type in ["_smb._tcp", "_afpovertcp._tcp"] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                // This Mac advertises itself when File Sharing is on; Finder leaves it out
                let ownName = SCDynamicStoreCopyComputerName(nil, nil) as String?
                let names = Set(results.compactMap { result -> String? in
                    if case let .service(name, _, _, _) = result.endpoint, name != ownName { return name }
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
        // The Bonjour name, as Finder connects: the same server then shows once in Finder's sidebar
        components.percentEncodedHost = (name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name)
            + (scheme == "smb" ? "._smb._tcp.local" : "._afpovertcp._tcp.local")
        return components.url ?? Places.networkURL
    }
}

/// Mounts a server with the system UI (login and, for a bare server, the share picker).
enum NetworkMounter {
    static func mount(_ url: URL, completion: @escaping @MainActor (URL?) -> Void) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        openOptions["SuggestedIcon"] = "com.apple.xserve"
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, nil, &request, .main) { status, _, mountPoints in
            let path = (mountPoints as? [String])?.first
            MainActor.assumeIsolated {
                if status != 0, status != Int32(ECANCELED), status != Int32(EEXIST) {
                    NSAlert(error: NSError(domain: NSPOSIXErrorDomain, code: Int(status),
                                           userInfo: [NSLocalizedDescriptionKey: L("Не удалось подключиться к «%@».", Places.serverName(of: url) ?? url.absoluteString)])).runModal()
                }
                completion(path.map { URL(fileURLWithPath: $0) } ?? existingMount(for: url))
            }
        }
        if status != 0 { MainActor.assumeIsolated { completion(nil) } }
    }

    /// Where a share is mounted, if it is (NetFS answers EEXIST): that share of that server,
    /// however it was reached.
    static func existingMount(for url: URL) -> URL? {
        let share = Places.shareName(of: url)
        return Places.mountedShares(on: url).first { mounted in
            share.isEmpty || Places.shareName(of: mounted.remount).caseInsensitiveCompare(share) == .orderedSame
        }?.volume
    }

    /// "Подключиться к серверу…" (⌘K): the share mounted, or a whole server to show.
    @MainActor
    static func askAndMount(completion: @escaping @MainActor (URL?) -> Void) {
        ConnectToServerWindow.show { text in connect(to: text, completion: completion) }
    }

    @MainActor
    private static func connect(to text: String, completion: @escaping @MainActor (URL?) -> Void) {
        guard let url = URL(string: text), url.host != nil else { NSSound.beep(); return }
        ConnectToServerWindow.remember(text)
        // A whole server: its shares are listed (and mounted when opened)
        if Places.listsShares(url), Places.serverRoot(url) != nil {
            return completion(url)
        }
        mount(url, completion: completion)
    }
}


/// Mounted disk images (.dmg, .iso…): macOS's disk list says which disks are images.
enum DiskImageVolumes {
    nonisolated(unsafe) private static var known: [String: Bool] = [:]
    private static let lock = NSLock()

    /// `url` is the top folder of a mounted disk image.
    static func isRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/Volumes/") || path.hasPrefix("/private/var/folders/") || path.hasPrefix("/private/tmp/"),
              (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true else { return false }
        lock.lock()
        if let cached = known[path] { lock.unlock(); return cached }
        lock.unlock()
        var image = false
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
           let description = DADiskCopyDescription(disk) as? [String: Any] {
            image = (description[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces) == "Disk Image"
        }
        lock.lock()
        known[path] = image
        lock.unlock()
        return image
    }
}
