import DictationCore
import XCTest
@testable import LocalASR

/// Правила подготовки списка терминов для подсказчика распознавания.
///
/// Модели здесь не нужно: это чистая нормализация. Ошибки в ней тихие —
/// дубликат или пустая строка не роняют распознавание, а просто портят
/// качество подсказок, — поэтому правила зафиксированы тестами.
final class VocabularyBoostTests: XCTestCase {
    func testПустыеИПробельныеТерминыВыбрасываются() {
        let boost = VocabularyBoost(terms: [.init(text: "deploy"), .init(text: ""), .init(text: "   "), .init(text: "GitHub")])

        XCTAssertEqual(boost.terms.map(\.text), ["deploy", "GitHub"])
    }

    func testДубликатыСхлопываютсяБезУчётаРегистра() {
        // Один термин двумя написаниями — это один термин: спот-модель ищет
        // акустическое тело, а не регистр. Первый вариант написания побеждает,
        // потому что именно его человек ввёл первым.
        let boost = VocabularyBoost(terms: [.init(text: "GitHub"), .init(text: "github"), .init(text: "Deploy"), .init(text: "deploy")])

        XCTAssertEqual(boost.terms.map(\.text), ["GitHub", "Deploy"])
    }

    func testПробелыПоКраямСрезаются() {
        let boost = VocabularyBoost(terms: [.init(text: "  pull request  ")])

        XCTAssertEqual(boost.terms.map(\.text), ["pull request"])
    }

    func testПустойСписокДопустим() {
        let boost = VocabularyBoost(terms: [])

        XCTAssertTrue(boost.terms.isEmpty)
        XCTAssertTrue(boost.isEmpty)
    }

    /// Готовый набор для словаря разработчика собирается из словаря замен,
    /// но три термина не попадают в него никогда: похожесть подсказчика видит
    /// сквозь алфавиты, и «deploy» ловил «тёплой», «Sentry» — «в центре»,
    /// «commit» — «комету». Замер — в docs/benchmarks.md; тест держит вывод.
    func testОпасныеТерминыНеПопадаютВАкустическийНабор() {
        let boost = VocabularyBoost.developerDefault()

        let texts = Set(boost.terms.map(\.text))
        XCTAssertFalse(texts.contains("deploy"), "«deploy» ловил «тёплой»")
        XCTAssertFalse(texts.contains("Sentry"), "«Sentry» ловил «в центре»")
        XCTAssertFalse(texts.contains("commit"), "«commit» ловил «комету»")

        // Остальной словарь при этом попадает целиком, с кириллическими
        // псевдонимами: без них мост от звука к латинице не работает.
        XCTAssertTrue(texts.contains("Kubernetes"))
        XCTAssertTrue(texts.contains("pull request"))
        // У Kubernetes два кириллических написания — склоняемое и огрех
        // распознавания; оба служат мостами и оба должны попасть в набор.
        let kubernetes = boost.terms.first { $0.text == "Kubernetes" }
        XCTAssertEqual(Set(kubernetes?.aliases ?? []), ["кубернетес", "кубернетис"])
    }

    /// Замены пользователя — включая выученные из правок — попадают в
    /// акустический набор с теми же предохранителями, что и стартовые.
    func testПользовательскиеЗаменыПополняютНаборСФильтрами() {
        let boost = VocabularyBoost.withUserReplacements([
            // дубликат стартового — не плодится
            DictionaryReplacement(spoken: "поуст герз", written: "Postgres"),
            // новый термин — учится
            DictionaryReplacement(spoken: "графана", written: "Grafana"),
            // опасный — заготовка держит на нём флаг, и запись человека его
            // не отменяет
            DictionaryReplacement(spoken: "деплой", written: "deploy"),
            // без латиницы — не термин
            DictionaryReplacement(spoken: "как слышится", written: "как пишется"),
            // свой опасный термин: раньше человек не мог исключить ничего
            DictionaryReplacement(spoken: "касса", written: "Kassa", noAcousticBoost: true),
        ])

        let texts = boost.terms.map(\.text)
        XCTAssertTrue(texts.contains("Grafana"))
        XCTAssertFalse(texts.contains("deploy"))
        XCTAssertFalse(texts.contains("как пишется"))
        XCTAssertFalse(texts.contains("Kassa"), "человек отметил термин — в акустику он не идёт")
        XCTAssertEqual(texts.filter { $0.lowercased() == "postgres" }.count, 1)
        let grafana = boost.terms.first { $0.text == "Grafana" }
        XCTAssertEqual(grafana?.aliases, ["графана"])
    }

    /// Кириллические написания — мост между звуком и латинским термином:
    /// текст модели кириллический, и без таких псевдонимов кандидат для
    /// замены не находится вовсе.
    func testПсевдонимыНормализуютсяКакТермины() {
        let boost = VocabularyBoost(terms: [
            .init(text: "deploy", aliases: [" деплой ", "", "ДЕПЛОЙ", "диплой", "deploy"])
        ])

        XCTAssertEqual(boost.terms.first?.aliases, ["деплой", "диплой"])
    }

    func testТерминБезПсевдонимовДопустим() {
        let boost = VocabularyBoost(terms: [.init(text: "GitHub")])

        XCTAssertEqual(boost.terms.first?.aliases, [])
    }
}
