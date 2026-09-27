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

    @Test func aRowNearerTheRightKeepsNextToTheZones() {
        // The row is a little nearer the right edge (480 pt) than the left (510 pt): it keeps to the
        // right, so it stays next to the zones with the same gap, as on the laptop
        let result = moved(row + zones + [corner], from: laptop, to: external)
        let movedRow = Array(result[0..<6])
        for (a, b) in zip(movedRow, movedRow.dropFirst()) { #expect(b.minX - a.maxX == 0) }  // still one row
        let gapBefore = zones[0].minX - row[5].maxX, gapAfter = result[6].minX - movedRow[5].maxX
        #expect(abs(gapAfter - gapBefore) < 0.5)
        #expect(movedRow[0].minY == row[0].minY)
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

    @Test func aGroupInTheRightHalfKeepsToTheRight() {
        // At 70 % of the width, 250 pt from the right edge — not at the edge, but on the right
        let icon = CGRect(x: laptop.width - 250 - 120, y: 500, width: 120, height: 114)
        let after = ScreenAnchoring.anchor(icon, from: laptop, to: external)
        #expect(abs((external.width - after.maxX) - 250) < 0.5)
        let left = CGRect(x: 380, y: 500, width: 120, height: 114)  // in the left half
        #expect(ScreenAnchoring.anchor(left, from: laptop, to: external).minX == 380)
    }

    @Test func toASmallerMonitorNothingOverlaps() {
        // Set up on the big monitor: the row in the middle, the zones at the right edge
        let bigRow = (0..<6).map { CGRect(x: 920 + CGFloat($0) * 120, y: 50, width: 120, height: 114) }
        let bigZones = zones.map { $0.offsetBy(dx: external.width - laptop.width, dy: 0) }
        let result = moved(bigRow + bigZones, from: external, to: laptop)
        let row = result[0..<6].reduce(CGRect.null) { $0.union($1) }
        for zone in result[6...] {
            #expect(!zone.intersects(row))
            #expect(zone.maxX <= laptop.width)
        }
    }

    @Test func keptInsideASmallerMonitor() {
        let wide = CGRect(x: 1800, y: 900, width: 700, height: 400)
        let after = ScreenAnchoring.anchor(wide, from: external, to: laptop)
        #expect(after.maxX <= laptop.width && after.maxY <= laptop.height && after.minX >= 0 && after.minY >= 0)
    }
}

/// Sizes of monitors macOS remembers (WindowServer's display sets).
@Suite struct SystemDisplaysTests {
    func display(_ uuid: String, _ wide: Int, _ high: Int) -> [String: Any] {
        ["UUID": uuid, "CurrentInfo": ["Wide": wide, "High": high, "Scale": 2]]
    }

    @Test func aDisplayAloneWinsOverOneInASet() {
        let plist: [String: Any] = ["DisplayAnyUserSets": ["Configs": [
            [display("ext-a", 2560, 1440), display("laptop", 1512, 982)],   // with a monitor: another mode
            [display("laptop", 1710, 1107)],                                  // on its own
        ]]]
        let sizes = SystemDisplays.sizes(in: plist)
        #expect(sizes["LAPTOP"] == CGSize(width: 1710, height: 1107))
        #expect(sizes["EXT-A"] == CGSize(width: 2560, height: 1440))
    }

    @Test func nothingForAnUnknownOrBrokenFile() {
        #expect(SystemDisplays.sizes(in: [:]).isEmpty)
        #expect(SystemDisplays.sizes(in: ["DisplayAnyUserSets": ["Configs": [[["UUID": "x"]]]]]).isEmpty)
    }
}
