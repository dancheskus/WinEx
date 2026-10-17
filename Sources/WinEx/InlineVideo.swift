import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Videos and audio in icon views, as in Finder: the length under the name, and on hover a play
/// button over the preview — a click plays it right there, another pauses it.
enum InlineVideo {
    /// Videos and audio files: both play in place (a sound just over its icon, the ring showing how far).
    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
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
    /// How much has played (0…1), shown as a ring around the button; `nil` before it starts.
    var progress: Double? { didSet { if progress != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks are handled by the grid

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        // Finder's: a light, see-through disc
        NSColor(white: 0.55, alpha: 0.6).setFill()
        NSBezierPath(ovalIn: circle).fill()
        if let progress {
            // The ring: a faint track and the part played, clockwise from the top
            let lineWidth = max(2, (bounds.width * 0.07).rounded())
            let ring = circle.insetBy(dx: lineWidth / 2 + 1, dy: lineWidth / 2 + 1)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = lineWidth
            NSColor.white.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(min(max(progress, 0), 1)), clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.white.setStroke()
            arc.stroke()
        }
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
    /// A sound (nothing to see): its button stays, faint, while it plays.
    let isAudio: Bool
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private let onEnd: () -> Void
    /// One thing plays at a time: starting another stops this one.
    private static weak var current: InlineVideoView?

    init(url: URL, onProgress: @escaping (Double) -> Void, onEnd: @escaping () -> Void) {
        player = AVPlayer(url: url)
        isAudio = UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
        self.onEnd = onEnd
        super.init(frame: .zero)
        wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        // Fills the preview's own shape, with its rounded corners
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
        layer?.masksToBounds = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak player] time in
            MainActor.assumeIsolated {
                guard let duration = player?.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else { return }
                onProgress(time.seconds / duration.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem,
                                                             queue: .main) { _ in MainActor.assumeIsolated { onEnd() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = max(3, (min(bounds.width, bounds.height) * 0.06).rounded())
    }

    /// Plays (on), stopping whatever else was playing in place.
    func play() {
        if let other = Self.current, other !== self { other.onEnd() }
        Self.current = self
        player.play()
    }

    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        removeFromSuperview()
    }
}

/// Finder's «Показывать сведения об объекте»: a line under the name in icon views — how many items
/// a folder holds, a picture's size in pixels, how long a video or a sound is, how big an archive
/// or a disk image is (as Finder: other files get no line).
enum ItemInfo {
    nonisolated(unsafe) private static var known: [String: String] = [:]
    private static let lock = NSLock()

    /// The line for `file`, or nil (nothing to say, or not known yet — then `ready` brings it).
    static func text(for file: FileItem, ready: @escaping @MainActor (String) -> Void) -> String? {
        let url = file.url
        if !file.isFolder, InlineVideo.isVideo(url) { return InlineVideo.duration(of: url, ready: ready) }
        if !file.isFolder, UTType(filenameExtension: url.pathExtension)?.conforms(to: .archive) == true { return file.sizeDescription }
        let isImage = !file.isFolder && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        guard file.isFolder || isImage else { return nil }
        // (A folder's count changes with what's in it: its date changes then too)
        let key = url.path + "|" + String(file.modified?.timeIntervalSince1970 ?? 0)
        lock.lock()
        let cached = known[key]
        if cached == nil { known[key] = "" }   // asked once
        lock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }
        Task.detached(priority: .utility) {
            let text: String?
            if isImage {
                text = pixelSize(of: url)
            } else {
                let count = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.count
                text = count.map { "\($0.formatted()) " + plural($0, L("объект"), L("объекта"), L("объектов")) }
            }
            guard let text else { return }
            lock.lock()
            known[key] = text
            lock.unlock()
            await MainActor.run { ready(text) }
        }
        return nil
    }

    /// "1920 × 1080" (read from the file's header, without loading the picture).
    private static func pixelSize(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }
}
