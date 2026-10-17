import AppKit

/// iCloud Drive as Finder shows it: its own folder and, among its items, the folders of the apps
/// that keep documents in iCloud (Pages, TextEdit, Shortcuts…) — each app's container in
/// ~/Library/Mobile Documents that isn't hidden (the hidden ones are apps' private data).
enum CloudDrive {
    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    nonisolated static let mobileDocumentsPath = root.deletingLastPathComponent().path + "/"

    /// An app's folder in iCloud Drive as Finder draws it: a folder with the app's icon on it (when
    /// the app is on this Mac — found by the container's name, «com~apple~Pages» → com.apple.Pages).
    nonisolated static func appFolderIcon(_ url: URL) -> NSImage? {
        guard url.lastPathComponent == "Documents", url.path.hasPrefix(mobileDocumentsPath), !url.path.hasPrefix(root.path) else { return nil }
        let folder = NSWorkspace.shared.icon(for: .folder)
        var id = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "~", with: ".")
        if id.hasPrefix("iCloud.") { id.removeFirst("iCloud.".count) }
        // (iWork's containers are named without «iWork»: com~apple~Pages is com.apple.iWork.Pages)
        let iWork = id.hasPrefix("com.apple.") ? "com.apple.iWork." + id.dropFirst("com.apple.".count) : id
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: iWork) else { return folder }
        let appIcon = NSWorkspace.shared.icon(forFile: app.path)
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            folder.draw(in: rect)
            // In the middle of the folder's front
            let side = rect.width * 0.46
            appIcon.draw(in: NSRect(x: rect.midX - side / 2, y: rect.height * 0.2, width: side, height: side))
            return true
        }
    }

    /// Finder's cloud after the name of a file that's in iCloud only (secondary text colour).
    static func cloudBadge(font: NSFont) -> NSAttributedString {
        let side = (font.pointSize * 1.05).rounded()
        guard let symbol = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side * 0.8, weight: .regular)) else { return NSAttributedString() }
        let size = symbol.size
        // Coloured as it's drawn (the label's colour is set for the name)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        // A no-break space: the cloud stays with the name's last word (never alone on a line)
        let badge = NSMutableAttributedString(string: "\u{00A0}", attributes: [.font: font])
        badge.append(NSAttributedString(attachment: attachment))
        return badge
    }

    /// The apps' «Documents» folders (named after their app: «Pages», «Просмотр»).
    nonisolated static func appFolders() -> [URL] {
        let containers = (try? FileManager.default.contentsOfDirectory(at: root.deletingLastPathComponent(), includingPropertiesForKeys: [.isHiddenKey])) ?? []
        return containers.compactMap { container in
            guard container.lastPathComponent != root.lastPathComponent,
                  (try? container.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == false else { return nil }
            let documents = container.appendingPathComponent("Documents")
            return FileManager.default.fileExists(atPath: documents.path) ? documents : nil
        }
    }
}

/// iCloud Drive's uploads and downloads as Finder shows them: iCloud publishes a progress per file
/// (NSProgress file progress); WinEx follows them for a circle by «iCloud Drive» in the sidebar and
/// a bar on the file's icon.
@MainActor
final class CloudProgress {
    static let shared = CloudProgress()
    /// Posted (at most a few times a second) when a file's progress moves, starts or ends.
    static let changed = Notification.Name("WinExCloudProgressChanged")

    static let root = CloudDrive.root
    /// iCloud Drive with the apps' folders (Pages, Numbers…), as Finder counts it.
    static let mobileDocuments = root.deletingLastPathComponent()

    private final class Transfer {
        let progress: Progress
        var observation: NSKeyValueObservation?
        init(_ progress: Progress) { self.progress = progress }
    }

    /// By the file's path with symlinks resolved (a file of Desktop & Documents in iCloud is
    /// published under iCloud Drive and shown under the home folder).
    private var transfers: [String: Transfer] = [:]
    /// Subscriptions by folder, with how many want each: a folder's subscription sees only the
    /// files right in it, so every folder shown is followed while it's shown.
    private var subscriptions: [String: (count: Int, token: Any)] = [:]
    private var postPending = false

    /// Folders anywhere in iCloud Drive where something changed lately, followed for a while: a
    /// file written or brought down there is what iCloud moves next (the sidebar's circle counts it).
    private var recent: [String: Date] = [:]
    private var events: FSEventStreamRef?
    private var pruneTimer: Timer?

    /// Once at launch: iCloud Drive, the home folder, Desktop and Documents (may be in iCloud),
    /// and whatever changes inside iCloud Drive.
    func start() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in [Self.root, home, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents")] { follow(folder) }
        watchCloudDrive()
    }

    private func watchCloudDrive() {
        guard events == nil, FileManager.default.fileExists(atPath: Self.root.path) else { return }
        var context = FSEventStreamContext()
        let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let folders = Array(list.prefix(count))
            MainActor.assumeIsolated { CloudProgress.shared.changed(in: folders) }
        }
        let resolved = Self.mobileDocuments.resolvingSymlinksInPath().path
        guard let stream = FSEventStreamCreate(nil, callback, &context, [resolved] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        events = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// (Folder-level events: each path is a folder whose contents changed.)
    private func changed(in folders: [String]) {
        let until = Date().addingTimeInterval(180)
        for path in folders {
            let folder = URL(fileURLWithPath: path).standardizedFileURL
            let key = folder.path
            if recent[key] == nil { follow(folder) }
            recent[key] = until
        }
        if pruneTimer == nil, !recent.isEmpty {
            pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { CloudProgress.shared.prune() }
            }
        }
    }

    /// Stops following the folders quiet for a few minutes (unless a file there is still moving).
    private func prune() {
        let now = Date()
        for (key, until) in recent where until < now && !transfers.keys.contains(where: { ($0 as NSString).deletingLastPathComponent == key }) {
            recent[key] = nil
            unfollow(URL(fileURLWithPath: key))
        }
        if recent.isEmpty { pruneTimer?.invalidate(); pruneTimer = nil }
    }

    /// Follows the files right in `folder` until `unfollow` (calls are counted).
    func follow(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if let existing = subscriptions[path] {
            subscriptions[path] = (existing.count + 1, existing.token)
            return
        }
        let rootPath = Self.mobileDocuments.path
        let token = Progress.addSubscriber(forFileURL: folder) { progress in
            let info = progress.userInfo
            let kind = info[.fileOperationKindKey] as? Progress.FileOperationKind
            guard let url = info[.fileURLKey] as? URL, kind == .uploading || kind == .downloading,
                  info[.init("BRProgressIsCreatedByCloudDocsKey")] != nil || url.path.hasPrefix(rootPath) else { return nil }
            let key = url.resolvingSymlinksInPath().path
            Task { @MainActor in CloudProgress.shared.add(progress, key: key) }
            return { Task { @MainActor in CloudProgress.shared.remove(progress, key: key) } }
        }
        subscriptions[path] = (1, token)
    }

    func unfollow(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard let existing = subscriptions[path] else { return }
        if existing.count > 1 {
            subscriptions[path] = (existing.count - 1, existing.token)
        } else {
            Progress.removeSubscriber(existing.token)
            subscriptions[path] = nil
        }
    }

    private func add(_ progress: Progress, key: String) {
        let transfer = Transfer(progress)
        transfer.observation = progress.observe(\.fractionCompleted) { _, _ in
            Task { @MainActor in CloudProgress.shared.post() }
        }
        transfers[key] = transfer
        post()
    }

    private func remove(_ progress: Progress, key: String) {
        guard transfers[key]?.progress === progress else { return }
        transfers[key] = nil
        post()
    }

    private func post() {
        guard !postPending else { return }
        postPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            postPending = false
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    var isActive: Bool { !transfers.isEmpty }

    /// How far the file's upload or download is (nil when it isn't being moved).
    func fraction(for url: URL) -> Double? {
        guard !transfers.isEmpty else { return nil }
        return transfers[url.resolvingSymlinksInPath().path]?.progress.fractionCompleted
    }

    /// All transfers together, by bytes (nil when nothing is moving).
    var total: Double? {
        guard !transfers.isEmpty else { return nil }
        let progresses = transfers.values.map(\.progress)
        let total = progresses.reduce(Int64(0)) { $0 + max($1.totalUnitCount, 0) }
        guard total > 0 else { return progresses.map(\.fractionCompleted).reduce(0, +) / Double(progresses.count) }
        return Double(progresses.reduce(Int64(0)) { $0 + max($1.completedUnitCount, 0) }) / Double(total)
    }

    #if DEBUG
    /// For scenarios: a transfer that isn't iCloud's.
    func debugSet(_ progress: Progress?, for url: URL) {
        let key = url.resolvingSymlinksInPath().path
        if let progress { add(progress, key: key) } else if let old = transfers[key] { remove(old.progress, key: key) }
    }
    #endif
}

/// A thin bar on a file's icon while iCloud moves the file; hidden otherwise.
final class CloudProgressBar: NSView {
    static let cellIdentifier = NSUserInterfaceItemIdentifier("cloudProgress")

    var url: URL? {
        didSet { if url != oldValue { update() } }
    }
    private var fraction: Double?
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        observer = NotificationCenter.default.addObserver(forName: CloudProgress.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func update() {
        let fraction = url.flatMap { CloudProgress.shared.fraction(for: $0) }
        // Shown: placed by the icon's layout (which skips it while hidden)
        if isHidden != (fraction == nil) {
            isHidden = fraction == nil
            superview?.needsLayout = true
        }
        if fraction != self.fraction { self.fraction = fraction; needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let fraction else { return }
        let radius = bounds.height / 2
        // Visible on a white document and on a dark folder alike
        NSColor.gray.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let inner = bounds.insetBy(dx: 1, dy: 1)
        var done = inner
        done.size.width = max(inner.height, inner.width * min(max(fraction, 0), 1))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: done, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

/// Finder's circle by «iCloud Drive» in the sidebar while anything uploads or downloads.
final class CloudProgressPie: NSView {
    private var fraction: Double?
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        observer = NotificationCenter.default.addObserver(forName: CloudProgress.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }  // Finder's size

    private func update() {
        fraction = CloudProgress.shared.total
        isHidden = fraction == nil
        toolTip = fraction.map { "iCloud Drive: \(Int(($0 * 100).rounded())) %" }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fraction else { return }
        let side = min(bounds.width, bounds.height) - 1
        let circle = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let color = NSColor.secondaryLabelColor
        color.setStroke()
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = 1.4
        ring.stroke()
        // The done part as a pie from twelve o'clock, clockwise
        let center = NSPoint(x: circle.midX, y: circle.midY)
        let pie = NSBezierPath()
        pie.move(to: center)
        pie.appendArc(withCenter: center, radius: side / 2 - 2.5, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(max(fraction, 0.02), 1)), clockwise: true)
        pie.close()
        color.setFill()
        pie.fill()
    }
}
