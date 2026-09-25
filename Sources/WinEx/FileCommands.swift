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

    /// One item → "имя.zip", several → "Архив.zip" (like Finder), next to them. The archive holds
    /// exactly what was selected (a single file isn't wrapped into its parent folder).
    static func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let folder = first.deletingLastPathComponent()
        let items = urls.filter { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }
        let base = items.count == 1 ? first.lastPathComponent : L("Архив")
        let archive = FileOps.newItemURL(named: base + ".zip", in: folder)
        let arguments: [String]
        let tool: String
        let marker: String
        // Progress: the tools name every file they add
        var total = 0
        for item in items {
            total += FileOperation.size(of: item).files
            if item.hasDirectoryPath || (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { total += 1 }
        }
        if items.count == 1 {
            // ditto keeps extended attributes and resource forks, like Finder's "Compress";
            // --keepParent keeps a folder's own name, but would wrap a file into its parent
            tool = "/usr/bin/ditto"
            let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            arguments = ["-V", "-c", "-k", "--sequesterRsrc"] + (isFolder ? ["--keepParent"] : []) + [first.path, archive.path]
            marker = "copying file "
        } else {
            tool = "/usr/bin/zip"
            arguments = ["-r", "-y", archive.path] + items.map(\.lastPathComponent)
            marker = "  adding: "
        }
        let headline: [(text: String, link: URL?)] = [(L("Сжатие %@ %@ в «%@»", items.count, plural(items.count, L("элемента"), L("элементов"), L("элементов")), archive.lastPathComponent), nil)]
        run(tool, arguments, in: folder, headline: headline, total: total, marker: marker) { ok in
            if ok {
                FileUndo.recordCreate(archive)
            } else {
                try? FileManager.default.removeItem(at: archive)
            }
        }
    }

    /// Extracts next to the archive: a single top-level item keeps its name, several go into a
    /// folder named after the archive (what Archive Utility does).
    static func extract(_ archive: URL) {
        let fm = FileManager.default
        let folder = archive.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".winex-extract-\(UUID().uuidString)")
        let headline: [(text: String, link: URL?)] = [(L("Распаковка «%@» в ", archive.lastPathComponent), nil), (folder.displayName, folder)]
        run("/usr/bin/ditto", ["-V", "-x", "-k", archive.path, staging.path], in: folder, headline: headline,
            total: entryCount(of: archive), marker: "copying file ") { ok in
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

    /// Files in a ZIP (what `ditto -V` will report while extracting).
    private static func entryCount(of archive: URL) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archive.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.hasSuffix("/") }.count
    }

    /// Runs an archiving tool off the main thread. Lines starting with `marker` (one per file) drive
    /// the progress window, which appears if the job takes more than a moment.
    private static func run(_ tool: String, _ arguments: [String], in folder: URL, headline: [(text: String, link: URL?)],
                            total: Int, marker: String, then done: @escaping @MainActor (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        let panel = ArchiveProgress(headline: headline, total: total) { process.terminate() }
        let collected = ArchiveOutput()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let (count, last) = collected.add(chunk, marker: marker)
            DispatchQueue.main.async { MainActor.assumeIsolated { panel.update(done: count, name: last) } }
        }
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            let ok = finished.terminationStatus == 0 && finished.terminationReason == .exit
            let message = collected.otherLines
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    panel.close()
                    if !ok && !panel.cancelled {
                        let alert = NSAlert()
                        alert.messageText = (headline.first?.text ?? L("Архив")) + L(" — не удалось")
                        alert.informativeText = message.suffix(600).trimmingCharacters(in: .whitespacesAndNewlines)
                        alert.runModal()
                    }
                    done(ok)
                }
            }
        }
        do {
            try process.run()
        } catch {
            panel.close()
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
            let alias = FileOps.newItemURL(named: L("%@ псевдоним", url.lastPathComponent), in: target)
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
            alert.messageText = L("Не удалось найти оригинал «%@»", url.lastPathComponent)
            alert.informativeText = L("Возможно, он удалён или находится на отключённом диске.")
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

/// Counts the per-file lines of an archiving tool's output (from its background thread).
final class ArchiveOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var count = 0
    private var last = ""
    private var others = ""

    func add(_ data: Data, marker: String) -> (Int, String) {
        lock.withLock {
            pending += String(decoding: data, as: UTF8.self)
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            for line in lines {
                if line.hasPrefix(marker) {
                    count += 1
                    let name = line.dropFirst(marker.count).replacingOccurrences(of: " ... ", with: "")
                    let file = (name.components(separatedBy: " (").first ?? name).trimmingCharacters(in: .whitespaces)
                    // Resource-fork copies ("__MACOSX/…/._name") aren't worth showing
                    if !(file as NSString).lastPathComponent.hasPrefix("._") { last = file }
                } else if !line.hasPrefix(">>>") && !line.contains(" bytes for ") && !line.isEmpty {
                    others += line + "\n"
                }
            }
            return (count, (last as NSString).lastPathComponent)
        }
    }

    var otherLines: String { lock.withLock { others } }
}

/// The window of a long archiving job (and of an update download): what's going on, the
/// percentage, a bar, the current file and ✕ to stop. Quick jobs never show it.
@MainActor
final class ArchiveProgress {
    private var window: NSWindow?
    private(set) var cancelled = false
    private var closed = false
    private let total: Int
    private let percent = NSTextField(labelWithString: L("Подготовка…"))
    private let bar = NSProgressIndicator()
    private let name = NSTextField(labelWithString: "")

    init(headline: [(text: String, link: URL?)], total: Int, cancel: @escaping () -> Void) {
        self.total = total
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.show(headline, cancel) }
        }
    }

    func update(done: Int, name current: String) {
        guard total > 0 else { return }
        let fraction = min(0.99, Double(done) / Double(total))
        bar.doubleValue = fraction * 100
        percent.stringValue = L("%@% выполнено", Int(fraction * 100))
        window?.title = percent.stringValue
        name.stringValue = current
    }

    private func show(_ headline: [(text: String, link: URL?)], _ cancel: @escaping () -> Void) {
        guard !closed else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.title = percent.stringValue
        window.isReleasedWhenClosed = false
        percent.font = .systemFont(ofSize: 18)
        bar.isIndeterminate = total == 0
        bar.minValue = 0
        bar.maxValue = 100
        if total == 0 { bar.startAnimation(nil) }
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        let stop = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Отмена")) ?? NSImage(), target: nil, action: nil)
        stop.isBordered = false
        stop.toolTip = L("Отмена")
        let handler = ButtonHandler { [weak self] in
            self?.cancelled = true
            cancel()
        }
        stop.target = handler
        stop.action = #selector(ButtonHandler.fire)
        objc_setAssociatedObject(stop, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        let titleRow = NSStackView(views: [percent, NSView(), stop])
        let stack = NSStackView(views: [FileOperationUI.headlineView(headline), titleRow, bar, name])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        for view in [titleRow, bar, name] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
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

/// Old name kept for the updater's download window.
typealias BusyIndicator = ArchiveProgress

extension ArchiveProgress {
    convenience init(title: String, cancel: @escaping () -> Void) {
        self.init(headline: [(title, nil)], total: 0, cancel: cancel)
    }
}

private final class ButtonHandler: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
