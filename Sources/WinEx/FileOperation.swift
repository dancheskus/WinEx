import Foundation

/// A copy, move, move to the Trash or deletion, run on a background thread with progress,
/// pause and cancel — the engine behind `FileOperationWindow`. It doesn't touch the UI: questions
/// (name conflicts, errors) go through the `decideConflicts` / `onError` hooks, which are called on
/// the worker thread and may block until the user answers.
final class FileOperation: @unchecked Sendable {
    enum Kind: Sendable { case copy, move, trash, delete }

    enum Resolution: Sendable { case replace, skip, keepBoth }

    /// A source whose name is already taken in the destination.
    struct Conflict: Sendable {
        let source: URL
        let existing: URL
    }

    enum ErrorAction: Sendable { case skip, cancel }

    enum Phase: Sendable { case counting, waiting, working, finished }

    struct Progress: Sendable {
        var phase: Phase = .counting
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var totalItems = 0
        var doneItems = 0
        var currentName = ""
        var paused = false
        var cancelled = false
        /// Progress is counted in bytes (copying) or in items (renames, Trash, deletion).
        var byBytes = true

        var fraction: Double {
            if byBytes, totalBytes > 0 { return min(1, Double(doneBytes) / Double(totalBytes)) }
            return totalItems > 0 ? min(1, Double(doneItems) / Double(totalItems)) : 0
        }
    }

    let kind: Kind
    let sources: [URL]
    let destination: URL?

    /// Asked once when names clash; returns a resolution per source (missing: skip).
    var decideConflicts: (([Conflict]) -> [URL: Resolution]?)?
    /// Asked on a failure; nil hook: skip.
    var onError: ((Error, URL) -> ErrorAction)?
    /// Replaced items go to the Trash (off in tests: they'd land in the user's Trash).
    var trashReplacedItems = true
    /// Called on the worker thread when everything is done (or cancelled).
    var onFinish: ((Result) -> Void)?

    struct Result: Sendable {
        /// Copied / moved: source → destination. Trashed: original → where it is in the Trash.
        var done: [(from: URL, to: URL)] = []
        var cancelled = false
    }

    /// Scenarios: copy byte by byte instead of cloning, slowed down, so the progress can be seen.
    nonisolated(unsafe) static var cloneFiles = true
    nonisolated(unsafe) static var slowDownForTesting: TimeInterval = 0

    private let lock = NSCondition()
    private var state = Progress()
    private var result = Result()

    init(kind: Kind, sources: [URL], destination: URL? = nil) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
    }

    var progress: Progress { lock.withLock { state } }

    func pause() { lock.withLock { state.paused = true } }

    func resume() {
        lock.withLock {
            state.paused = false
            lock.broadcast()
        }
    }

    func cancel() {
        lock.withLock {
            state.cancelled = true
            state.paused = false
            lock.broadcast()
        }
    }

    func start() {
        Thread.detachNewThread { [self] in run() }
    }

    /// Runs on the calling thread (tests).
    func run() {
        defer {
            let result = lock.withLock { () -> Result in
                state.phase = .finished
                self.result.cancelled = state.cancelled
                return self.result
            }
            onFinish?(result)
        }
        switch kind {
        case .copy, .move: transfer()
        case .trash, .delete: remove()
        }
    }

    // MARK: - Pause / cancel

    /// Blocks while paused; false once cancelled.
    private func shouldContinue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while state.paused && !state.cancelled { lock.wait() }
        return !state.cancelled
    }

    private func update(_ change: (inout Progress) -> Void) {
        lock.withLock { change(&state) }
    }

    // MARK: - Copy / move

    private struct Job {
        let source: URL
        var target: URL
        let bytes: Int64
        let files: Int
        /// A move within one volume: a rename, instant.
        let rename: Bool
        var replacing: URL?
    }

    private func transfer() {
        guard let destination else { return }
        let fm = FileManager.default
        let targetPath = destination.standardizedFileURL.path

        // 1. What to do with each source, and how much there is to copy
        var jobs: [Job] = []
        var conflicts: [Conflict] = []
        for source in sources {
            guard shouldContinue() else { return }
            let sourcePath = source.standardizedFileURL.path
            if targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/") {
                if ask(CocoaError(.fileWriteNoPermission, userInfo: [
                    NSLocalizedDescriptionKey: "Нельзя поместить папку «\(source.lastPathComponent)» в саму себя.",
                ]), source) == .cancel { cancel(); return }
                continue
            }
            let sameFolder = source.deletingLastPathComponent().standardizedFileURL.path == targetPath
            if kind == .move && sameFolder { continue }  // already there
            let rename = kind == .move && Self.onSameVolume(source, destination)
            let (bytes, files) = rename ? (0, 1) : Self.size(of: source)
            var target = destination.appendingPathComponent(source.lastPathComponent)
            if sameFolder {
                // A copy into its own folder: "name - копия", like Finder and Explorer
                target = FileOps.uniqueDestination(for: source.lastPathComponent, in: destination)
            } else if fm.fileExists(atPath: target.path) || (try? target.checkResourceIsReachable()) == true {
                conflicts.append(Conflict(source: source, existing: target))
            }
            jobs.append(Job(source: source, target: target, bytes: bytes, files: files, rename: rename))
            update {
                $0.totalBytes += bytes
                $0.totalItems += files
            }
        }

        // 2. Name clashes: replace, skip or keep both — the user decides
        if !conflicts.isEmpty {
            update { $0.phase = .waiting }
            guard let decisions = decideConflicts?(conflicts) else { cancel(); return }
            jobs = jobs.compactMap { job in
                guard conflicts.contains(where: { $0.source == job.source }) else { return job }
                var job = job
                switch decisions[job.source] ?? .skip {
                case .skip:
                    update {
                        $0.totalBytes -= job.bytes
                        $0.totalItems -= job.files
                    }
                    return nil
                case .replace: job.replacing = job.target
                case .keepBoth: job.target = FileOps.uniqueDestination(for: job.source.lastPathComponent, in: destination)
                }
                return job
            }
        }
        let everythingRenames = jobs.allSatisfy(\.rename)
        update {
            $0.phase = .working
            $0.byBytes = !everythingRenames
        }

        // 3. The work
        for job in jobs {
            guard shouldContinue() else { return }
            update { $0.currentName = job.source.lastPathComponent }
            if let replacing = job.replacing, !removeReplaced(replacing, source: job.source) { continue }
            let (bytesBefore, itemsBefore) = lock.withLock { (state.doneBytes, state.doneItems) }
            do {
                if job.rename {
                    try fm.moveItem(at: job.source, to: job.target)
                } else {
                    try copy(job.source, to: job.target)
                    if kind == .move { try fm.removeItem(at: job.source) }
                }
                lock.withLock { result.done.append((job.source, job.target)) }
            } catch {
                // A copy cut short leaves nothing half-done behind
                if !job.rename { try? fm.removeItem(at: job.target) }
                if progress.cancelled { return }
                if ask(error, job.source) == .cancel { cancel(); return }
            }
            update {
                $0.doneBytes = bytesBefore + job.bytes
                $0.doneItems = itemsBefore + job.files
            }
        }
    }

    /// Makes room for a replacing item: the old one goes to the Trash (deleted where there's none).
    private func removeReplaced(_ url: URL, source: URL) -> Bool {
        let fm = FileManager.default
        do {
            if trashReplacedItems, (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { return true }
            try fm.removeItem(at: url)
            return true
        } catch {
            if ask(error, source) == .cancel { cancel() }
            return false
        }
    }

    // MARK: copyfile with progress

    /// Bytes copied before the current file of a folder copy, and of the current file.
    private var copiedInFinishedFiles: Int64 = 0
    private var copyBase: Int64 = 0

    private func copy(_ source: URL, to target: URL) throws {
        guard let copyState = copyfile_state_alloc() else { throw CocoaError(.fileWriteUnknown) }
        defer { copyfile_state_free(copyState) }
        copyBase = progress.doneBytes
        copiedInFinishedFiles = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CTX), context)
        let callback: copyfile_callback_t = { what, stage, state, source, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let operation = Unmanaged<FileOperation>.fromOpaque(context).takeUnretainedValue()
            return operation.copyStatus(what: what, stage: stage, state: state, source: source)
        }
        copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        // Clones on APFS (instant, no extra space), copies elsewhere; links are copied as links
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | (Self.cloneFiles ? COPYFILE_CLONE : 0))
        if copyfile(source.path, target.path, copyState, flags) != 0 {
            if progress.cancelled { throw CocoaError(.userCancelled) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func copyStatus(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?) -> Int32 {
        guard shouldContinue() else { return COPYFILE_QUIT }
        switch (what, stage) {
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            if Self.slowDownForTesting > 0 { Thread.sleep(forTimeInterval: Self.slowDownForTesting) }
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            update { $0.doneBytes = self.copyBase + self.copiedInFinishedFiles + Int64(copied) }
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            if let source { update { $0.currentName = (String(cString: source) as NSString).lastPathComponent } }
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            var info = stat()
            if let source, lstat(source, &info) == 0 { copiedInFinishedFiles += Int64(info.st_size) }
            update {
                $0.doneBytes = self.copyBase + self.copiedInFinishedFiles
                $0.doneItems += 1
            }
        case (_, COPYFILE_ERR):
            // A file that can't be copied: ask whether to go on without it
            let path = source.map { String(cString: $0) } ?? ""
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            return ask(error, URL(fileURLWithPath: path)) == .cancel ? COPYFILE_QUIT : COPYFILE_SKIP
        default:
            break
        }
        return COPYFILE_CONTINUE
    }

    // MARK: - Trash / delete

    private func remove() {
        let fm = FileManager.default
        let items = sources.filter { (try? $0.checkResourceIsReachable()) == true || fm.fileExists(atPath: $0.path) }
        update {
            $0.totalItems = items.count
            $0.byBytes = false
            $0.phase = .working
        }
        for url in items {
            guard shouldContinue() else { return }
            update { $0.currentName = url.lastPathComponent }
            do {
                if kind == .trash {
                    var trashed: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &trashed)
                    if let trashed = trashed as URL? { lock.withLock { result.done.append((url, trashed)) } }
                } else {
                    try fm.removeItem(at: url)
                    lock.withLock { result.done.append((url, url)) }
                }
            } catch {
                if ask(error, url) == .cancel { cancel(); return }
            }
            update { $0.doneItems += 1 }
        }
    }

    // MARK: - Helpers

    private func ask(_ error: Error, _ url: URL) -> ErrorAction {
        onError?(error, url) ?? .skip
    }

    private static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let x = volume(a), let y = volume(b) else { return false }
        return x.isEqual(y)
    }

    /// Bytes and files in `url` (a file or a whole folder).
    static func size(of url: URL, cancel: CancelFlag? = nil) -> (bytes: Int64, files: Int) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            return (Int64(values?.fileSize ?? 0), 1)
        }
        var bytes: Int64 = 0, files = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            if files % 1000 == 0, cancel?.isCancelled == true { break }
            let itemValues = try? item.resourceValues(forKeys: keys)
            if itemValues?.isDirectory == true && itemValues?.isSymbolicLink != true { continue }
            bytes += Int64(itemValues?.fileSize ?? 0)
            files += 1
        }
        return (bytes, max(files, 1))
    }
}
