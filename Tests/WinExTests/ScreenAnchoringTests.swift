import CoreGraphics
import Testing
@testable import WinEx

/// Moving a desktop arrangement between monitors of different sizes (laptop ↔ external monitor).
@Suite struct ScreenAnchoringTests {
    // The laptop (1710 × 1107 pt) as set up: a row of icons at the top in the middle, three zones
    // in a column at the right edge, a lone icon at the bottom left.
    let laptop = CGSize(width: 1710, height: 1107)
    let external = CGSize(width: 2560, height: 1440)
    let row = (0..<6).map { CGRect(x: 510 + CGFloat($0) * 120, y: 50, width: 120, height: 114) }
    let zones = [CGRect(x: 1262, y: 42, width: 440, height: 278),
                 CGRect(x: 1262, y: 342, width: 440, height: 170),
                 CGRect(x: 1262, y: 532, width: 440, height: 170)]
    let corner = CGRect(x: 20, y: 960, width: 120, height: 114)

    func moved(_ rects: [CGRect], from: CGSize, to: CGSize) -> [CGRect] {
        let offsets = ScreenAnchoring.offsets(for: rects, from: from, to: to)
        return zip(rects, offsets).map { $0.offsetBy(dx: $1.dx, dy: $1.dy) }
    }

    @Test func zonesAtTheRightEdgeStayAtTheRightEdge() {
        let result = moved(row + zones + [corner], from: laptop, to: external)
        for (before, after) in zip(zones, result[6..<9]) {
            #expect(abs((external.width - after.maxX) - (laptop.width - before.maxX)) < 0.5)  // same gap to the right edge
            #expect(after.minY == before.minY)                                                  // same gap to the top
            #expect(after.size == before.size)                                                  // not resized
        }
    }

    @Test func aRowInTheMiddleMovesAsOneAndStaysCentred() {
        let result = Array(moved(row + zones + [corner], from: laptop, to: external)[0..<6])
        // Still a row with the same spacing
        for (a, b) in zip(result, result.dropFirst()) { #expect(b.minX - a.maxX == 0) }
        // Its middle at the same fraction of the width, at the same distance from the top
        let before = row.reduce(CGRect.null) { $0.union($1) }, after = result.reduce(CGRect.null) { $0.union($1) }
        #expect(abs(after.midX / external.width - before.midX / laptop.width) < 0.001)
        #expect(after.minY == before.minY)
    }

    @Test func aCornerIconKeepsItsCorner() {
        let after = moved(row + zones + [corner], from: laptop, to: external)[9]
        #expect(after.minX == corner.minX)
        #expect(abs((external.height - after.maxY) - (laptop.height - corner.maxY)) < 0.5)
    }

    @Test func backToTheLaptopItIsAsItWas() {
        let there = moved(row + zones + [corner], from: laptop, to: external)
        let back = moved(there, from: external, to: laptop)
        for (original, returned) in zip(row + zones + [corner], back) {
            #expect(abs(original.minX - returned.minX) < 0.5 && abs(original.minY - returned.minY) < 0.5)
        }
    }

    @Test func nothingMovesOnTheSameSize() {
        #expect(ScreenAnchoring.offsets(for: zones, from: laptop, to: laptop).allSatisfy { $0 == .zero })
    }

    @Test func keptInsideASmallerMonitor() {
        let wide = CGRect(x: 1800, y: 900, width: 700, height: 400)
        let after = ScreenAnchoring.anchor(wide, from: external, to: laptop)
        #expect(after.maxX <= laptop.width && after.maxY <= laptop.height && after.minX >= 0 && after.minY >= 0)
    }
}
