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
        self.url = Self.normalized(url)
    }

    var location: Location { Location(url) }
    var title: String { location.title }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool {
        if case .device(_, let path) = location { return !path.isEmpty }
        return (url.isFileURL && url.path != "/") || Places.isServer(url)
    }

    func navigate(to newURL: URL) {
        let target = Self.normalized(newURL)
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
        navigate(to: Self.parent(of: url))
    }

    /// A server is kept as its address alone (smb://NAS._smb._tcp.local, no user or share).
    private static func normalized(_ url: URL) -> URL {
        Places.listsShares(url) ? Location(url).url : url.standardizedFileURL
    }

    /// Up from a share's top folder is its server's list of shares; up from a server, "Сеть".
    private static func parent(of url: URL) -> URL {
        if Places.isServer(url) { return Places.networkURL }
        // A device's folder: the one above, up to the device's page
        if case .device(let udid, let path) = Location(url) {
            return Places.deviceURL(udid, path: (path as NSString).deletingLastPathComponent == "/" ? "" : (path as NSString).deletingLastPathComponent)
        }
        if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true, let server = Places.serverURL(ofVolume: url) {
            return server
        }
        return url.deletingLastPathComponent()
    }
}
