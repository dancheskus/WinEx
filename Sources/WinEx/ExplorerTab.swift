import Foundation

/// One tab: a current folder plus its back/forward history.
final class ExplorerTab {
    let id = UUID()
    private(set) var url: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    /// Items to select the next time this tab's folder is shown.
    var pendingSelection: [URL] = []

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    var title: String { Places.isNetwork(url) ? "Сеть" : Self.tagName(of: url) ?? url.displayName }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.isFileURL && url.path != "/" }

    // MARK: Tag locations

    /// A tab can show "all files with a tag" instead of a folder; such locations use this URL scheme.
    static let tagScheme = "x-winex-tag"

    static func tagURL(_ name: String) -> URL {
        var components = URLComponents()
        components.scheme = tagScheme
        components.host = "tag"
        components.path = "/" + name
        return components.url!
    }

    static func tagName(of url: URL) -> String? {
        url.scheme == tagScheme ? String(url.path.dropFirst()) : nil
    }

    func navigate(to newURL: URL) {
        let target = newURL.standardizedFileURL
        // Same place? (folders compare by path, tag locations as a whole)
        guard target.isFileURL != url.isFileURL || (target.isFileURL ? target.path != url.path : target != url) else { return }
        backStack.append(url)
        forwardStack.removeAll()
        url = target
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        url = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        url = next
    }

    func goUp() {
        guard canGoUp else { return }
        pendingSelection = [url]
        navigate(to: url.deletingLastPathComponent())
    }
}
