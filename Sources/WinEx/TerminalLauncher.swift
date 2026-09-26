import AppKit

/// "Открыть в терминале" (Settings ▸ Основные): the folder — or a file's folder, or the folder on
/// screen, or the desktop — in the terminal of the user's choice; an executable script is run there
/// ("Запустить в …").
@MainActor
final class TerminalLauncher: NSObject {
    static let shared = TerminalLauncher()

    struct App: Equatable {
        let name: String
        let url: URL
    }

    /// How a terminal is told where to start: most open a folder handed to them; a few take a
    /// command-line option instead (a new instance each time).
    private enum Style {
        case folder
        /// Options for a start folder, and for running a script (with its folder)
        case arguments(@Sendable (String) -> [String], run: @Sendable (String, String) -> [String])
    }

    private static let known: [(id: String, style: Style)] = [
        ("com.apple.Terminal", .folder),
        ("com.googlecode.iterm2", .folder),
        ("dev.warp.Warp-Stable", .folder),
        ("com.mitchellh.ghostty", .arguments({ ["--working-directory=\($0)"] }, run: { ["--working-directory=\($1)", "-e", $0] })),
        ("net.kovidgoyal.kitty", .arguments({ ["--directory", $0] }, run: { ["--directory", $1, $0] })),
        ("org.alacritty", .arguments({ ["--working-directory", $0] }, run: { ["--working-directory", $1, "-e", $0] })),
        ("com.github.wez.wezterm", .arguments({ ["start", "--cwd", $0] }, run: { ["start", "--cwd", $1, "--", $0] })),
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
        let isTerminal = app.name == L("Терминал") || app.name == "Terminal"
        let title = urls.allSatisfy(isScript)
            ? (isTerminal ? L("Запустить в Терминале") : L("Запустить в %@", app.name))
            : (isTerminal ? L("Открыть в Терминале") : L("Открыть в %@", app.name))
        let item = NSMenuItem(title: title,
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
    /// A file the terminal runs: a script or program with the executable bit (not an app).
    static func isScript(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
        return values?.isRegularFile == true && values?.isPackage != true && FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func open(_ urls: [URL]) {
        // Scripts run; everything else opens its folder
        for script in urls.filter(isScript).prefix(5) { run(script) }
        var folders: [URL] = []
        for url in urls where !isScript(url) {
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
        case .arguments(let arguments, _):
            configuration.arguments = arguments(folder.path)
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
            }
        }
    }

    /// Runs a script in the terminal: most terminals run an executable file handed to them
    /// (Terminal, iTerm, Hyper…); the others get it as a command.
    static func run(_ script: URL) {
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
            NSWorkspace.shared.open([script], withApplicationAt: app.url, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
            }
        case .arguments(_, let run):
            configuration.arguments = run(script.path, script.deletingLastPathComponent().path)
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
            }
        }
    }
}
