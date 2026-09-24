import AppKit
import Quartz

/// Space-bar Quick Look. The panel asks the responder chain for a controller
/// (`acceptsPreviewPanelControl`); the file list and the desktop implement it.
@MainActor
enum QuickLook {
    private static var panel: QLPreviewPanel? {
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
    }

    /// Shows or hides the panel for `controller`'s selection. The controller is attached explicitly:
    /// the panel's own responder-chain lookup can pick another window (the desktop window never
    /// becomes main, so an explorer window would win).
    static func toggle(for controller: QLPreviewPanelDataSource & QLPreviewPanelDelegate) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && panel.dataSource === controller {
            panel.orderOut(nil)
            return
        }
        owner = controller
        panel.dataSource = controller
        panel.delegate = controller
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    /// The view that pressed Space last. Only it accepts panel control, so the panel's own
    /// responder-chain lookup can't hand the panel to some other window.
    private(set) static weak var owner: AnyObject?

    static func accepts(_ controller: AnyObject) -> Bool {
        owner === controller
    }

    /// `endPreviewPanelControl` helper: detach only if the panel still belongs to `controller`.
    static func detach(_ panel: QLPreviewPanel, from controller: AnyObject) {
        guard panel.dataSource === controller else { return }
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// Keeps the panel in sync when `controller`'s selection changes.
    static func selectionChanged(in controller: AnyObject) {
        guard let panel, panel.isVisible, panel.dataSource === controller else { return }
        panel.reloadData()
    }

    /// Arrow keys (and Space to close) pressed while the panel is key go back to the file view.
    static func forward(_ event: NSEvent, to view: NSView, panel: QLPreviewPanel) -> Bool {
        guard event.type == .keyDown else { return false }
        view.keyDown(with: event)
        panel.reloadData()
        return true
    }
}
