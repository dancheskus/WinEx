import AppKit

/// What a tab shows. Tabs, history and the sidebar store plain URLs; this decodes them:
/// a folder, the Trash (a folder with its own menu), all files with a tag, or the network.
enum Location: Equatable {
    case folder(URL)
    case trash
    case tag(String)
    case network

    /// Tag locations use this URL scheme: `x-winex-tag://tag/<name>`.
    static let tagScheme = "x-winex-tag"

    init(_ url: URL) {
        if url.scheme == Places.networkURL.scheme {
            self = .network
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
        }
    }

    /// Folders compare by path (a trailing slash or `file://` spelling doesn't make a new place).
    static func == (a: Location, b: Location) -> Bool {
        switch (a, b) {
        case let (.folder(x), .folder(y)): x.path == y.path
        case (.trash, .trash), (.network, .network): true
        case let (.tag(x), .tag(y)): x == y
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
        case .tag, .network: nil
        }
    }

    /// Tab and window title.
    var title: String {
        switch self {
        case .folder(let url): url.displayName
        case .trash: Places.trashURL.displayName
        case .tag(let name): name
        case .network: "Сеть"
        }
    }

    /// What the address bar shows: a path, or the name of a virtual location.
    var addressText: String {
        switch self {
        case .tag(let name): "Теги: \(name)"
        case .network: "Сеть"
        case .folder, .trash: url.path
        }
    }

    /// Can be shown in a tab (files and apps are opened instead).
    var isBrowsable: Bool {
        switch self {
        case .folder(let url): url.isBrowsableDirectory
        case .trash, .tag, .network: true
        }
    }

    @MainActor
    var icon: NSImage? {
        switch self {
        case .folder(let url): FileItem(url: url).icon
        case .trash: NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        case .tag(let name): FileTags.dotImage(color: FileTags.tag(named: name, knownTags: []).color, size: 14)
        case .network: NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        }
    }
}
