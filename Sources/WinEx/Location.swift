import AppKit
import UniformTypeIdentifiers

/// What a tab shows. Tabs, history and the sidebar store plain URLs; this decodes them:
/// a folder, the Trash (a folder with its own menu), all files with a tag, the network, a
/// server's shares, or search results.
enum Location: Equatable {
    case folder(URL)
    case trash
    case tag(String)
    case network
    /// A file server (smb://NAS._smb._tcp.local): its shares, mounted when opened.
    case server(URL)
    case computer
    case recents
    case shared
    /// An iPhone or iPad (by its UDID): its page, or (path «/<app id>/<folders…>») a folder of an
    /// app's Documents.
    case device(String, path: String)
    case search(SearchRequest)

    /// Tag locations use this URL scheme: `x-winex-tag://tag/<name>`.
    static let tagScheme = "x-winex-tag"

    init(_ url: URL) {
        if url.scheme == Places.networkURL.scheme {
            self = .network
        } else if Places.listsShares(url), let server = Places.serverRoot(url) {
            self = .server(server)
        } else if url.scheme == Places.computerURL.scheme {
            self = .computer
        } else if url.scheme == Places.recentsURL.scheme {
            self = .recents
        } else if url.scheme == Places.sharedURL.scheme {
            self = .shared
        } else if url.scheme == Places.deviceScheme {
            let path = url.path
            self = .device(url.host ?? "", path: path == "/" ? "" : path)
        } else if let request = SearchRequest(url: url) {
            self = .search(request)
        } else if url.scheme == Self.tagScheme {
            self = .tag(String(url.path.dropFirst()))
        } else if Places.isTrash(url) {
            self = .trash
        } else {
            self = .folder(url.standardizedFileURL)
        }
    }

    var url: URL {
        switch self {
        case .folder(let url): url
        case .trash: Places.trashURL
        case .tag(let name): Self.tagURL(name)
        case .network: Places.networkURL
        case .server(let url): url
        case .computer: Places.computerURL
        case .recents: Places.recentsURL
        case .shared: Places.sharedURL
        case .device(let udid, let path): Places.deviceURL(udid, path: path)
        case .search(let request): request.url
        }
    }

    /// Folders compare by path (a trailing slash or `file://` spelling doesn't make a new place).
    static func == (a: Location, b: Location) -> Bool {
        switch (a, b) {
        case let (.folder(x), .folder(y)): x.path == y.path
        case (.trash, .trash), (.network, .network), (.computer, .computer),
             (.recents, .recents), (.shared, .shared): true
        case let (.search(x), .search(y)): x == y
        case let (.device(x, p), .device(y, q)): x == y && p == q
        case let (.tag(x), .tag(y)): x == y
        case let (.server(x), .server(y)): x.scheme == y.scheme && Places.sameServer(x, y)
        default: false
        }
    }

    static func tagURL(_ name: String) -> URL {
        var components = URLComponents()
        components.scheme = tagScheme
        components.host = "tag"
        components.path = "/" + name
        return components.url ?? Places.networkURL
    }

    /// The folder on disk, if this location is one.
    var directory: URL? {
        switch self {
        case .folder(let url): url
        case .trash: Places.trashURL
        case .tag, .network, .server, .computer, .recents, .shared, .device, .search: nil
        }
    }

    /// Tab and window title.
    var title: String {
        switch self {
        case .folder(let url): url.displayName
        case .trash: Places.trashURL.displayName
        case .tag(let name): name
        case .network: L("Сеть")
        case .server(let url): Places.serverName(of: url) ?? url.absoluteString
        case .computer: L("Этот Mac")
        case .recents: L("Недавние")
        case .shared: L("Общий доступ")
        case .device(let udid, let path):
            MainActor.assumeIsolated {
                let parts = path.split(separator: "/").map(String.init)
                if parts.count > 1, let last = parts.last { return last }
                if let id = parts.first { return DeviceFilesView.appNames[udid]?[id] ?? id }
                return MobileDevices.shared.device(udid)?.name ?? "iPhone"
            }
        case .search(let request): L("Поиск «%@»", request.text)
        }
    }

    /// What the address bar shows: a path, or the name of a virtual location.
    var addressText: String {
        switch self {
        case .tag(let name): L("Теги: %@", name)
        case .network: L("Сеть")
        case .server(let url): url.scheme.map { "\($0)://" + (Places.serverName(of: url) ?? "") } ?? url.absoluteString
        case .computer: L("Этот Mac")
        case .recents: L("Недавние")
        case .shared: L("Общий доступ")
        case .device: title
        case .search(let request):
            L("Результаты поиска «%@» ", request.text) + (request.wholeMac ? L("на всём Mac") : L("в «%@»", request.folder?.displayName ?? ""))
        case .folder, .trash: url.path
        }
    }

    /// Can be shown in a tab (files and apps are opened instead).
    var isBrowsable: Bool {
        switch self {
        case .folder(let url): url.isBrowsableDirectory
        case .trash, .tag, .network, .server, .computer, .recents, .shared, .device, .search: true
        }
    }

    @MainActor
    var icon: NSImage? {
        switch self {
        case .folder(let url):
            // A server's shared folder: Finder's shared-folder picture, as in the server's list
            if let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeIsLocalKey]),
               values.isVolume == true, values.volumeIsLocal == false {
                NSWorkspace.shared.icon(for: UTType("public.file-sharepoint") ?? .folder)
            } else {
                FileItem(url: url).icon
            }
        case .trash: NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        case .tag(let name): FileTags.dotImage(color: FileTags.tag(named: name, knownTags: []).color, size: 14)
        case .network: NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        case .server: NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        case .computer: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        case .recents: NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        case .shared: NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        case .device(let udid, let path):
            path.isEmpty ? NSImage(systemSymbolName: MobileDevices.shared.device(udid)?.symbol ?? "iphone", accessibilityDescription: nil)
                : NSWorkspace.shared.icon(for: .folder)
        case .search: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        }
    }
}
