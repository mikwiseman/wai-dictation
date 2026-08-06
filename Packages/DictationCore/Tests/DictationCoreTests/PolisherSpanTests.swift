import XCTest
@testable import DictationCore

/// Полишер и защищённые спаны.
///
/// Здесь же живёт фикс дефекта, ради которого модель спанов и появилась.
final class PolisherSpanTests: XCTestCase {
    /// Тот самый дефект: пробел после точки перед заглавной разваливал имена.
    func testDoesNotSplitADottedIdentifier() {
        XCTAssertEqual(
            TranscriptPolisher.polish("открой TextPipeline.Output"),
            "Открой TextPipeline.Output"
        )
        XCTAssertEqual(
            TranscriptPolisher.polish("зови AppState.shared"),
            "Зови AppState.shared"
        )
        XCTAssertEqual(TranscriptPolisher.polish("правь Foo.Bar"), "Правь Foo.Bar")
    }

    /// Настоящая граница предложения по-прежнему разбивается.
    ///
    /// Правило про идентификаторы только про ASCII, поэтому русский текст его
    /// не касается вовсе.
    func testStillSplitsARealSentenceBoundary() {
        XCTAssertEqual(
            TranscriptPolisher.polish("Готово.Дальше поедем"),
            "Готово. Дальше поедем"
        )
        XCTAssertEqual(
            TranscriptPolisher.polish("Готово.Пойдём дальше"),
            "Готово. Пойдём дальше"
        )
    }

    /// Гвардия по заглавной осталась на месте: числа, версии, домены и
    /// сокращения спанами не становятся и держатся именно на ней.
    func testConservativeDotAndColonRulesAreUnchangedThroughSpans() {
        let untouched = [
            "Testing numbers like 3.14 and dates like January 5.",
            "Версия 2.0.1 вышла",
            "Смотри на wai.computer",
            "Это т.д. и т.п.",
            "Встреча в 12:30",
        ]
        for input in untouched {
            XCTAssertEqual(TranscriptPolisher.polish(input), input, "не должно измениться: \(input)")
        }
    }

    func testPolisherNeverEditsInsideBackticks() {
        XCTAssertEqual(
            TranscriptPolisher.polish("запусти `swift  test` сейчас"),
            "Запусти `swift  test` сейчас"
        )
        XCTAssertEqual(
            TranscriptPolisher.polish("напиши `a , b` вот так"),
            "Напиши `a , b` вот так"
        )
    }

    func testPathsAndFlagsSurvivePolishing() {
        XCTAssertEqual(
            TranscriptPolisher.polish("открой /etc/hosts и добавь --dry-run"),
            "Открой /etc/hosts и добавь --dry-run"
        )
    }

    /// Идентификатор первым словом не получает заглавную: это имя, а не начало
    /// предложения. `OnTextInserted` — уже другое имя.
    func testIdentifierAtTheStartKeepsItsCase() {
        XCTAssertEqual(
            TranscriptPolisher.polish("onTextInserted сработал"),
            "onTextInserted сработал"
        )
        XCTAssertEqual(TranscriptPolisher.polish("привет"), "Привет", "обычное слово — как раньше")
    }

    /// Схлопывание пробелов не лезет внутрь спана, но лишний пробел рядом убирает.
    func testWhitespaceCollapseStopsAtTheSpanBoundary() {
        XCTAssertEqual(
            TranscriptPolisher.polish("до   `a  b`   после"),
            "До `a  b` после"
        )
    }
}
