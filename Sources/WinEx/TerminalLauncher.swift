import AppKit

/// "Открыть в терминале" (Settings ▸ Основные): the folder — or a file's folder, or the folder on
/// screen, or the desktop — in the terminal of the user's choice.
@MainActor
final class TerminalLauncher: NSObject {
    static let shared = TerminalLauncher()

    struct App: Equatable {
        let name: String
        let url: URL
    }

    /// How a terminal is told where to start: most open a folder handed to them; a few take a
    /// command-line option instead (a new instance each time).
    private enum Style { case folder, arguments(@Sendable (String) -> [String]) }

    private static let known: [(id: String, style: Style)] = [
        ("com.apple.Terminal", .folder),
        ("com.googlecode.iterm2", .folder),
        ("dev.warp.Warp-Stable", .folder),
        ("com.mitchellh.ghostty", .arguments { ["--working-directory=\($0)"] }),
        ("net.kovidgoyal.kitty", .arguments { ["--directory", $0] }),
        ("org.alacritty", .arguments { ["--working-directory", $0] }),
        ("com.github.wez.wezterm", .arguments { ["start", "--cwd", $0] }),
        ("co.zeit.hyper", .folder),
        ("org.tabby", .folder),
        ("com.raphaelamorim.rio", .folder),
    ]

    /// The terminals installed on this Mac, Terminal first.
    static var installed: [App] {
        known.compactMap { entry in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id).map { App(name: displayName($0), url: $0) }
        }
    }

    /// The chosen terminal (Terminal when none was chosen or it's gone).
    static var chosen: App? {
        if let path = Settings.terminalApp, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            return App(name: displayName(url), url: url)
        }
        return installed.first
    }

    static func displayName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The context menu's item, if it's switched on.
    static func menuItem(for urls: [URL]) -> NSMenuItem? {
        guard Settings.terminalInMenu, let app = chosen, !urls.isEmpty else { return nil }
        let item = NSMenuItem(title: app.name == L("Терминал") || app.name == "Terminal" ? L("Открыть в Терминале") : L("Открыть в %@", app.name),
                              action: #selector(openFromMenu(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = urls as NSArray
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: 18, height: 18)
        item.image = icon
        return item
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        Self.open(urls)
    }

    /// Folders open as they are; for a file, its folder.
    static func open(_ urls: [URL]) {
        var folders: [URL] = []
        for url in urls {
            let folder = url.isBrowsableDirectory ? url : url.deletingLastPathComponent()
            if !folders.contains(folder) { folders.append(folder) }
        }
        folders.prefix(5).forEach(open(folder:))
    }

    static func open(folder: URL) {
        guard let app = chosen else {
            NSSound.beep()
            return
        }
        let bundleID = Bundle(url: app.url)?.bundleIdentifier
        let style = known.first { $0.id == bundleID }?.style ?? .folder
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        switch style {
        case .folder:
            NSWorkspace.shared.open([folder], withApplicationAt: app.url, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
            }
        case .arguments(let arguments):
            configuration.arguments = arguments(folder.path)
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
            }
        }
    }
}
