import XCTest
@testable import LocalASR

/// Возврат пунктуации после словарного ресорера — без модели и без звука.
final class PunctuationReattachmentTests: XCTestCase {
    private func restore(_ original: String, _ rescored: String) -> String {
        PunctuationReattachment.restore(original: original, rescored: rescored)
    }

    private func markCount(_ text: String) -> Int {
        text.filter { ".,!?:;…«»\"'()—–".contains($0) }.count
    }

    private func cores(_ text: String) -> [String] {
        PunctuationReattachment.fields(text).map(\.core)
    }

    // MARK: - Основное

    func testEqualStringsAreReturnedUnchanged() {
        XCTAssertEqual(restore("Привет, мир.", "Привет, мир."), "Привет, мир.")
    }

    /// Тот самый дефект: замена слова унесла с собой запятую.
    func testCommaComesBackToTheReplacedWord() {
        XCTAssertEqual(
            restore(
                "Данные лежат в постгресе, а кэш отдельно.",
                "Данные лежат в Postgres а кэш отдельно."
            ),
            "Данные лежат в Postgres, а кэш отдельно."
        )
    }

    func testSentenceFinalPeriodIsNotLost() {
        XCTAssertEqual(
            restore("Открой постгрес.", "Открой Postgres"),
            "Открой Postgres."
        )
    }

    /// Свой знак ресорера главнее — иначе получилось бы «Postgres,,».
    func testMarkIsNeverDoubled() {
        XCTAssertEqual(
            restore("Открой постгрес, потом", "Открой Postgres, потом"),
            "Открой Postgres, потом"
        )
    }

    /// Склейка нескольких слов в термин: знак отдаёт только последнее из них,
    /// и внутрь термина пунктуация не попадает.
    func testMergingTwoWordsKeepsOnlyTheTrailingMark() {
        let result = restore("Сделай пул реквест, потом", "Сделай pull-request потом")
        XCTAssertEqual(result, "Сделай pull-request, потом")
        XCTAssertFalse(result.contains("pull,"), "внутрь термина знак не заезжает")
    }

    /// Разрыв слова на несколько: знак садится в конец, а не внутрь.
    func testSplittingAWordDoesNotScatterMarksInside() {
        let result = restore("Открой постгрес.", "Открой Post gres")
        XCTAssertFalse(result.contains("Post. gres"))
        XCTAssertTrue(result.hasSuffix("."), "точка осталась в конце")
    }

    // MARK: - Что нельзя трогать

    /// Знаки внутри слова не снимаются — их снимают только с краёв.
    func testPunctuationInsideAWordIsNeverTouched() {
        let samples = [
            "Число 3.14 точное",
            "И т.д. дальше",
            "Ссылка https://wai.computer сюда",
            "I don't know",
            "Пишем тайп-скрипт сейчас",
        ]
        for text in samples {
            XCTAssertEqual(restore(text, text), text, "не должно измениться: \(text)")
        }
    }

    /// Тексты разошлись слишком сильно — возвращаем как есть.
    ///
    /// Это не тихая деградация, а сегодняшнее поведение: выдумывать пунктуацию
    /// хуже, чем её потерять.
    func testTooDifferentTextsAreLeftAlone() {
        let rescored = "совершенно другой набор слов без единого совпадения"
        XCTAssertEqual(restore("Привет, как дела? Хорошо.", rescored), rescored)
    }

    func testNewlinesAndSpacingSurvive() {
        let original = "Первая строка,\nвторая строка."
        let rescored = "Первая строка\nвторая строка"
        let result = restore(original, rescored)
        XCTAssertTrue(result.contains("\n"), "перевод строки на месте")
        XCTAssertEqual(result, "Первая строка,\nвторая строка.")
    }

    func testEmptyStrings() {
        XCTAssertEqual(restore("", ""), "")
        XCTAssertEqual(restore("Привет.", ""), "")
        XCTAssertEqual(restore("", "Привет"), "Привет")
    }

    // MARK: - Инварианты

    private let corpus: [(String, String)] = [
        ("Данные лежат в постгресе, а кэш отдельно.", "Данные лежат в Postgres а кэш отдельно."),
        ("Открой постгрес.", "Открой Postgres"),
        ("Сделай пул реквест, потом деплой!", "Сделай pull-request потом deploy"),
        ("Число 3.14, и т.д.", "Число 3.14 и т.д."),
        ("Первая строка,\nвторая строка.", "Первая строка\nвторая строка"),
        ("Привет, как дела?", "Привет как дела"),
    ]

    /// Инвариант 3, самый важный: слова не меняются никогда.
    ///
    /// Иначе возврат пунктуации отменил бы словарную правку — ровно то, ради
    /// чего ресорер и работает.
    func testWordsAreNeverChanged() {
        for (original, rescored) in corpus {
            XCTAssertEqual(
                cores(restore(original, rescored)),
                cores(rescored),
                "слова обязаны остаться словами ресорера"
            )
        }
    }

    /// Инвариант 1: знак, который дал ресорер, не удаляется.
    func testMarksProducedByTheRescorerAreNeverRemoved() {
        for (original, rescored) in corpus {
            let result = restore(original, rescored)
            XCTAssertGreaterThanOrEqual(
                markCount(result), markCount(rescored),
                "нельзя потерять то, что ресорер уже написал"
            )
        }
    }

    /// Инвариант 2: новых знаков не появляется.
    func testNoMarkIsEverInvented() {
        for (original, rescored) in corpus {
            let result = restore(original, rescored)
            XCTAssertLessThanOrEqual(
                markCount(result), max(markCount(original), markCount(rescored)),
                "знаки берутся только из объединения сторон"
            )
        }
    }

    /// Ради чего всё: на корпусе знаки перестают пропадать.
    func testMarkCountRecoversTowardTheOriginal() {
        for (original, rescored) in corpus where markCount(original) > markCount(rescored) {
            let result = restore(original, rescored)
            XCTAssertGreaterThan(
                markCount(result), markCount(rescored),
                "восстановление обязано что-то вернуть: \(original)"
            )
        }
    }
}
