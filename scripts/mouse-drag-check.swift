// Drives the real mouse for the "mousedrag" scenario. Run only with the user's consent:
//   scripts/mouse-drag-check.sh
// Waits for <out>/grab.txt ("grabX grabY targetX targetY", global top-left coordinates), drags the
// window's title bar there, writes <out>/dragged; waits for <out>/close.txt ("x y"), clicks it,
// writes <out>/closed. Stops if <out>/abort appears.
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
func waitFor(_ name: String) -> [Double]? {
    for _ in 0..<300 {
        if FileManager.default.fileExists(atPath: out.appendingPathComponent("abort").path) { return nil }
        if let text = try? String(contentsOf: out.appendingPathComponent(name), encoding: .utf8) {
            return text.split(separator: " ").compactMap { Double($0) }
        }
        usleep(100_000)
    }
    return nil
}
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func touch(_ name: String) { FileManager.default.createFile(atPath: out.appendingPathComponent(name).path, contents: nil) }

guard let g = waitFor("grab.txt"), g.count == 4 else { print("no grab point / aborted"); exit(1) }
let from = CGPoint(x: g[0], y: g[1]), to = CGPoint(x: g[2], y: g[3])
post(.mouseMoved, from); usleep(200_000)
post(.leftMouseDown, from); usleep(150_000)
let steps = 40
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    usleep(15_000)
}
usleep(150_000)
post(.leftMouseUp, to); usleep(300_000)
touch("dragged")

guard let c = waitFor("close.txt"), c.count == 2 else { print("no close point / aborted"); exit(1) }
let close = CGPoint(x: c[0], y: c[1])
post(.mouseMoved, close); usleep(250_000)
post(.leftMouseDown, close); usleep(80_000)
post(.leftMouseUp, close); usleep(300_000)
touch("closed")
print("mouse: dragged \(from) → \(to), clicked close at \(close)")
