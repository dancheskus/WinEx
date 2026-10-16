import Testing
@testable import WinEx

/// File names in menu items keep the menu's width.
@Suite struct MenuNameTests {
    @Test func aShortNameStaysAsItIs() {
        #expect(menuName("Отчёт.docx") == "Отчёт.docx")
    }

    @Test func aLongNameLosesItsMiddle() {
        let name = menuName("Инструкция_Пассажирская_таможенная_декларация_в_виде_документа_на.docx")
        #expect(name.count == 30)
        #expect(name.hasPrefix("Инструкция_"))
        #expect(name.hasSuffix(".docx"))
        #expect(name.contains("…"))
    }
}
