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
            Standard(title: L("Программы"), url: URL(fileURLWithPath: "/Applications"), symbol: "square.grid.3x3"),
        ].compactMap { $0 }
    }

    /// Paths of the favourites, in order.
    static var favoritePaths: [String] {
        get { defaults.stringArray(forKey: "sidebarFavorites") ?? standardFavorites.map(\.url.path) }
        set {
            var seen = Set<String>()
            defaults.set(newValue.filter { seen.insert($0).inserted }, forKey: "sidebarFavorites")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func isFavorite(_ url: URL) -> Bool {
        favoritePaths.contains(url.standardizedFileURL.path)
    }

    /// Pins a folder at `index` (the end when nil), or moves it there if it's already a favourite.
    static func pin(_ url: URL, at index: Int? = nil) {
        let path = url.standardizedFileURL.path
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
        let path = url.standardizedFileURL.path
        favoritePaths = favoritePaths.filter { $0 != path }
    }

    /// Settings: a standard folder switched back on returns to its usual place among the others.
    static func restore(_ standard: Standard) {
        let order = standardFavorites.map(\.url.path)
        let paths = favoritePaths
        guard let rank = order.firstIndex(of: standard.url.path) else { return pin(standard.url) }
        let after = order[..<rank]
        let index = (paths.lastIndex { after.contains($0) }).map { $0 + 1 } ?? 0
        pin(standard.url, at: index)
    }

    static func symbol(for url: URL) -> String {
        standardFavorites.first { $0.url.path == url.standardizedFileURL.path }?.symbol ?? "folder"
    }

    // MARK: Places

    enum Place: String, CaseIterable {
        case computer, iCloud, internalDisks, externalDisks, servers, airDrop, network, trash

        var title: String {
            switch self {
            case .computer: L("Этот Mac")
            case .iCloud: "iCloud Drive"
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
            case .computer: "desktopcomputer"
            case .iCloud: "icloud"
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
