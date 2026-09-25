import AppKit

/// Settings ▸ Программы: the apps of "Открыть с помощью" (hidden ones, added ones, ones with an
/// item of their own in the context menu) and the entries of "Создать ▸".
enum AppsConfig {
    static let didChange = Notification.Name("WinExAppsConfigChanged")
    private static var defaults: UserDefaults { AppDefaults.store }

    // MARK: Open with

    /// Which items an added app is offered for.
    enum Scope: String, Codable, CaseIterable {
        case all, files, folders

        var title: String {
            switch self {
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
        /// An item of its own in the context menu: "Открыть в Visual Studio Code".
        var inMainMenu = false

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { OpenWithMenu.appName(url) }

        /// Whether it's offered for all of `urls`.
        func applies(to urls: [URL]) -> Bool {
            !urls.isEmpty && urls.allSatisfy { url in
                let isFolder = url.isBrowsableDirectory
                switch scope {
                case .folders: return isFolder
                case .files: if isFolder { return false }
                case .all: if isFolder { return true }
                }
                return extensions.isEmpty || extensions.contains(url.pathExtension.lowercased())
            }
        }
    }

    static var apps: [App] {
        get { decode([App].self, "openWithApps") ?? [] }
        set { encode(newValue, "openWithApps") }
    }

    /// Apps left out of "Открыть с помощью" (their bundle identifiers, or paths).
    static var hiddenApps: [String] {
        get { defaults.stringArray(forKey: "openWithHidden") ?? [] }
        set {
            defaults.set(newValue, forKey: "openWithHidden")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func identity(of app: URL) -> String {
        Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path
    }

    static func isHidden(_ app: URL) -> Bool {
        hiddenApps.contains(identity(of: app))
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
