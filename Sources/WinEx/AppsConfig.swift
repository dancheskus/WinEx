import AppKit
import UniformTypeIdentifiers

/// Settings ▸ Программы: the apps of "Открыть с помощью" (hidden ones, added ones, ones with an
/// item of their own in the context menu) and the entries of "Создать ▸".
enum AppsConfig {
    static let didChange = Notification.Name("WinExAppsConfigChanged")
    private static var defaults: UserDefaults { AppDefaults.store }

    // MARK: Open with

    /// Which items an app is offered for.
    enum Scope: String, Codable, CaseIterable {
        /// What macOS offers it for (the kinds of files it says it opens).
        case system, all, files, folders

        var title: String {
            switch self {
            case .system: L("Как предлагает macOS")
            case .all: L("Файлы и папки")
            case .files: L("Только файлы")
            case .folders: L("Только папки")
            }
        }
    }

    struct App: Codable, Equatable {
        var path: String
        var scope: Scope = .all
        /// For files: only these extensions ("txt", "md"); empty — any file.
        var extensions: [String] = []
        /// In the context menu itself as "Открыть в Visual Studio Code" instead of in
        /// "Открыть с помощью".
        var inMainMenu = false

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { OpenWithMenu.appName(url) }

        /// Whether it's offered for all of `urls`.
        func applies(to urls: [URL]) -> Bool {
            !urls.isEmpty && urls.allSatisfy { url in
                let isFolder = url.isBrowsableDirectory
                switch scope {
                case .system:
                    // Extensions typed in say which files, whatever macOS offers it for (VS Code
                    // for .rtf); none: the files macOS offers it for
                    if !isFolder, !extensions.isEmpty { return extensions.contains(url.pathExtension.lowercased()) }
                    let identity = AppsConfig.identity(of: self.url)
                    guard NSWorkspace.shared.urlsForApplications(toOpen: url).contains(where: { AppsConfig.identity(of: $0) == identity }) else { return false }
                    if isFolder { return true }
                case .folders: return isFolder
                case .files: if isFolder { return false }
                case .all: if isFolder { return true }
                }
                return extensions.isEmpty || extensions.contains(url.pathExtension.lowercased())
            }
        }
    }

    /// Settings of the apps whose row in Settings ▸ Программы was changed (or added there): where
    /// they're offered, in the menu itself or not. Apps without an entry: as macOS offers them.
    static var apps: [App] {
        get { decode([App].self, "openWithApps") ?? [] }
        set { encode(newValue, "openWithApps") }
    }

    /// The apps of "Открыть с помощью" switched on in Settings ▸ Программы (bundle identifiers, or
    /// paths). Until the user changes anything: the basic ones (an earlier list of
    /// hidden apps still counts), so apps installed later start switched off.
    static var shownApps: [String] {
        get {
            // Apps added before the two lists became one stay on (once: later they're switched here)
            let added = defaults.bool(forKey: "openWithMerged") ? [] : apps.map { identity(of: $0.url) }
            if let shown = defaults.stringArray(forKey: "openWithShown") {
                let merged = shown + added.filter { !shown.contains($0) }
                if !added.isEmpty { self.shownApps = merged }
                return merged
            }
            let hidden = defaults.stringArray(forKey: "openWithHidden") ?? []
            return basicApps.filter { !hidden.contains($0) } + added.filter { !basicApps.contains($0) }
        }
        set {
            defaults.set(true, forKey: "openWithMerged")
            defaults.set(newValue, forKey: "openWithShown")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static let basicApps = ["com.apple.TextEdit", "com.apple.Preview", "com.apple.Safari", "com.apple.QuickTimePlayerX",
                            "com.apple.archiveutility"]

    static func identity(of app: URL) -> String {
        Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path
    }

    static func isShown(_ app: URL) -> Bool { shownApps.contains(identity(of: app)) }

    /// The Settings entry of `app` (any copy of it).
    static func config(for app: URL) -> App? {
        let identity = identity(of: app)
        return apps.first { self.identity(of: $0.url) == identity }
    }

    /// Changes `app`'s entry, making one if there isn't (offered as macOS offers it, or, for an
    /// app macOS doesn't offer for common files, for files and folders).
    static func change(_ app: URL, _ edit: (inout App) -> Void) {
        var list = apps
        let identity = identity(of: app)
        let index = list.firstIndex { self.identity(of: $0.url) == identity } ?? {
            list.append(App(path: app.path, scope: isListed(app) ? .system : .all))
            return list.count - 1
        }()
        edit(&list[index])
        apps = list
    }

    /// One of the apps macOS offers for folders and common files (the Settings list starts with them).
    static func isListed(_ app: URL) -> Bool { listedIdentities.contains(identity(of: app)) }

    /// In "Открыть с помощью" for the system-offered `app`: switched on, offered for these items,
    /// not in the menu itself. Apps outside the Settings list (ones for rarer kinds of files)
    /// always show, they can't be switched there.
    static func showsInOpenWith(_ app: URL, for urls: [URL]) -> Bool {
        guard let config = config(for: app) else { return !isListed(app) || isShown(app) }
        return isShown(app) && !config.inMainMenu && config.applies(to: urls)
    }

    /// The apps of "Открыть с помощью" for folders and the usual kinds of files (text, documents,
    /// pictures, sound, video, archives, code, web pages), without WinEx (any copy), each once, by name.
    static func listedApps() -> [URL] {
        let types: [UTType] = [.folder, .plainText, .rtf, .pdf, .image, .png, .jpeg, .movie, .mpeg4Movie, .audio, .mp3,
                               .html, .json, .xml, .zip, .sourceCode, .shellScript, .spreadsheet, .presentation,
                               UTType("org.openxmlformats.wordprocessingml.document"), UTType("net.daringfireball.markdown")].compactMap { $0 }
        var seen = Set<String>()
        var apps: [URL] = []
        let own = identity(of: Bundle.main.bundleURL)
        for type in types {
            for app in NSWorkspace.shared.urlsForApplications(toOpen: type) where identity(of: app) != own && seen.insert(identity(of: app)).inserted {
                apps.append(app)
            }
        }
        listedCache = seen
        return apps.sorted { OpenWithMenu.appName($0).localizedStandardCompare(OpenWithMenu.appName($1)) == .orderedAscending }
    }

    private static var listedCache: Set<String>?
    private static var listedIdentities: Set<String> {
        if let listedCache { return listedCache }
        _ = listedApps()
        return listedCache ?? []
    }

    // MARK: New items

    struct Template: Codable, Equatable {
        var id = UUID().uuidString
        /// In the menu: "Документ Pages".
        var title: String
        /// The new file's name with its extension: "Новый документ.pages".
        var fileName: String
        /// A file copied for each new one; nil — an empty file.
        var sourcePath: String?
    }

    /// Built-in entries renamed by the user: id → title / file name.
    static var templateTitles: [String: String] {
        get { defaults.dictionary(forKey: "newItemTitles") as? [String: String] ?? [:] }
        set {
            defaults.set(newValue, forKey: "newItemTitles")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var templateFileNames: [String: String] {
        get { defaults.dictionary(forKey: "newItemFileNames") as? [String: String] ?? [:] }
        set {
            defaults.set(newValue, forKey: "newItemFileNames")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var templates: [Template] {
        get { decode([Template].self, "newItemTemplates") ?? [] }
        set { encode(newValue, "newItemTemplates") }
    }

    /// Built-in entries switched off (their ids).
    static var hiddenTemplates: [String] {
        get { defaults.stringArray(forKey: "newItemHidden") ?? [] }
        set {
            defaults.set(newValue, forKey: "newItemHidden")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Storage

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
