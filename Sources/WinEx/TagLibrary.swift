import AppKit

/// Every tag WinEx knows (Settings ▸ Теги), in the user's order, and which of them the sidebar shows.
///
/// Finder keeps its tag list in iCloud where no other app can read it, so the list is gathered
/// from the tagged files themselves (Spotlight). Finder's favourite tags — the coloured row of the
/// context menu — live in Finder's own settings and are read from and written back there, so both
/// apps show the same ones.
enum TagLibrary {
    struct Entry: Codable, Equatable {
        var name: String
        var color: Int
        var inSidebar: Bool
    }

    static let didChange = Notification.Name("WinExTagLibraryChanged")

    private static var defaults: UserDefaults { AppDefaults.store }
    private static let key = "tagLibrary"

    static var entries: [Entry] {
        get {
            if let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode([Entry].self, from: data) {
                return stored
            }
            // Before the first edit: Finder's favourites
            return favoriteNames.map { Entry(name: $0, color: FileTags.standardColor(of: $0) ?? 0, inSidebar: true) }
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func color(of name: String) -> Int? {
        entries.first { $0.name == name }?.color
    }

    // MARK: Finder's favourite tags

    private static let finder = "com.apple.finder" as CFString
    private static let favoritesKey = "FavoriteTagNames" as CFString
    /// Finder's standard seven, if it has never saved its own list.
    static let standardNames = ["Красный", "Оранжевый", "Желтый", "Зеленый", "Синий", "Лиловый", "Серый"]

    /// Scenario runs keep them in the scenario's own store: Finder's settings stay untouched.
    private static var usesFinderSettings: Bool {
        #if DEBUG
        return !Scenario.isRequested
        #else
        return true
        #endif
    }

    /// Finder's favourite tags, in its order.
    static var favoriteNames: [String] {
        get {
            let stored = usesFinderSettings
                ? CFPreferencesCopyAppValue(favoritesKey, finder) as? [String]
                : defaults.stringArray(forKey: "scenarioFavoriteTags")
            return stored.map { $0.filter { !$0.isEmpty } } ?? standardNames
        }
        set {
            guard newValue != favoriteNames else { return }
            if usesFinderSettings {
                // Finder's list starts with an empty name; keep that shape
                CFPreferencesSetAppValue(favoritesKey, ([""] + newValue) as CFArray, finder)
                CFPreferencesAppSynchronize(finder)
            } else {
                defaults.set(newValue, forKey: "scenarioFavoriteTags")
            }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Editing

    /// Adds tags found on files (or in Finder's favourites) that the list doesn't have yet.
    static func merge(_ found: [FileTags.Tag]) {
        var list = entries
        var known = Set(list.map(\.name))
        for tag in found where !known.contains(tag.name) {
            list.append(Entry(name: tag.name, color: tag.color, inSidebar: true))
            known.insert(tag.name)
        }
        if list != entries { entries = list }
    }

    /// Renames or recolours a tag everywhere: in the list, in the favourites, on every file.
    @MainActor
    static func change(_ name: String, to newName: String, color: Int) {
        var list = entries
        guard let index = list.firstIndex(where: { $0.name == name }) else { return }
        if newName != name, list.contains(where: { $0.name == newName }) { return }
        list[index].name = newName
        list[index].color = color
        entries = list
        if newName != name { favoriteNames = favoriteNames.map { $0 == name ? newName : $0 } }
        rewriteFiles(tagged: name) { tags in
            tags.map { $0.name == name ? FileTags.Tag(name: newName, color: color) : $0 }
        }
    }

    /// Deletes a tag from the list, the favourites and every file.
    @MainActor
    static func delete(_ name: String) {
        entries = entries.filter { $0.name != name }
        favoriteNames = favoriteNames.filter { $0 != name }
        rewriteFiles(tagged: name) { $0.filter { $0.name != name } }
    }

    // MARK: Spotlight

    /// Tags on the Mac's files (Spotlight knows every tagged file), added to the list.
    @MainActor
    static func discover() {
        SpotlightOnce.run(NSPredicate(fromMetadataQueryString: "kMDItemUserTags == *")) { urls in
            DispatchQueue.global(qos: .utility).async {
                var found: [FileTags.Tag] = []
                var seen = Set<String>()
                for url in urls.prefix(20_000) {
                    for tag in FileTags.tags(of: url) where seen.insert(tag.name).inserted { found.append(tag) }
                }
                DispatchQueue.main.async { merge(found) }
            }
        }
    }

    @MainActor
    private static func rewriteFiles(tagged name: String, _ change: @escaping @Sendable ([FileTags.Tag]) -> [FileTags.Tag]) {
        let predicate = NSPredicate(format: "kMDItemUserTags == %@", name)
        SpotlightOnce.run(predicate) { urls in
            DispatchQueue.global(qos: .userInitiated).async {
                for url in urls {
                    let tags = FileTags.tags(of: url)
                    guard tags.contains(where: { $0.name == name }) else { continue }
                    try? FileTags.setTags(change(tags), on: url)
                }
                DispatchQueue.main.async { NotificationCenter.default.post(name: .fileTagsChanged, object: nil) }
            }
        }
    }
}

/// One Spotlight query: every match on this Mac, then it stops.
@MainActor
final class SpotlightOnce {
    private static var running: [SpotlightOnce] = []
    private let query = NSMetadataQuery()
    private let observers = Observers()

    static func run(_ predicate: NSPredicate?, completion: @escaping @MainActor ([URL]) -> Void) {
        guard let predicate else { return completion([]) }
        let search = SpotlightOnce()
        running.append(search)
        search.query.predicate = predicate
        search.query.searchScopes = [NSMetadataQueryLocalComputerScope]
        search.observers.add(.NSMetadataQueryDidFinishGathering, object: search.query) { [weak search] in
            guard let search else { return }
            search.query.stop()
            let urls = search.query.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
                .map { URL(fileURLWithPath: $0) }
            running.removeAll { $0 === search }
            completion(urls)
        }
        if !search.query.start() {
            running.removeAll { $0 === search }
            completion([])
        }
    }
}
