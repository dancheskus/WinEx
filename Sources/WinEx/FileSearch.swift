import AppKit

/// What to look for: words in the name (all of them), optionally in the contents too, in a folder
/// with its subfolders or on the whole Mac. Stored in a tab as an `x-winex-search://` URL.
struct SearchRequest: Equatable {
    var text: String
    /// The folder the search started in (results are shown for it unless `wholeMac`).
    var folder: URL?
    var wholeMac = false
    var contents = true

    static let scheme = "x-winex-search"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "search"
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "in", value: folder?.path),
            URLQueryItem(name: "all", value: wholeMac ? "1" : "0"),
            URLQueryItem(name: "content", value: contents ? "1" : "0"),
        ]
        return components.url ?? URL(fileURLWithPath: "/")
    }

    init(text: String, folder: URL?, wholeMac: Bool = false, contents: Bool = true) {
        self.text = text
        self.folder = folder
        self.wholeMac = wholeMac
        self.contents = contents
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        text = value("q") ?? ""
        folder = value("in").map { URL(fileURLWithPath: $0) }
        wholeMac = value("all") == "1"
        contents = value("content") != "0"
    }

    var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Where Spotlight looks: the folder (with subfolders) or every indexed volume.
    var scope: URL? { wholeMac ? nil : folder }

    /// Very short words on the whole Mac would match most of the disk.
    var isTooShort: Bool { text.trimmingCharacters(in: .whitespaces).count < (wholeMac ? 2 : 1) }

    /// Spotlight: every word in the file name, or (with `contents`) the text inside the file.
    var predicate: NSPredicate {
        let names = words.map { word -> NSPredicate in
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
            return NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(escaped)*")
        }
        // NSMetadataQuery rejects (throws on) AND / OR groups of a single predicate
        let name = names.count == 1 ? names[0] : NSCompoundPredicate(andPredicateWithSubpredicates: names)
        guard contents else { return name }
        let content = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", text)
        return NSCompoundPredicate(orPredicateWithSubpredicates: [name, content])
    }

    /// The same name test for folders Spotlight doesn't index.
    func nameMatches(_ name: String) -> Bool {
        let words = words
        return !words.isEmpty && words.allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Runs a search and reports results as they come.
///
/// Spotlight does the work: the system keeps its index up to date anyway, so a search costs
/// WinEx nothing while it isn't running — no index of our own, no rescans. Results update live
/// (batched), are capped, and the query stops as soon as nobody shows it. Folders Spotlight
/// doesn't cover (network and some external volumes, excluded folders) get a one-off walk by
/// name at background priority, bounded in size; ⌘R runs it again.
@MainActor
final class FileSearch {
    struct State {
        var results: [URL] = []
        /// Spotlight is still collecting (first results may already be in).
        var gathering = true
        /// Folders are being walked because Spotlight doesn't index them.
        var walking = false
        /// More matches exist than `resultLimit`; the most relevant are shown.
        var truncated = false
    }

    static let resultLimit = 2000
    /// Most entries a fallback walk looks at.
    static let walkLimit = 300_000

    private(set) var state = State()
    var onChange: ((State) -> Void)?

    private let query = NSMetadataQuery()
    private let observers = Observers()
    private let walkScope: URL?
    private let nameMatch: ((String) -> Bool)?
    private var spotlight: [URL] = []
    private var walked: [URL] = []
    private var walk: CancelFlag?
    private var walkedOnce = false

    /// `nameMatch` enables the fallback walk of `scope` (name searches only).
    init(predicate: NSPredicate, scope: URL?, nameMatch: ((String) -> Bool)? = nil) {
        query.predicate = predicate
        query.searchScopes = [scope ?? NSMetadataQueryLocalComputerScope]
        // Keep the most relevant matches when there are too many
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataQueryResultContentRelevanceAttribute, ascending: false)]
        // Live updates at most twice a second (a download or a build can change thousands of files)
        query.notificationBatchingInterval = 0.5
        walkScope = scope
        self.nameMatch = nameMatch
    }

    convenience init(_ request: SearchRequest) {
        self.init(predicate: request.predicate, scope: request.scope, nameMatch: request.scope == nil ? nil : request.nameMatches)
    }

    func start() {
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidUpdate] {
            observers.add(name, object: query) { [weak self] in self?.collect(finished: false) }
        }
        observers.add(.NSMetadataQueryDidFinishGathering, object: query) { [weak self] in self?.collect(finished: true) }
        query.start()
        // Volumes Spotlight surely doesn't index: walk right away, don't wait for an empty answer
        if let walkScope, !Self.isIndexedVolume(walkScope) { startWalk() }
    }

    func stop() {
        query.stop()
        observers.removeAll()
        walk?.cancel()
        walk = nil
    }

    private func collect(finished: Bool) {
        query.disableUpdates()
        let count = min(query.resultCount, Self.resultLimit)
        spotlight = (0..<count).compactMap { index in
            (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }.map { URL(fileURLWithPath: $0) }
        state.truncated = query.resultCount > Self.resultLimit
        query.enableUpdates()
        if finished {
            state.gathering = false
            // Nothing from Spotlight in a folder: maybe it isn't indexed — look by name
            if spotlight.isEmpty, walkScope != nil, !walkedOnce { startWalk() }
        }
        publish()
    }

    private func publish() {
        var seen = Set<String>()
        state.results = (spotlight + walked).filter { seen.insert($0.path).inserted }
        if state.results.count > Self.resultLimit {
            state.results.removeLast(state.results.count - Self.resultLimit)
            state.truncated = true
        }
        onChange?(state)
    }

    // MARK: Fallback walk

    private func startWalk() {
        guard let scope = walkScope, let nameMatch, walk == nil else { return }
        walkedOnce = true
        let flag = CancelFlag()
        walk = flag
        state.walking = true
        let showHidden = Settings.showHidden
        let limit = Self.resultLimit, walkLimit = Self.walkLimit
        // Lowest useful priority: the Mac stays responsive, the battery calm
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            let enumerator = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: [], options: options,
                                                            errorHandler: { _, _ in true })
            var found: [URL] = []
            var looked = 0
            var lastReport = Date()
            func report(done: Bool) {
                let batch = found
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !flag.isCancelled else { return }
                        self.walked = batch
                        if done {
                            self.state.walking = false
                            self.walk = nil
                        }
                        self.publish()
                    }
                }
            }
            while let url = enumerator?.nextObject() as? URL {
                if flag.isCancelled { return }
                looked += 1
                if nameMatch(url.lastPathComponent) {
                    found.append(url)
                    if found.count >= limit { break }
                }
                if looked >= walkLimit { break }
                if Date().timeIntervalSince(lastReport) > 0.5 {
                    lastReport = Date()
                    report(done: false)
                }
            }
            report(done: true)
        }
    }

    /// Local, internal volumes are indexed by default; network and removable ones usually aren't.
    private static func isIndexedVolume(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        return values?.volumeIsLocal != false && values?.volumeIsInternal != false
    }
}

/// A cancellation flag shared with background work.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
