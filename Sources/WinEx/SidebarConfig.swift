import AppKit

/// What the sidebar shows (Settings ▸ Боковое меню): the favourites in the user's order —
/// standard folders plus pinned ones — and which places are listed.
enum SidebarConfig {
    static let didChange = Notification.Name("WinExSidebarChanged")

    private static var defaults: UserDefaults { AppDefaults.store }

    // MARK: Favourites

    struct Standard {
        let title: String
        let url: URL
        let symbol: String
    }

    /// The folders Finder offers for its favourites, in WinEx's default order.
    static var standardFavorites: [Standard] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func folder(_ directory: FileManager.SearchPathDirectory, _ symbol: String) -> Standard? {
            guard let url = fm.urls(for: directory, in: .userDomainMask).first else { return nil }
            return Standard(title: url.displayName, url: url, symbol: symbol)
        }
        return [
            Standard(title: home.displayName, url: home, symbol: "house"),
            folder(.desktopDirectory, "menubar.dock.rectangle"),
            folder(.documentDirectory, "doc"),
            folder(.downloadsDirectory, "arrow.down.circle"),
            folder(.picturesDirectory, "photo"),
            folder(.musicDirectory, "music.note"),
            folder(.moviesDirectory, "film"),
            Standard(title: L("Программы"), url: URL(fileURLWithPath: "/Applications"), symbol: "finder:SidebarApplicationsFolder"),
        ].compactMap { $0 }
    }

    /// How a favourite is stored: a folder's path, or a place's address («Недавние»).
    static func key(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    static func url(forKey key: String) -> URL {
        key.hasPrefix("/") ? URL(fileURLWithPath: key) : URL(string: key) ?? URL(fileURLWithPath: key)
    }

    /// Keys of the favourites (see `key(_:)`), in order.
    static var favoritePaths: [String] {
        get {
            // (Only folders: «Недавние» was a favourite for a while; it's on top of the sidebar now)
            defaults.stringArray(forKey: "sidebarFavorites")?.filter { $0.hasPrefix("/") } ?? standardFavorites.map { key($0.url) }
        }
        set {
            var seen = Set<String>()
            defaults.set(newValue.filter { seen.insert($0).inserted }, forKey: "sidebarFavorites")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func isFavorite(_ url: URL) -> Bool {
        favoritePaths.contains(key(url))
    }

    /// Pins a folder at `index` (the end when nil), or moves it there if it's already a favourite.
    static func pin(_ url: URL, at index: Int? = nil) {
        let path = key(url)
        var paths = favoritePaths
        var target = index ?? paths.count
        if let current = paths.firstIndex(of: path) {
            paths.remove(at: current)
            if current < target { target -= 1 }
        }
        paths.insert(path, at: min(max(target, 0), paths.count))
        favoritePaths = paths
    }

    static func unpin(_ url: URL) {
        let path = key(url)
        favoritePaths = favoritePaths.filter { $0 != path }
    }

    /// Settings: a standard folder switched back on returns to its usual place among the others.
    static func restore(_ standard: Standard) {
        let order = standardFavorites.map { key($0.url) }
        let paths = favoritePaths
        guard let rank = order.firstIndex(of: key(standard.url)) else { return pin(standard.url) }
        let after = order[..<rank]
        let index = (paths.lastIndex { after.contains($0) }).map { $0 + 1 } ?? 0
        pin(standard.url, at: index)
    }

    /// A sidebar icon: an SF Symbol, or (`finder:<name>`) one of Finder's own sidebar glyphs where
    /// no symbol matches (Applications' «A») — as a template, tinted like the symbols.
    static func icon(_ symbol: String, pointSize: CGFloat) -> NSImage? {
        guard symbol.hasPrefix("finder:") else {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        }
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(symbol.dropFirst(7)).icns"
        guard let glyph = NSImage(contentsOfFile: path) else { return NSImage(systemSymbolName: "folder", accessibilityDescription: nil) }
        let side = (pointSize * 1.15).rounded()
        glyph.size = NSSize(width: side, height: side)
        glyph.isTemplate = true
        return glyph
    }

    static func symbol(for url: URL) -> String {
        standardFavorites.first { key($0.url) == key(url) }?.symbol ?? "folder"
    }

    // MARK: Places

    enum Place: String, CaseIterable {
        case recents, shared, computer, iCloud, internalDisks, externalDisks, servers, airDrop, network, trash

        var title: String {
            switch self {
            case .recents: L("Недавние")
            case .computer: L("Этот Mac")
            case .iCloud: "iCloud Drive"
            case .shared: L("Общий доступ")
            case .internalDisks: L("Внутренние диски")
            case .externalDisks: L("Внешние диски")
            case .servers: L("Подключённые серверы")
            case .airDrop: "AirDrop"
            case .network: L("Сеть")
            case .trash: L("Корзина")
            }
        }

        var symbol: String {
            switch self {
            case .recents: "clock"
            case .computer: "desktopcomputer"
            case .iCloud: "icloud"
            case .shared: "person.2"
            case .internalDisks: "internaldrive"
            case .externalDisks: "externaldrive"
            case .servers: "externaldrive.connected.to.line.below"
            case .airDrop: "airplayaudio"
            case .network: "network"
            case .trash: "trash"
            }
        }
    }

    static func shows(_ place: Place) -> Bool {
        !(defaults.stringArray(forKey: "sidebarHiddenPlaces") ?? []).contains(place.rawValue)
    }

    static func setShows(_ place: Place, _ shown: Bool) {
        var hidden = Set(defaults.stringArray(forKey: "sidebarHiddenPlaces") ?? [])
        if shown { hidden.remove(place.rawValue) } else { hidden.insert(place.rawValue) }
        defaults.set(hidden.sorted(), forKey: "sidebarHiddenPlaces")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Tags

    static var showsTags: Bool {
        get { defaults.object(forKey: "sidebarShowsTags") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "sidebarShowsTags")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
