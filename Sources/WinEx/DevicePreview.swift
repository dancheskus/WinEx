import AppKit
import Quartz

/// Space-bar Quick Look for a device's files and photos: the selected files are copied into a
/// cache (once: a copy of the same size is used again) and shown in the system panel; arrow keys
/// in the panel move the selection in the list, which shows the next one.
@MainActor
final class DevicePreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    struct Item: Equatable {
        let root: DeviceFileStore.Root
        let path: String
        let size: Int64?
    }

    /// The list whose selection is shown (keys pressed in the panel go to it).
    weak var keyView: NSView?
    /// A file being copied before the panel can show it: «Загрузка «name»… 34 %» (nil: done).
    var onLoading: ((String?) -> Void)?
    private var job: CancelFlag?
    private var store: DeviceFileStore?
    private var items: [Item] = []
    private var ready: [URL] = []
    private var generation = 0

    nonisolated static func cacheFolder(_ udid: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.winex.WinEx/Devices/\(udid)")
    }

    /// Where a device file's copy is kept.
    private static func local(_ item: Item, udid: String) -> URL {
        let root: String
        switch item.root {
        case .media: root = "Media"
        case .app(let id): root = id
        }
        return cacheFolder(udid).appendingPathComponent(root).appendingPathComponent(String(item.path.drop { $0 == "/" }))
    }

    /// Space: shows the items (or hides the panel when it's showing them).
    func toggle(_ items: [Item], store: DeviceFileStore) {
        if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil,
           panel.isVisible, panel.dataSource === self {
            return panel.orderOut(nil)
        }
        // Space again while the first file is still coming: never mind
        if job?.isCancelled == false, ready.isEmpty, !self.items.isEmpty {
            job?.cancel()
            generation += 1
            self.items = []
            onLoading?(nil)
            return
        }
        guard !items.isEmpty else { return }
        self.store = store
        load(items) { [weak self] in
            guard let self else { return }
            QuickLook.toggle(for: self)
        }
    }

    /// The selection changed: the panel (if it's open for this list) follows.
    func selectionChanged(_ items: [Item]) {
        guard let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil,
              panel.isVisible, panel.dataSource === self, !items.isEmpty, items != self.items else { return }
        load(items) { QLPreviewPanel.shared()?.reloadData() }
    }

    /// Copies what isn't cached yet, then `done` (the first file is enough to show; the others
    /// follow as they come).
    private func load(_ items: [Item], done: @escaping () -> Void) {
        guard let store else { return }
        generation += 1
        let generation = generation
        job?.cancel()
        let job = CancelFlag()
        self.job = job
        self.items = items
        let udid = store.udid
        let targets = items.map { Self.local($0, udid: udid) }
        ready = []
        var shown = false
        store.queue.async {
            for (item, target) in zip(items, targets) {
                let fm = FileManager.default
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
                if job.isCancelled { return }
                // (Photos come without their size: asked for, for the percent and the cached copy's check)
                let item = item.size != nil ? item
                    : Item(root: item.root, path: item.path, size: try? store.with(item.root) { try $0.info(item.path).size })
                if size == nil || (item.size != nil && size != item.size) {
                    try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let partial = target.appendingPathExtension("part")
                    let name = (item.path as NSString).lastPathComponent
                    // Only the first one keeps the panel waiting: it's what the spinner is for
                    let first = !shown
                    if first { DispatchQueue.main.async { if self.generation == generation { self.onLoading?(L("Загрузка «%@»…", name)) } } }
                    var lastPercent = -1
                    do {
                        try store.download(item.root, item.path, isDirectory: false, to: partial) { bytes in
                            if first, let total = item.size, total > 0 {
                                let percent = Int(Double(bytes) / Double(total) * 100)
                                if percent != lastPercent {
                                    lastPercent = percent
                                    DispatchQueue.main.async {
                                        if self.generation == generation { self.onLoading?(L("Загрузка «%@»… %@ %", name, String(min(percent, 100)))) }
                                    }
                                }
                            }
                            return !job.isCancelled
                        }
                        try? fm.removeItem(at: target)
                        try fm.moveItem(at: partial, to: target)
                    } catch {
                        try? fm.removeItem(at: partial)
                        MobileDevices.log.info("preview \(item.path, privacy: .public): \(String(describing: error), privacy: .public)")
                        if job.isCancelled { return }
                        continue
                    }
                }
                shown = true
                DispatchQueue.main.async {
                    guard self.generation == generation else { return }
                    self.ready.append(target)
                    if self.ready.count == 1 {
                        self.onLoading?(nil)
                        done()
                    } else {
                        QLPreviewPanel.shared()?.reloadData()
                    }
                }
            }
            // Nothing could be copied: no spinner left turning
            DispatchQueue.main.async {
                if self.generation == generation, self.ready.isEmpty {
                    self.items = []
                    self.onLoading?(nil)
                }
            }
        }
    }

    // MARK: Panel

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { ready.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { index < ready.count ? ready[index] as NSURL : nil }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard let event, let keyView else { return false }
            return QuickLook.forward(event, to: keyView, panel: panel)
        }
    }
}

/// The device lists' views take the panel when it's their preview's (see `QuickLook.accepts`).
@MainActor
protocol DevicePreviewHost: NSResponder {
    var preview: DevicePreview? { get }
}

extension DevicePreviewHost {
    func previewAccepts() -> Bool { preview.map { QuickLook.accepts($0) } ?? false }
    func previewBegin(_ panel: QLPreviewPanel) {
        panel.dataSource = preview
        panel.delegate = preview
    }
    func previewEnd(_ panel: QLPreviewPanel) {
        if let preview { QuickLook.detach(panel, from: preview) }
    }
}
