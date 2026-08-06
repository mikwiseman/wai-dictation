import XCTest
@testable import DictationCore

/// Расщепление словаря на точный и фонетический проходы.
///
/// Расщепление служебное: между проходами встаёт детекция спанов. Поэтому
/// главное здесь — доказать, что само расщепление ничего не изменило.
final class DictionaryPassSplitTests: XCTestCase {
    private let dictionary = [
        DictionaryReplacement(spoken: "поуст герз", written: "Postgres", inflects: false),
        DictionaryReplacement(spoken: "код", written: "code", inflects: false),
        DictionaryReplacement(spoken: "пул реквест", written: "pull request", inflects: false),
    ]

    func testExactPassAloneEqualsThePipelineWithPhoneticOff() {
        let corpus = [
            "открой поуст герз и проверь",
            "это код, а это кодировка",
            "сделай пул реквест сейчас",
            "обычная русская фраза без терминов",
            "",
        ]
        for text in corpus {
            XCTAssertEqual(
                DictionaryReplacements.applyExact(dictionary, to: text),
                DictionaryReplacements.apply(dictionary, to: text, phoneticMatching: false),
                "расщепление не имеет права менять точный проход"
            )
        }
    }

    func testFacadeStillEqualsExactThenPhonetic() {
        let text = "открой поуст герз и сделай пул реквест"
        let manual = DictionaryReplacements.applyPhonetic(
            dictionary,
            to: DictionaryReplacements.applyExact(dictionary, to: text),
            protecting: []
        )
        XCTAssertEqual(DictionaryReplacements.apply(dictionary, to: text), manual)
    }

    /// Пустое множество спанов обязано давать ровно прежний результат.
    ///
    /// Матчер жадный, и его поведение эмерджентное: сдвиг тут был бы не заметен
    /// глазом, но испортил бы каждую вторую диктовку. Гоняем на полном стартовом
    /// словаре, а не на трёх парах.
    func testEmptySpanSetChangesNothing() {
        let starter = StarterDictionary.developer
        let corpus = [
            "надо сделать деплой на сервер",
            "открой поуст герз и посмотри в центре экрана",
            "коммит уже готов, а комета нет",
            "джава скрипт и джаваскрипт — одно и то же",
            "у нас даун тайм с утра",
            "Привет, как дела? Сегодня хорошая погода.",
        ]
        for text in corpus {
            XCTAssertEqual(
                PhoneticMatching.apply(starter, to: text, protecting: []),
                PhoneticMatching.apply(starter, to: text),
                "путь без спанов должен быть неотличим от прежнего"
            )
        }
    }
}

/// Фонетический добор и защищённые спаны — коллизионные фикстуры.
final class PhoneticMatchingSpanTests: XCTestCase {
    /// «сентри» фонетически близко к Sentry — это и делает фикстуру коллизионной.
    private let dictionary = [
        DictionaryReplacement(spoken: "сентри", written: "Sentry", inflects: false)
    ]

    private func phonetic(_ text: String) -> String {
        let spans = ProtectedSpanDetector.detect(in: text)
        return DictionaryReplacements.applyPhonetic(dictionary, to: text, protecting: spans)
    }

    /// Коллизия 1: термин словаря внутри бэктиков.
    func testPhoneticDoesNotFireInsideBackticks() {
        let result = phonetic("смотри `сентри` и просто сентри")
        XCTAssertTrue(result.contains("`сентри`"), "внутри бэктиков должно остаться как есть")
        XCTAssertTrue(result.contains("просто Sentry"), "снаружи — замениться")
    }

    /// Коллизия 2: фонетический сосед внутри пути.
    func testPhoneticDoesNotFireInsideAPath() {
        let result = phonetic("лежит в /Users/mik/сентри/log")
        XCTAssertEqual(result, "лежит в /Users/mik/сентри/log")
    }

    /// Окно из трёх слов не имеет права перешагнуть спан.
    func testPhoneticWindowNeverStraddlesASpanBoundary() {
        let terms = [DictionaryReplacement(spoken: "даун тайм", written: "downtime", inflects: false)]
        let text = "был даун `код` тайм вчера"
        let spans = ProtectedSpanDetector.detect(in: text)
        let result = DictionaryReplacements.applyPhonetic(terms, to: text, protecting: spans)
        XCTAssertEqual(result, text, "через защищённый кусок термин не собирается")
    }

    /// Точная замена — явная воля человека, и она выше защиты спана.
    ///
    /// Работает не правилом приоритета, а порядком: точный проход отрабатывает
    /// раньше, чем спаны вообще посчитаны.
    func testExactReplacementOutranksSpanProtection() {
        let text = "смотри `сентри` тут"
        let afterExact = DictionaryReplacements.applyExact(dictionary, to: text)
        XCTAssertEqual(afterExact, "смотри `Sentry` тут")
    }

    /// Спаны пересчитываются после точной замены, а не берутся от сырого текста.
    func testSpansAreRecomputedAfterTheExactPass() {
        let terms = [DictionaryReplacement(spoken: "путь", written: "/etc/hosts", inflects: false)]
        let afterExact = DictionaryReplacements.applyExact(terms, to: "открой путь скорее")
        XCTAssertEqual(afterExact, "открой /etc/hosts скорее")
        XCTAssertEqual(
            ProtectedSpanDetector.detect(in: afterExact).map(\.kind), [.path],
            "замена породила путь — он обязан стать спаном"
        )
    }
}
