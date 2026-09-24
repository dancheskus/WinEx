import AppKit

/// Copy / cut / paste of files, shared by every window and the desktop.
///
/// Cut works like in Explorer: ⌘X puts the files on the pasteboard and remembers them as
/// "cut" (shown dimmed); pasting moves them. The cut mark disappears as soon as anything else
/// lands on the pasteboard — another ⌘X / ⌘C here, or a copy in any other app.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()
    /// Posted when the set of cut files changes, so views can update their dimming.
    static let didChange = Notification.Name("WinExFileClipboardDidChange")

    private(set) var cutPaths: Set<String> = []
    private var cutChangeCount = -1
    private var watchTimer: Timer?

    private var pasteboard: NSPasteboard { .general }

    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func isCut(_ url: URL) -> Bool {
        !cutPaths.isEmpty && cutPaths.contains(url.path)
    }

    func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        write(urls)
        setCut([])
    }

    func cut(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        write(urls)
        cutChangeCount = pasteboard.changeCount
        setCut(Set(urls.map(\.path)))
    }

    /// Pastes into `directory`: moves if the pasteboard holds our cut files, copies otherwise.
    func paste(into directory: URL) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let move = pasteboard.changeCount == cutChangeCount && Set(urls.map(\.path)) == cutPaths
        if move {
            // A cut can be pasted only once, like in Explorer
            pasteboard.clearContents()
            setCut([])
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            for source in urls {
                do {
                    if move {
                        // Pasting into the folder the files came from does nothing
                        guard source.deletingLastPathComponent().standardizedFileURL.path != directory.standardizedFileURL.path else { continue }
                        if directory.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") {
                            throw CocoaError(.fileWriteNoPermission, userInfo: [
                                NSLocalizedDescriptionKey: "Нельзя переместить папку «\(source.lastPathComponent)» в саму себя.",
                            ])
                        }
                        try fm.moveItem(at: source, to: FileOps.uniqueDestination(for: source.lastPathComponent, in: directory))
                    } else {
                        try fm.copyItem(at: source, to: FileOps.uniqueDestination(for: source.lastPathComponent, in: directory))
                    }
                } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
            }
        }
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    private func setCut(_ paths: Set<String>) {
        guard paths != cutPaths else { return }
        cutPaths = paths
        watchTimer?.invalidate()
        watchTimer = nil
        if !paths.isEmpty {
            // Other apps don't notify about pasteboard changes; poll while something is cut
            watchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                MainActor.assumeIsolated { FileClipboard.shared.checkPasteboard() }
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func checkPasteboard() {
        if pasteboard.changeCount != cutChangeCount { setCut([]) }
    }
}
