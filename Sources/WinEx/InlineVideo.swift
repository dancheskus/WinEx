import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Videos in icon views, as in Finder: the length under the name, and on hover a play button over
/// the preview — a click plays the video right there, another pauses it.
enum InlineVideo {
    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    nonisolated(unsafe) private static var durations: [String: String] = [:]
    private static let lock = NSLock()

    /// "00:18" (or "1:02:03"); `nil` until known — `ready` is called on the main thread once it is.
    static func duration(of url: URL, ready: @escaping @MainActor (String) -> Void) -> String? {
        let key = url.path
        lock.lock()
        let known = durations[key]
        lock.unlock()
        if let known { return known.isEmpty ? nil : known }
        lock.lock()
        durations[key] = ""   // asked once
        lock.unlock()
        Task.detached(priority: .utility) {
            guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return }
            let seconds = Int(time.seconds.rounded())
            let text = seconds >= 3600
                ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%02d:%02d", seconds / 60, seconds % 60)
            lock.lock()
            durations[key] = text
            lock.unlock()
            await MainActor.run { ready(text) }
        }
        return nil
    }
}

/// Finder's round play / pause button over a video's preview.
final class VideoPlayButton: NSView {
    var isPlaying = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks are handled by the grid

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let symbol = NSImage(systemSymbolName: isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: bounds.height * 0.36, weight: .bold))
        guard let symbol else { return }
        let white = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r); NSColor.white.setFill(); r.fill(using: .sourceIn); return true
        }
        var rect = DesktopView.aspectFit(white.size, in: circle.insetBy(dx: circle.width * 0.3, dy: circle.height * 0.3))
        if !isPlaying { rect.origin.x += circle.width * 0.03 }   // the triangle looks centred a touch to the right
        white.draw(in: rect)
    }
}

/// The playing video, in place of the preview.
final class InlineVideoView: NSView {
    let player: AVPlayer
    private var endObserver: NSObjectProtocol?

    init(url: URL, onEnd: @escaping () -> Void) {
        player = AVPlayer(url: url)
        super.init(frame: .zero)
        wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem,
                                                             queue: .main) { _ in MainActor.assumeIsolated { onEnd() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stop() {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        removeFromSuperview()
    }
}
