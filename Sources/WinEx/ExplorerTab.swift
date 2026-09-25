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

    var location: Location { Location(url) }
    var title: String { location.title }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.isFileURL && url.path != "/" }

    func navigate(to newURL: URL) {
        let target = newURL.standardizedFileURL
        guard Location(target) != location else { return }
        backStack.append(url)
        forwardStack.removeAll()
        url = target
    }

    /// Shows another place without a history step (refining a search).
    func replace(with newURL: URL) {
        url = newURL.standardizedFileURL
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

    /// "Очистить историю переходов": back and forward lead nowhere any more.
    func clearHistory() {
        backStack.removeAll()
        forwardStack.removeAll()
    }

    func goUp() {
        guard canGoUp else { return }
        pendingSelection = [url]
        navigate(to: url.deletingLastPathComponent())
    }
}
