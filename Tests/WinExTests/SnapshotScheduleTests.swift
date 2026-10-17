import Foundation
import Testing
@testable import WinEx

/// When an automatic desktop snapshot is due.
@Suite struct SnapshotScheduleTests {
    let calendar = Calendar(identifier: .gregorian)
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    @Test func dailyIsOnceACalendarDayNotEveryTwentyFourHours() {
        // Taken late in the evening: due again the next morning, not only the next evening
        #expect(DesktopSnapshots.isDue(last: date(9, 23, 10), now: date(10, 9, 30), hours: 24, calendar: calendar))
        #expect(!DesktopSnapshots.isDue(last: date(10, 9, 30), now: date(10, 23, 50), hours: 24, calendar: calendar))
    }

    @Test func weeklyAndHourly() {
        #expect(!DesktopSnapshots.isDue(last: date(1, 20), now: date(7, 23), hours: 168, calendar: calendar))
        #expect(DesktopSnapshots.isDue(last: date(1, 20), now: date(8, 8), hours: 168, calendar: calendar))
        #expect(DesktopSnapshots.isDue(last: date(10, 9), now: date(10, 15), hours: 6, calendar: calendar))
        #expect(!DesktopSnapshots.isDue(last: date(10, 9), now: date(10, 14, 59), hours: 6, calendar: calendar))
    }
}
