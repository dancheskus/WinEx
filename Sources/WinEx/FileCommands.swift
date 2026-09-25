import AppKit

/// Finder's everyday file commands: duplicate, compress / extract ZIP, aliases, package contents.
/// Shared by folder windows and the desktop; every result can be undone with ⌘Z.
@MainActor
enum FileCommands {
    // MARK: Duplicate

    /// A copy next to each item ("имя - копия"), with the usual progress window if it's big.
    static func duplicate(_ urls: [URL]) {
        for (folder, items) in Dictionary(grouping: urls, by: { $0.deletingLastPathComponent() }) {
            FileOperations.start(.copy, items, to: folder)
        }
    }

    // MARK: ZIP

    static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    /// One item → "имя.zip", several → "Архив.zip" (like Finder), next to them.
    static func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let folder = first.deletingLastPathComponent()
        let items = urls.filter { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }
        let base = items.count == 1 ? first.lastPathComponent : "Архив"
        let archive = FileOps.newItemURL(named: base + ".zip", in: folder)
        let arguments: [String]
        let tool: String
        if items.count == 1 {
            // ditto keeps extended attributes and resource forks, like Finder's "Compress"
            tool = "/usr/bin/ditto"
            arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, archive.path]
        } else {
            tool = "/usr/bin/zip"
            arguments = ["-r", "-y", "-q", archive.path] + items.map(\.lastPathComponent)
        }
        run(tool, arguments, in: folder, busy: "Сжатие «\(archive.lastPathComponent)»…") { ok in
            if ok { FileUndo.recordCreate(archive) } else { try? FileManager.default.removeItem(at: archive) }
        }
    }

    /// Extracts next to the archive: a single top-level item keeps its name, several go into a
    /// folder named after the archive (what Archive Utility does).
    static func extract(_ archive: URL) {
        let fm = FileManager.default
        let folder = archive.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".winex-extract-\(UUID().uuidString)")
        run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path], in: folder, busy: "Распаковка «\(archive.lastPathComponent)»…") { ok in
            defer { try? fm.removeItem(at: staging) }
            guard ok else { return }
            let contents = ((try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != "__MACOSX" }
            let result: URL
            do {
                if contents.count == 1, let only = contents.first {
                    result = FileOps.newItemURL(named: only.lastPathComponent, in: folder)
                    try fm.moveItem(at: only, to: result)
                } else {
                    result = FileOps.newItemURL(named: archive.deletingPathExtension().lastPathComponent, in: folder)
                    try fm.createDirectory(at: result, withIntermediateDirectories: false)
                    for item in contents { try fm.moveItem(at: item, to: result.appendingPathComponent(item.lastPathComponent)) }
                }
                FileUndo.recordCreate(result)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Runs an archiving tool off the main thread; a small window says what's going on if it takes long.
    private static func run(_ tool: String, _ arguments: [String], in folder: URL, busy: String,
                            then done: @escaping @MainActor (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let indicator = BusyIndicator(title: busy) { process.terminate() }
        process.terminationHandler = { finished in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = finished.terminationStatus == 0 && finished.terminationReason == .exit
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    indicator.close()
                    if !ok && !indicator.cancelled {
                        let alert = NSAlert()
                        alert.messageText = busy.replacingOccurrences(of: "…", with: "") + " не удалось"
                        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        alert.runModal()
                    }
                    done(ok)
                }
            }
        }
        do {
            try process.run()
        } catch {
            indicator.close()
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Aliases

    static func isAlias(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }

    /// Finder aliases (they follow the original when it's moved) in `folder`, or next to each item.
    static func makeAliases(_ urls: [URL], in folder: URL? = nil) {
        for url in urls {
            let target = folder ?? url.deletingLastPathComponent()
            let alias = FileOps.newItemURL(named: "\(url.lastPathComponent) псевдоним", in: target)
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: alias)
                FileUndo.recordCreate(alias)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Where an alias points (nil for other files or a broken alias).
    static func original(of url: URL) -> URL? {
        guard isAlias(url) else { return nil }
        return try? URL(resolvingAliasFileAt: url, options: [.withoutUI])
    }

    /// Resolves an alias for opening; other files as they are.
    static func resolved(_ url: URL) -> URL {
        original(of: url) ?? url
    }

    /// "Показать оригинал": the original in its folder, selected; a broken alias says so.
    static func showOriginal(of url: URL, reveal: (URL) -> Void) {
        guard let original = original(of: url) else {
            let alert = NSAlert()
            alert.messageText = "Не удалось найти оригинал «\(url.lastPathComponent)»"
            alert.informativeText = "Возможно, он удалён или находится на отключённом диске."
            alert.runModal()
            return
        }
        reveal(original)
    }

    // MARK: Packages

    /// Apps, bundles and other folders shown as a single file.
    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }
}

/// A small window for archiving that takes a while, with a Cancel button.
@MainActor
final class BusyIndicator {
    private var window: NSWindow?
    private(set) var cancelled = false
    private var closed = false

    init(title: String, cancel: @escaping () -> Void) {
        // Quick jobs never show it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.show(title, cancel) }
        }
    }

    private func show(_ title: String, _ cancel: @escaping () -> Void) {
        guard !closed else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.title = "WinEx"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let button = NSButton(title: "Отмена", target: nil, action: nil)
        let handler = ButtonHandler { [weak self] in
            self?.cancelled = true
            cancel()
        }
        button.target = handler
        button.action = #selector(ButtonHandler.fire)
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        let stack = NSStackView(views: [label, bar, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        closed = true
        window?.orderOut(nil)
        window = nil
    }
}

private final class ButtonHandler: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
