import XCTest
@testable import DictationCore

/// Свёртка типографики: привести написание к тому, что человек набрал бы руками.
///
/// Стадия узкая по замыслу. Она чинит символы, которые в диктовке могут быть
/// только следом чужой правки или невидимым мусором, и не трогает ничего, что
/// несёт смысл.
final class TypographyFoldTests: XCTestCase {
    func testTableHasExactlyTwelveEntries() {
        XCTAssertEqual(TypographyFold.table.count, 12)
    }

    /// Невидимые символы: часть становится обычным пробелом, часть исчезает.
    ///
    /// Приезжают они из `written` в словаре — человек вставляет термин копипастом
    /// вместе с неразрывным пробелом или BOM, а в настройках их не видно вовсе.
    func testInvisibleCharactersDisappear() {
        XCTAssertEqual(TypographyFold.fold("два\u{00A0}слова"), "два слова")
        XCTAssertEqual(TypographyFold.fold("два\u{202F}слова"), "два слова")
        XCTAssertEqual(TypographyFold.fold("два\u{2009}слова"), "два слова")
        XCTAssertEqual(TypographyFold.fold("сло\u{200B}во"), "слово")
        XCTAssertEqual(TypographyFold.fold("\u{FEFF}слово"), "слово")
        XCTAssertEqual(TypographyFold.fold("сло\u{00AD}во"), "слово")
    }

    func testCurlyQuotesBecomeStraight() {
        XCTAssertEqual(TypographyFold.fold("\u{2018}одинарные\u{2019}"), "'одинарные'")
        XCTAssertEqual(TypographyFold.fold("\u{201C}двойные\u{201D}"), "\"двойные\"")
    }

    /// Минус — не дефис, и на этом ломается распознавание флага.
    func testMinusSignBecomesAHyphenSoFlagsStayFlags() {
        let folded = TypographyFold.fold("ключ \u{2212}x поставь")
        XCTAssertEqual(folded, "ключ -x поставь")
        XCTAssertEqual(ProtectedSpanDetector.detect(in: folded).map(\.kind), [.flag])
    }

    func testHorizontalBarBecomesEmDash() {
        XCTAssertEqual(TypographyFold.fold("Москва \u{2015} столица"), "Москва — столица")
    }

    /// Ёлочки — правильная русская типографика, а не мусор. Это текст человека.
    ///
    /// Тире тоже несёт смысл: сворачивать его в дефис нельзя, иначе «Москва —
    /// столица» превратится в «Москва -столица», а заодно появятся пары дефисов,
    /// которые детектор спанов примет за флаг.
    func testGuillemetsAndDashesAreNeverFolded() {
        let text = "«Москва — столица», а Питер – нет"
        XCTAssertEqual(TypographyFold.fold(text), text)
    }

    /// Многоточием владеет полишер: у него `…` есть в обоих наборах знаков,
    /// и свёртка в три точки увела бы его в консервативное правило точки.
    func testEllipsisIsNeverFoldedBecauseThePolisherOwnsIt() {
        XCTAssertEqual(TypographyFold.fold("Ну\u{2026} ладно"), "Ну\u{2026} ладно")
    }

    func testOrdinaryTextIsUntouched() {
        let text = "Привет, как дела? Всё хорошо: 3.14 и т.д."
        XCTAssertEqual(TypographyFold.fold(text), text)
    }

    func testEmptyText() {
        XCTAssertEqual(TypographyFold.fold(""), "")
    }

    // MARK: - Спаны

    /// Внутри бэктиков лежит код: кавычка там значащая, и менять её нельзя.
    func testFoldSkipsProtectedSpans() {
        let text = "напиши `let s = \u{201C}hi\u{201D}` и \u{201C}цитату\u{201D}"
        let spans = ProtectedSpanDetector.detect(in: text)
        let folded = TypographyFold.fold(text, protecting: spans)

        XCTAssertTrue(folded.contains("`let s = \u{201C}hi\u{201D}`"), "код не тронут")
        XCTAssertTrue(folded.contains("\"цитату\""), "а обычный текст свёрнут")
    }

    /// Без спанов свёртка идёт по всему тексту — это тот же путь, что и раньше.
    func testEmptySpanSetFoldsEverything() {
        let text = "\u{201C}раз\u{201D} и \u{201C}два\u{201D}"
        XCTAssertEqual(TypographyFold.fold(text, protecting: []), TypographyFold.fold(text))
    }

    /// Свёртка не двигает границы спанов: длина защищённых кусков сохраняется.
    func testFoldKeepsSpansIntact() {
        let text = "правь TextPipeline.Output\u{00A0}сейчас"
        let spans = ProtectedSpanDetector.detect(in: text)
        let folded = TypographyFold.fold(text, protecting: spans)
        XCTAssertEqual(
            ProtectedSpanDetector.detect(in: folded).map(\.text),
            spans.map(\.text)
        )
    }
}
