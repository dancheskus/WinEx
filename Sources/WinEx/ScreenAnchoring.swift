import Foundation
import CoreGraphics

/// Moves a desktop arrangement to a monitor of another size (another monitor, or the same one at
/// another resolution) so it looks the way it was set up: things that sit together move together,
/// a group near an edge or a corner keeps its distance to that edge, one in the middle keeps its
/// place relative to the centre. Nothing is resized.
enum ScreenAnchoring {
    /// How far each rect moves (icons' cells and zones, in points from the monitor's top-left),
    /// going from a monitor of size `from` to one of size `to`. Rects closer than `gap` form a group.
    static func offsets(for rects: [CGRect], from: CGSize, to: CGSize, gap: CGFloat = 24) -> [CGVector] {
        guard from.width > 0, from.height > 0, from != to else { return rects.map { _ in .zero } }
        var offsets = rects.map { _ in CGVector.zero }
        for group in groups(rects, gap: gap) {
            let box = group.map { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
            let moved = anchor(box, from: from, to: to)
            let shift = CGVector(dx: moved.minX - box.minX, dy: moved.minY - box.minY)
            for index in group { offsets[index] = shift }
        }
        return offsets
    }

    /// Where `rect` goes on the new monitor. On each axis the monitor is three bands: close to an
    /// edge (within a fifth of the monitor) it keeps its distance to the nearer edge; otherwise its
    /// middle decides — in the first third it keeps its distance to that edge, in the last third
    /// to the far edge, in the middle third its middle stays at the same fraction of the monitor.
    /// Kept inside the monitor.
    static func anchor(_ rect: CGRect, from: CGSize, to: CGSize) -> CGRect {
        func axis(_ start: CGFloat, _ length: CGFloat, _ old: CGFloat, _ new: CGFloat) -> CGFloat {
            let lead = start, trail = old - (start + length), middle = start + length / 2
            let placed: CGFloat
            if min(lead, trail) <= old / 5 {
                placed = lead <= trail ? start : new - trail - length
            } else if middle < old / 3 {
                placed = start
            } else if middle > old * 2 / 3 {
                placed = new - trail - length
            } else {
                placed = middle / old * new - length / 2
            }
            return min(max(placed, 0), max(new - length, 0))
        }
        return CGRect(x: axis(rect.minX, rect.width, from.width, to.width),
                      y: axis(rect.minY, rect.height, from.height, to.height),
                      width: rect.width, height: rect.height)
    }

    /// Indices of rects that touch (within `gap`), directly or through others.
    static func groups(_ rects: [CGRect], gap: CGFloat) -> [[Int]] {
        var parent = Array(rects.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for a in rects.indices {
            for b in rects.indices where b > a && rects[a].insetBy(dx: -gap / 2, dy: -gap / 2).intersects(rects[b].insetBy(dx: -gap / 2, dy: -gap / 2)) {
                parent[root(a)] = root(b)
            }
        }
        return Dictionary(grouping: rects.indices, by: root).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}

/// What macOS remembers about monitors, connected or not (WindowServer's display sets): the size
/// (in points, "looks like") a monitor had, for one WinEx never saw — like a laptop's own screen
/// while it's closed on external monitors.
enum SystemDisplays {
    private static let path = "/Library/Preferences/com.apple.windowserver.displays.plist"
    nonisolated(unsafe) private static var cache: (modified: Date, sizes: [String: CGSize])?

    /// Every monitor macOS remembers, with its size.
    static var known: [String: CGSize] {
        _ = size(of: "")
        return cache?.sizes ?? [:]
    }

    /// The last size macOS has for the monitor with this display UUID.
    static func size(of uuid: String) -> CGSize? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if cache?.modified != modified {
            let plist = NSDictionary(contentsOfFile: path) as? [String: Any] ?? [:]
            cache = (modified, sizes(in: plist))
        }
        return cache?.sizes[uuid.uppercased()]
    }

    /// From the plist: each display's size in the set where it was alone (where it was used by
    /// itself), else in the first set it's in.
    static func sizes(in plist: [String: Any]) -> [String: CGSize] {
        var alone: [String: CGSize] = [:], any: [String: CGSize] = [:]
        for key in ["DisplayAnyUserSets", "DisplaySets"] {
            let configs = (plist[key] as? [String: Any])?["Configs"] as? [Any] ?? []
            for config in configs {
                let displays = (config as? [[String: Any]]) ?? ((config as? [String: Any])?["DisplayConfig"] as? [[String: Any]]) ?? []
                for display in displays {
                    guard let uuid = (display["UUID"] as? String)?.uppercased(),
                          let info = display["CurrentInfo"] as? [String: Any],
                          let wide = (info["Wide"] as? NSNumber)?.doubleValue, let high = (info["High"] as? NSNumber)?.doubleValue,
                          wide > 0, high > 0 else { continue }
                    let size = CGSize(width: wide, height: high)
                    if displays.count == 1, alone[uuid] == nil { alone[uuid] = size }
                    if any[uuid] == nil { any[uuid] = size }
                }
            }
        }
        return any.merging(alone) { _, alone in alone }
    }
}
