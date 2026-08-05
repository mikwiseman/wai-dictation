import XCTest
@testable import DictationCore

/// Выделение правки вставленного фрагмента из содержимого чужого поля.
///
/// Мы знаем три вещи: каким поле было сразу после вставки, где в нём наш
/// фрагмент и каким поле стало потом. Общие префикс и суффикс отрезаются;
/// если изменившаяся середина лежит внутри нашего фрагмента — это правка
/// диктовки, и её можно учить.
final class InsertedEditExtractorTests: XCTestCase {
    func testПравкаВнутриВставленногоФрагментаИзвлекается() {
        let edit = InsertedEditExtractor.extract(
            baseline: "Привет! Открой поуст герз и проверь. Пока.",
            current: "Привет! Открой Postgres и проверь. Пока.",
            inserted: "Открой поуст герз и проверь."
        )

        XCTAssertEqual(edit?.original, "Открой поуст герз и проверь.")
        XCTAssertEqual(edit?.edited, "Открой Postgres и проверь.")
    }

    func testПравкаЧужогоТекстаВнеФрагментаИгнорируется() {
        // Человек правил СВОЙ текст до нашей вставки — не наше дело.
        let edit = InsertedEditExtractor.extract(
            baseline: "Превет! Открой поуст герз. Пока.",
            current: "Привет! Открой поуст герз. Пока.",
            inserted: "Открой поуст герз."
        )

        XCTAssertNil(edit)
    }

    func testБезИзмененийНетПравки() {
        let edit = InsertedEditExtractor.extract(
            baseline: "Открой поуст герз.",
            current: "Открой поуст герз.",
            inserted: "Открой поуст герз."
        )

        XCTAssertNil(edit)
    }

    func testВставкиНетВПоле() {
        // Поле очистили или переписали целиком — учить не из чего.
        let edit = InsertedEditExtractor.extract(
            baseline: "Совсем другой текст.",
            current: "Ещё более другой.",
            inserted: "Открой поуст герз."
        )

        XCTAssertNil(edit)
    }

    func testДописанноеПослеФрагментаНеСчитаетсяПравкой() {
        // Человек продолжил печатать после вставки — фрагмент не менялся.
        let edit = InsertedEditExtractor.extract(
            baseline: "Открой поуст герз.",
            current: "Открой поуст герз. И ещё кое-что.",
            inserted: "Открой поуст герз."
        )

        XCTAssertNil(edit)
    }

    func testПравкаНаКраюФрагментаИзвлекается() {
        // Исправили первое слово фрагмента: общий префикс кончается в чужом
        // тексте, но изменённая середина всё ещё внутри вставки.
        let edit = InsertedEditExtractor.extract(
            baseline: "Заметка: гитхаб лежит.",
            current: "Заметка: GitHub лежит.",
            inserted: "гитхаб лежит."
        )

        XCTAssertEqual(edit?.original, "гитхаб лежит.")
        XCTAssertEqual(edit?.edited, "GitHub лежит.")
    }

    func testПустоеПолеПослеВставкиНеУчит() {
        let edit = InsertedEditExtractor.extract(
            baseline: "Открой поуст герз.",
            current: "",
            inserted: "Открой поуст герз."
        )

        XCTAssertNil(edit)
    }
}
