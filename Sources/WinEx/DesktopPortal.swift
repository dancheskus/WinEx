import AppKit
import QuickLookThumbnailing
import Quartz

/// A folder portal (Stardock Fences): a fence showing another folder's contents on the desktop —
/// icons with desktop-style labels, scrolling, selection, open, drag out, drop in, the file
/// context menu. It watches the folder (no polling) and reads it in the background.
@MainActor
final class PortalView: NSScrollView {
    let folder: URL
    private let grid: PortalGrid

    init(folder: URL, cell: NSSize, iconSide: CGFloat) {
        self.folder = folder
        grid = PortalGrid(folder: folder, cell: cell, iconSide: iconSide)
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        documentView = grid
        contentView.postsBoundsChangedNotifications = false
        grid.reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        grid.fitWidth(contentSize.width)
    }

    func update(cell: NSSize, iconSide: CGFloat) {
        grid.cell = cell
        grid.iconSide = iconSide
        grid.fitWidth(contentSize.width)
    }

    var itemCount: Int { grid.items.count }
}

/// The icons of a portal, drawn like the desktop's.
@MainActor
private final class PortalGrid: NSView, NSDraggingSource, FileMenuActions, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let folder: URL
    var cell: NSSize { didSet { if cell != oldValue { needsLayoutGrid = true } } }
    var iconSide: CGFloat { didSet { if iconSide != oldValue { needsLayoutGrid = true; thumbnails = [:] } } }
    private(set) var items: [FileItem] = []
    private var selection = Set<Int>() { didSet { needsDisplay = true; QuickLook.selectionChanged(in: self) } }
    private var anchor: Int?
    private var watcher: DirectoryWatcher?
    private var thumbnails: [String: NSImage] = [:]
    private var requested = Set<String>()
    private var columns = 1
    private var needsLayoutGrid = true
    private var width: CGFloat = 0
    private let observers = Observers()
    private var reading = false

    init(folder: URL, cell: NSSize, iconSide: CGFloat) {
        self.folder = folder
        self.cell = cell
        self.iconSide = iconSide
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        watcher = DirectoryWatcher(url: folder) { [weak self] in self?.reload() }
        observers.add(.showHiddenChanged) { [weak self] in self?.reload() }
        observers.add(.fileTagsChanged) { [weak self] in self?.reload() }
        let menu = NSMenu()
        menu.delegate = self
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Contents (read in the background: a portal to a big or network folder stays smooth)

    func reload() {
        guard !reading else { return }
        reading = true
        let folder = folder, showHidden = Settings.showHidden
        let selected = Set(selection.compactMap { items.indices.contains($0) ? items[$0].url.lastPathComponent : nil })
        DispatchQueue.global(qos: .utility).async {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: FileItem.keys,
                                                                      options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
            // A huge folder: the first thousands are plenty for a desktop portal
            let loaded = FileItem.sorted(urls.prefix(5000).map(FileItem.init), by: FileItem.SortOrder(key: "name", ascending: true))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                self.items = loaded
                self.selection = Set(loaded.indices.filter { selected.contains(loaded[$0].url.lastPathComponent) })
                let live = Set(loaded.map(self.thumbnailKey))
                self.thumbnails = self.thumbnails.filter { live.contains($0.key) }
                self.requested.formIntersection(live)
                self.needsLayoutGrid = true
                self.fitWidth(self.width)
            }
        }
    }

    func fitWidth(_ available: CGFloat) {
        width = available
        let newColumns = max(1, Int(available / cell.width))
        guard needsLayoutGrid || newColumns != columns || frame.width != available else { return }
        needsLayoutGrid = false
        columns = newColumns
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        setFrameSize(NSSize(width: available, height: max(CGFloat(rows) * cell.height + 6, superview?.bounds.height ?? 0)))
        needsDisplay = true
    }

    private func center(of index: Int) -> CGPoint {
        CGPoint(x: cell.width * (CGFloat(index % columns) + 0.5),
                y: 6 + iconSide / 2 + 8 + cell.height * CGFloat(index / columns))
    }

    private func iconRect(_ index: Int) -> NSRect {
        let c = center(of: index)
        return NSRect(x: c.x - iconSide / 2, y: c.y - iconSide / 2, width: iconSide, height: iconSide)
    }

    private func labelRect(_ index: Int) -> NSRect {
        let c = center(of: index)
        return NSRect(x: c.x - cell.width / 2 + 2, y: c.y + iconSide / 2 + 9, width: cell.width - 4, height: 32)
    }

    private func hitRect(_ index: Int) -> NSRect { iconRect(index).insetBy(dx: -4, dy: -4).union(labelRect(index)) }

    private func index(at point: NSPoint) -> Int? {
        items.indices.first { hitRect($0).contains(point) }
    }

    // MARK: Drawing

    private static let labelAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        return [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow]
    }()

    override func draw(_ dirtyRect: NSRect) {
        let font = Self.labelAttributes[.font] as? NSFont ?? .systemFont(ofSize: 12)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        for i in items.indices where hitRect(i).insetBy(dx: -8, dy: -8).intersects(dirtyRect) {
            let item = items[i]
            let icon = iconRect(i), label = labelRect(i)
            let text = NSMutableAttributedString(attributedString: FileTags.dots(for: item.tags, attributes: Self.labelAttributes))
            text.append(NSAttributedString(string: item.name, attributes: Self.labelAttributes))
            let lines = DesktopLabel.lines(text, width: label.width)
            let rects = lines.enumerated().map { n, line in
                let w = min(ceil(line.size().width), label.width)
                return NSRect(x: label.midX - w / 2, y: label.minY + CGFloat(n) * lineHeight, width: w, height: lineHeight)
            }
            if selection.contains(i) {
                let square = NSBezierPath(roundedRect: icon.insetBy(dx: -5, dy: -5), xRadius: 10, yRadius: 10)
                NSColor.black.withAlphaComponent(0.3).setFill()
                square.fill()
                NSColor.white.withAlphaComponent(0.4).setStroke()
                square.lineWidth = 2
                square.stroke()
                NSColor.selectedContentBackgroundColor.setFill()
                rects.forEach { NSBezierPath(roundedRect: $0.insetBy(dx: -4, dy: -1), xRadius: 4, yRadius: 4).fill() }
            }
            let image = self.image(for: i)
            image.draw(in: DesktopView.aspectFit(image.size, in: icon), from: .zero, operation: .sourceOver,
                       fraction: FileClipboard.shared.isCut(item.url) ? FileListViewController.cutAlpha : 1, respectFlipped: true, hints: nil)
            for (line, rect) in zip(lines, rects) { line.draw(in: rect.insetBy(dx: -2, dy: 0)) }
        }
    }

    private func thumbnailKey(_ item: FileItem) -> String {
        "\(Int(iconSide))|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.url.path)"
    }

    private func image(for index: Int) -> NSImage {
        let item = items[index]
        guard !item.isFolder, item.url.pathExtension != "app" else { return item.icon }
        let key = thumbnailKey(item)
        if let cached = thumbnails[key] { return cached }
        if !requested.contains(key) {
            requested.insert(key)
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: iconSide, height: iconSide),
                                                       scale: window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            request.iconMode = true
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let image = representation?.nsImage else { return }
                DispatchQueue.main.async {
                    self?.thumbnails[key] = image
                    self?.needsDisplay = true
                }
            }
        }
        return item.icon
    }

    // MARK: Mouse

    private var mouseDownPoint = NSPoint.zero
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        dragging = false
        guard let i = index(at: point) else {
            if !event.modifierFlags.contains(.command) { selection = [] }
            return
        }
        if event.modifierFlags.contains(.command) {
            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
        } else if event.modifierFlags.contains(.shift), let anchor {
            selection = Set(min(anchor, i)...max(anchor, i))
        } else if !selection.contains(i) {
            selection = [i]
        }
        anchor = i
        if event.clickCount == 2 { openSelected(nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !dragging, !selection.isEmpty, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        dragging = true
        let dragged = selection.sorted().map { i -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: items[i].url as NSURL)
            item.setDraggingFrame(iconRect(i), contents: items[i].icon)
            return item
        }
        beginDraggingSession(with: dragged, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete { FileOps.trash(selectedURLs) }
    }

    // MARK: Drops: into the portal's folder (or onto a folder in it)

    private var dropFolder: URL?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if let i = index(at: point), items[i].isFolder {
            let operation = FileDrop.operation(for: sender, into: items[i].url)
            if operation != [] { dropFolder = items[i].url; return operation }
        }
        dropFolder = folder
        return FileDrop.operation(for: sender, into: folder)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        FileDrop.perform(sender, into: dropFolder ?? folder)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch (event.keyCode, event.modifierFlags.intersection([.command, .shift, .option, .control])) {
        case (36, []), (125, [.command]): openSelected(nil)
        case (51, [.command]): moveToTrash(nil)
        case (0, [.command]): selection = Set(items.indices)
        case (49, []): if !selection.isEmpty { QuickLook.toggle(for: self) }
        case (53, []): selection = []
        default: super.keyDown(with: event)
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let point = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if let i = index(at: point) {
            if !selection.contains(i) { selection = [i] }
            FileContextMenu.addItems(to: menu, for: selectedURLs, target: self, folderTabs: false,
                                     customizableFolder: selection.count == 1 && items[i].isFolder)
        } else {
            selection = []
            let open = menu.addItem(withTitle: L("Открыть «%@» в WinEx", folder.displayName), action: #selector(openFolder(_:)), keyEquivalent: "")
            open.target = self
            open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            if FileClipboard.shared.canPaste {
                menu.addItem(withTitle: L("Вставить"), action: #selector(paste(_:)), keyEquivalent: "").target = self
            }
            menu.addItem(NewItemTemplate.menuItem(target: self, action: #selector(createNewItem(_:))))
        }
        MenuStyle.decorate(menu)
    }

    @objc private func openFolder(_ sender: Any?) { AppDelegate.shared.openWindow(at: folder) }

    @objc private func createNewItem(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? NewItemTemplate else { return }
        do {
            let url = try template.create(in: folder)
            FileUndo.recordCreate(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func paste(_ sender: Any?) { FileClipboard.shared.paste(into: folder) }

    // MARK: FileMenuActions

    private var selectedURLs: [URL] { selection.sorted().filter(items.indices.contains).map { items[$0].url } }

    func openSelected(_ sender: Any?) { selectedURLs.forEach(AppDelegate.shared.open) }
    func quickLook(_ sender: Any?) { QuickLook.toggle(for: self) }
    func cut(_ sender: Any?) { FileClipboard.shared.cut(selectedURLs) }
    func copy(_ sender: Any?) { FileClipboard.shared.copy(selectedURLs) }
    func copyPath(_ sender: Any?) { FileOps.copyPaths(selectedURLs) }
    func renameSelected(_ sender: Any?) {
        // Renaming happens in the folder's window, with the name selected
        guard let url = selectedURLs.first else { return }
        AppDelegate.shared.reveal(url)
    }
    func moveToTrash(_ sender: Any?) { FileOps.trash(selectedURLs) }
    func share(_ sender: Any?) {
        guard let first = selection.sorted().first else { return }
        NSSharingServicePicker(items: selectedURLs).show(relativeTo: iconRect(first), of: self, preferredEdge: .minY)
    }
    func toggleTag(_ sender: NSMenuItem) { FileContextMenu.toggleTag(sender) }
    func customizeFolder(_ sender: Any?) {
        guard let i = selection.sorted().first else { return }
        FolderCustomizationController.show(for: items[i].url, relativeTo: iconRect(i), of: self)
    }
    func showProperties(_ sender: Any?) { PropertiesWindowController.show(for: selectedURLs.isEmpty ? [folder] : selectedURLs) }
    func duplicate(_ sender: Any?) { FileCommands.duplicate(selectedURLs) }
    func compress(_ sender: Any?) { FileCommands.compress(selectedURLs) }
    func extractArchive(_ sender: Any?) { selectedURLs.filter(FileCommands.isZip).forEach(FileCommands.extract) }
    func makeAlias(_ sender: Any?) { FileCommands.makeAliases(selectedURLs) }
    func showOriginal(_ sender: Any?) {
        if let url = selectedURLs.first(where: FileCommands.isAlias) { AppDelegate.shared.reveal(FileCommands.resolved(url)) }
    }
    func showPackageContents(_ sender: Any?) {
        if let url = selectedURLs.first(where: FileCommands.isPackage) { AppDelegate.shared.openWindow(at: url) }
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { QuickLook.accepts(self) }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.detach(panel, from: self) }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { selectedURLs[index] as NSURL }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool { QuickLook.forward(event, to: self, panel: panel) }
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let window, let url = item?.previewItemURL, let i = items.firstIndex(where: { $0.url.path == url.path }) else { return .zero }
        return window.convertToScreen(convert(DesktopView.aspectFit(image(for: i).size, in: iconRect(i)), to: nil))
    }
}
