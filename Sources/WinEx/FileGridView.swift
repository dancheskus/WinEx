import AppKit

/// Folder view styles, in the same order as Explorer's "View" menu.
enum ViewMode: Int, CaseIterable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles

    var title: String {
        switch self {
        case .extraLargeIcons: "Огромные значки"
        case .largeIcons: "Крупные значки"
        case .mediumIcons: "Обычные значки"
        case .smallIcons: "Мелкие значки"
        case .list: "Список"
        case .details: "Таблица"
        case .tiles: "Плитка"
        }
    }

    var symbol: String {
        switch self {
        case .extraLargeIcons: "square.grid.2x2.fill"
        case .largeIcons: "square.grid.2x2"
        case .mediumIcons: "square.grid.3x3"
        case .smallIcons: "square.grid.4x3.fill"
        case .list: "list.bullet"
        case .details: "list.bullet.rectangle"
        case .tiles: "rectangle.grid.1x2"
        }
    }

    /// Ctrl+wheel order in Explorer: from the densest view to the biggest icons.
    static let zoomOrder: [ViewMode] = [.details, .list, .smallIcons, .mediumIcons, .largeIcons, .extraLargeIcons]

    static var saved: ViewMode {
        get { ViewMode(rawValue: UserDefaults.standard.object(forKey: "viewMode") as? Int ?? -1) ?? .details }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "viewMode") }
    }

    var iconSize: CGFloat {
        switch self {
        case .extraLargeIcons: 192
        case .largeIcons: 96
        case .mediumIcons, .tiles: 48
        case .smallIcons, .list, .details: 16
        }
    }

    var itemSize: NSSize {
        switch self {
        case .extraLargeIcons: NSSize(width: 212, height: 238)
        case .largeIcons: NSSize(width: 122, height: 140)
        case .mediumIcons: NSSize(width: 90, height: 92)
        case .smallIcons: NSSize(width: 220, height: 22)
        case .list: NSSize(width: 240, height: 22)
        case .tiles: NSSize(width: 280, height: 64)
        case .details: .zero
        }
    }

    /// Icon to the left of the text rather than above it.
    var isHorizontalItem: Bool { self == .smallIcons || self == .list || self == .tiles }

    /// "List" fills columns top to bottom and scrolls sideways, like in Explorer.
    var scrollsHorizontally: Bool { self == .list }

    var usesThumbnails: Bool { iconSize >= 96 }
}

/// Turns ⌘+scroll and pinch into zoom steps (Explorer uses Ctrl+wheel).
struct ZoomGesture {
    private var accumulated: CGFloat = 0

    mutating func step(forScroll event: NSEvent) -> Int? {
        accumulated += event.scrollingDeltaY
        return take(threshold: event.hasPreciseScrollingDeltas ? 24 : 1)
    }

    mutating func step(forMagnify event: NSEvent) -> Int? {
        accumulated += event.magnification
        return take(threshold: 0.15)
    }

    private mutating func take(threshold: CGFloat) -> Int? {
        guard abs(accumulated) >= threshold else { return nil }
        defer { accumulated = 0 }
        return accumulated > 0 ? 1 : -1
    }
}

/// Flow layout that packs rows to the left with fixed spacing, like Explorer
/// (the stock layout spreads leftover width between the items).
final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        super.layoutAttributesForElements(in: rect).map(leftAligned)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        super.layoutAttributesForItem(at: indexPath).map(leftAligned)
    }

    private func leftAligned(_ attributes: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        guard scrollDirection == .vertical, attributes.representedElementCategory == .item,
              let indexPath = attributes.indexPath, let width = collectionView?.bounds.width else { return attributes }
        // All items have the same size, so the column follows from the index
        let pitch = itemSize.width + minimumInteritemSpacing
        let available = width - sectionInset.left - sectionInset.right + minimumInteritemSpacing
        let perRow = max(1, Int(available / pitch))
        let copy = attributes.copy() as! NSCollectionViewLayoutAttributes
        copy.frame.origin.x = sectionInset.left + CGFloat(indexPath.item % perRow) * pitch
        return copy
    }
}

// MARK: - Item

final class FileGridItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var mode: ViewMode = .mediumIcons
    private var isFolder = false
    private var originalName = ""
    private var onRename: ((String) -> Void)?
    private var renameCancelled = false

    private var itemView: GridItemView { view as! GridItemView }

    override func loadView() {
        view = GridItemView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        detailField.textColor = .secondaryLabelColor
        detailField.font = .systemFont(ofSize: 11)
        detailField.maximumNumberOfLines = 2
        [iconView, nameField, detailField].forEach(view.addSubview)
        imageView = iconView
        textField = nameField
    }

    override var isSelected: Bool {
        didSet { itemView.isSelected = isSelected }
    }

    func configure(with file: FileItem, mode: ViewMode, image: NSImage) {
        self.mode = mode
        isFolder = file.isFolder
        iconView.image = image
        nameField.stringValue = file.name
        nameField.toolTip = file.name
        if mode.isHorizontalItem {
            nameField.alignment = .left
            nameField.maximumNumberOfLines = 1
            nameField.lineBreakMode = .byTruncatingTail
            nameField.cell?.wraps = false
        } else {
            nameField.alignment = .center
            nameField.maximumNumberOfLines = 2
            nameField.lineBreakMode = .byWordWrapping
            nameField.cell?.wraps = true
            nameField.cell?.truncatesLastVisibleLine = true
        }
        nameField.font = .systemFont(ofSize: mode == .extraLargeIcons ? 13 : 12)
        detailField.isHidden = mode != .tiles
        detailField.stringValue = [file.typeDescription, file.sizeDescription].compactMap { $0 }.joined(separator: "\n")
        view.needsLayout = true
    }

    func setImage(_ image: NSImage) {
        iconView.image = image
    }

    /// Cut files look faded until they are pasted or the cut is cancelled.
    func setCut(_ isCut: Bool) {
        iconView.alphaValue = isCut ? FileListViewController.cutAlpha : 1
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let icon = mode.iconSize
        switch mode {
        case .smallIcons, .list:
            iconView.frame = NSRect(x: 4, y: (bounds.height - icon) / 2, width: icon, height: icon)
            nameField.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: bounds.width - 28, height: 16)
        case .tiles:
            iconView.frame = NSRect(x: 6, y: (bounds.height - icon) / 2, width: icon, height: icon)
            nameField.frame = NSRect(x: 62, y: bounds.height - 24, width: bounds.width - 68, height: 16)
            detailField.frame = NSRect(x: 62, y: 6, width: bounds.width - 68, height: 30)
        default:
            iconView.frame = NSRect(x: (bounds.width - icon) / 2, y: bounds.height - icon - 4, width: icon, height: icon)
            let textHeight = bounds.height - icon - 10
            nameField.frame = NSRect(x: 4, y: 2, width: bounds.width - 8, height: textHeight)
        }
    }

    // MARK: Inline rename

    func beginRename(onCommit: @escaping (String) -> Void) {
        onRename = onCommit
        originalName = nameField.stringValue
        renameCancelled = false
        itemView.isRenaming = true
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.drawsBackground = true
        nameField.backgroundColor = .textBackgroundColor
        nameField.delegate = self
        view.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectedRange = FileOps.baseNameRange(of: originalName, isFolder: isFolder)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameCancelled = true
        nameField.stringValue = originalName
        view.window?.makeFirstResponder(collectionView)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.drawsBackground = false
        itemView.isRenaming = false
        let commit = onRename
        onRename = nil
        if !renameCancelled { commit?(nameField.stringValue) }
        // Return keyboard focus to the grid after Return/Tab
        DispatchQueue.main.async { [weak self] in
            guard let self, let grid = self.collectionView, self.view.window?.firstResponder is NSWindow else { return }
            self.view.window?.makeFirstResponder(grid)
        }
    }
}

/// Item background: Explorer-style highlight of the whole cell.
final class GridItemView: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    var isDropTarget = false { didSet { needsDisplay = true } }
    var isRenaming = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Clicks go to the collection view (it implements selection), except while renaming
        guard !isRenaming else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isDropTarget else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(isDropTarget ? 0.5 : 0.3).setFill()
        path.fill()
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Collection view

/// Icon/list/tile views with Explorer selection rules:
///  - click selects one item and sets the anchor;
///  - ⌘-click (Ctrl on Windows) toggles an item and moves the anchor;
///  - ⇧-click selects the range from the anchor, ⇧⌘-click adds that range;
///  - arrows move, ⇧+arrows extend from the anchor, Home/End jump;
///  - dragging on empty space draws a selection rectangle.
final class FileCollectionView: NSCollectionView {
    var onQuickLook: (() -> Void)?
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    var onSelectionChange: (() -> Void)?
    var itemName: ((Int) -> String)?
    var draggingItems: ((IndexSet) -> [NSDraggingItem])?
    /// Where files dropped at a point go: a folder item (with its index, to highlight) or the current folder.
    var dropTarget: ((NSPoint) -> (url: URL, index: Int?)?)?
    private var highlightedDropIndex: Int? {
        didSet {
            guard highlightedDropIndex != oldValue else { return }
            for index in [oldValue, highlightedDropIndex].compactMap({ $0 }) {
                (item(at: IndexPath(item: index, section: 0))?.view as? GridItemView)?.isDropTarget = index == highlightedDropIndex
            }
        }
    }

    /// Item under the last right click, -1 if none (like NSTableView.clickedRow).
    private(set) var clickedIndex = -1

    private var anchor: Int?
    private var lead: Int?
    private var mouseDownIndex: Int?
    private var mouseDownPoint = NSPoint.zero
    private var dragStarted = false
    private var collapseOnMouseUp: Int?
    private var typeSelectBuffer = ""
    private var typeSelectTime = Date.distantPast
    private var zoom = ZoomGesture()

    var count: Int { numberOfSections > 0 ? numberOfItems(inSection: 0) : 0 }

    var selectedIndexes: IndexSet { IndexSet(selectionIndexPaths.map(\.item)) }

    /// Sets the selection programmatically; the anchor becomes `anchor` (or is cleared).
    func setSelection(_ indexes: IndexSet, anchor newAnchor: Int?) {
        anchor = newAnchor
        lead = newAnchor
        selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        onSelectionChange?()
    }

    func clearClickedIndex() {
        clickedIndex = -1
    }

    func scrollToItem(_ index: Int) {
        guard index >= 0 && index < count else { return }
        scrollToItems(at: [IndexPath(item: index, section: 0)],
                      scrollPosition: isHorizontalFlow ? .nearestVerticalEdge : .nearestHorizontalEdge)
    }

    private var isHorizontalFlow: Bool {
        (collectionViewLayout as? NSCollectionViewFlowLayout)?.scrollDirection == .horizontal
    }

    private func apply(_ selection: IndexSet, lead newLead: Int) {
        lead = newLead
        selectionIndexPaths = Set(selection.map { IndexPath(item: $0, section: 0) })
        onSelectionChange?()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clickedIndex = -1
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .command])

        guard let index = indexPathForItem(at: point)?.item else {
            // Empty space: selection rectangle (⌘/⇧ add to the current selection)
            mouseDownIndex = nil
            let base = modifiers.isEmpty ? IndexSet() : selectedIndexes
            apply(base, lead: lead ?? 0)
            RubberBand.track(in: self, from: point) { rect in
                let hit = (0..<count).filter { i in
                    layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame.intersects(rect) ?? false
                }
                apply(base.union(IndexSet(hit)), lead: hit.last ?? lead ?? 0)
            }
            let selection = selectedIndexes
            anchor = selection.isEmpty ? nil : (anchor ?? selection.first)
            return
        }

        mouseDownIndex = index
        mouseDownPoint = point
        dragStarted = false
        collapseOnMouseUp = nil
        var selection = selectedIndexes

        if modifiers.contains(.shift) {
            let from = anchor ?? lead ?? 0
            anchor = from
            let range = IndexSet(integersIn: min(from, index)...max(from, index))
            apply(modifiers.contains(.command) ? selection.union(range) : range, lead: index)
        } else if modifiers.contains(.command) {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchor = index
            apply(selection, lead: index)
        } else {
            if selection.contains(index) {
                // Keep a multi-selection so it can be dragged; collapse on mouse up otherwise
                if selection.count > 1 { collapseOnMouseUp = index }
            } else {
                selection = [index]
            }
            anchor = index
            apply(selection, lead: index)
            if event.clickCount == 2 { onOpen?() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownIndex != nil, !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        dragStarted = true
        collapseOnMouseUp = nil
        let items = draggingItems?(selectedIndexes) ?? []
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted, let index = collapseOnMouseUp {
            apply([index], lead: index)
        }
        collapseOnMouseUp = nil
        mouseDownIndex = nil
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .delete] : [.copy, .move, .generic]
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dropped on the Trash in the Dock
        if operation == .delete {
            FileOps.trash(session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        }
    }

    // MARK: Drop destination (own handling instead of the stock insertion gaps)

    private func dropDestination(for sender: NSDraggingInfo) -> (url: URL, operation: NSDragOperation)? {
        let point = convert(sender.draggingLocation, from: nil)
        guard let target = dropTarget?(point) else { return nil }
        let operation = FileDrop.operation(for: sender, into: target.url)
        if operation == [], target.index != nil, let fallback = dropTarget?(NSPoint(x: -1, y: -1)) {
            // Can't drop onto that folder (e.g. it is being dragged): use the current folder
            highlightedDropIndex = nil
            return (fallback.url, FileDrop.operation(for: sender, into: fallback.url))
        }
        highlightedDropIndex = operation == [] ? nil : target.index
        return (target.url, operation)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropDestination(for: sender)?.operation ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropDestination(for: sender)?.operation ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlightedDropIndex = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { highlightedDropIndex = nil }
        guard let destination = dropDestination(for: sender), destination.operation != [] else { return false }
        return FileDrop.perform(sender, into: destination.url)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        clickedIndex = indexPathForItem(at: point)?.item ?? -1
        // Like Explorer: right-clicking an unselected item selects it, empty space clears
        if clickedIndex < 0 {
            apply([], lead: lead ?? 0)
        } else if !selectedIndexes.contains(clickedIndex) {
            anchor = clickedIndex
            apply([clickedIndex], lead: clickedIndex)
        }
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        if let step = zoom.step(forScroll: event) { onZoom?(step) }
    }

    override func magnify(with event: NSEvent) {
        if let step = zoom.step(forMagnify: event) { onZoom?(step) }
    }

    override func selectAll(_ sender: Any?) {
        guard count > 0 else { return }
        anchor = 0
        apply(IndexSet(integersIn: 0..<count), lead: count - 1)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if modifiers.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {   // Return, Enter
            onOpen?()
        } else if modifiers.isEmpty && event.keyCode == 51 {                     // Backspace
            onGoUp?()
        } else if modifiers.isEmpty && event.keyCode == 49 && !isTypingName {    // Space
            onQuickLook?()
        } else if modifiers.isSubset(of: [.shift]), let target = navigationTarget(for: event.keyCode) {
            moveFocus(to: target, extend: modifiers.contains(.shift))
        } else if modifiers.isSubset(of: [.shift]), let chars = event.characters, isTypeSelect(chars) {
            typeSelect(chars)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Items per row (vertical flow) or per column (horizontal flow).
    private func itemsPerLine() -> Int {
        let total = count
        guard total > 1, let first = layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame else { return 1 }
        var n = 1
        while n < total, let frame = layoutAttributesForItem(at: IndexPath(item: n, section: 0))?.frame,
              isHorizontalFlow ? abs(frame.minX - first.minX) < 1 : abs(frame.minY - first.minY) < 1 {
            n += 1
        }
        return n
    }

    private func navigationTarget(for keyCode: UInt16) -> Int? {
        let total = count
        guard total > 0 else { return nil }
        let arrows: Set<UInt16> = [123, 124, 125, 126, 115, 119]
        guard arrows.contains(keyCode) else { return nil }
        guard let current = lead ?? selectedIndexes.first else { return 0 }

        let perLine = itemsPerLine()
        let delta: Int
        switch keyCode {
        case 123: delta = isHorizontalFlow ? -perLine : -1   // ←
        case 124: delta = isHorizontalFlow ? perLine : 1     // →
        case 126: delta = isHorizontalFlow ? -1 : -perLine   // ↑
        case 125: delta = isHorizontalFlow ? 1 : perLine     // ↓
        case 115: return 0                                   // Home
        default: return total - 1                            // End
        }
        let target = current + delta
        if target < 0 { return current }
        if target >= total {
            // Moving to a shorter last line lands on the last item
            return abs(delta) > 1 && current / perLine < (total - 1) / perLine ? total - 1 : current
        }
        return target
    }

    private func moveFocus(to target: Int, extend: Bool) {
        if extend {
            let from = anchor ?? lead ?? target
            anchor = from
            apply(IndexSet(integersIn: min(from, target)...max(from, target)), lead: target)
        } else {
            anchor = target
            apply([target], lead: target)
        }
        scrollToItem(target)
    }

    /// A space right after typed letters is part of a name being type-selected, not Quick Look.
    private var isTypingName: Bool {
        !typeSelectBuffer.isEmpty && Date().timeIntervalSince(typeSelectTime) < 1
    }

    private func isTypeSelect(_ chars: String) -> Bool {
        !chars.isEmpty && chars.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    /// Typing jumps to the next item whose name starts with the typed text.
    private func typeSelect(_ chars: String) {
        let now = Date()
        if now.timeIntervalSince(typeSelectTime) > 1 { typeSelectBuffer = "" }
        typeSelectTime = now
        typeSelectBuffer += chars.lowercased()
        let total = count
        guard total > 0, let itemName else { return }
        let start = typeSelectBuffer.count == 1 ? (lead ?? -1) + 1 : (lead ?? 0)
        for offset in 0..<total {
            let i = (start + offset) % total
            if itemName(i).lowercased().hasPrefix(typeSelectBuffer) {
                moveFocus(to: i, extend: false)
                return
            }
        }
    }
}
