import Foundation

/// Reads folder listings on a background queue so big folders don't freeze the window.
///
/// - Each `read` supersedes the previous one: a stale result is never delivered.
/// - `refresh` requests arriving while a read is running collapse into one follow-up read
///   (a copy of thousands of files fires the watcher constantly).
/// - The main thread waits a few milliseconds for the result, so small folders appear at once,
///   without a blank frame; only slow listings are delivered later.
@MainActor
final class FolderLoader {
    struct Listing: @unchecked Sendable {
        var items: [FileItem] = []
        /// The order `items` are sorted in, if any.
        var order: FileItem.SortOrder?
        var error: Error?
    }

    typealias Produce = @Sendable () -> Listing

    private let queue = DispatchQueue(label: "dev.winex.folder-loader", qos: .userInitiated)
    private var generation = 0
    private var running = false
    private var followUp: (produce: Produce, apply: (Listing) -> Void)?

    /// How long the main thread may wait for a listing before letting it arrive asynchronously.
    static let patience: TimeInterval = 0.03

    /// A read is running and its result hasn't been shown yet.
    var isWaiting: Bool { running }

    /// Starts a new read, dropping any read in progress.
    func read(_ produce: @escaping Produce, apply: @escaping (Listing) -> Void) {
        generation += 1
        followUp = nil
        start(produce, apply: apply)
    }

    /// Re-reads; while a read is running, only the latest request is kept and runs after it.
    func refresh(_ produce: @escaping Produce, apply: @escaping (Listing) -> Void) {
        if running {
            followUp = (produce, apply)
        } else {
            start(produce, apply: apply)
        }
    }

    /// Forgets the read in progress (the view shows something else now).
    func cancel() {
        generation += 1
        followUp = nil
        running = false
    }

    private func start(_ produce: @escaping Produce, apply: @escaping (Listing) -> Void) {
        let token = generation
        let delivery = Delivery()
        running = true
        queue.async {
            delivery.fulfil(produce())
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.deliver(delivery, token: token, apply: apply) }
            }
        }
        if delivery.wait(Self.patience) { deliver(delivery, token: token, apply: apply) }
    }

    private func deliver(_ delivery: Delivery, token: Int, apply: (Listing) -> Void) {
        guard token == generation, let listing = delivery.take() else { return }
        running = false
        apply(listing)
        if let next = followUp, token == generation {
            followUp = nil
            start(next.produce, apply: next.apply)
        }
    }

    /// Hands one listing from the queue to whichever main-thread path gets there first.
    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var listing: Listing?
        private var taken = false

        func fulfil(_ value: Listing) {
            lock.withLock { listing = value }
            ready.signal()
        }

        func wait(_ seconds: TimeInterval) -> Bool {
            ready.wait(timeout: .now() + seconds) == .success
        }

        func take() -> Listing? {
            lock.withLock {
                guard !taken, let listing else { return nil }
                taken = true
                return listing
            }
        }
    }

    /// The contents of `directory`, with the resource values the views need already fetched.
    nonisolated static func contents(of directory: URL, showHidden: Bool, sortedBy order: FileItem.SortOrder) -> Listing {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: FileItem.keys, options: options)
            return Listing(items: FileItem.sorted(urls.map(FileItem.init), by: order), order: order)
        } catch {
            return Listing(error: error)
        }
    }
}
