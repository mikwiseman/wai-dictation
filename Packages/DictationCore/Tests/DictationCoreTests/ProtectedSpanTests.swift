import XCTest
@testable import DictationCore

/// Защищённые спаны: куски текста, которые после словаря никто не трогает.
///
/// Правила намеренно консервативные. Ложный спан подавляет словарь и полишер
/// молча — человек видит неисправленный термин и не понимает почему. Пропущенный
/// спан хуже выглядит, но чинится словарём. Поэтому везде, где выбор неочевиден,
/// выбрано «не спан».
final class ProtectedSpanDetectorTests: XCTestCase {
    private func kinds(_ text: String) -> [ProtectedSpan.Kind] {
        ProtectedSpanDetector.detect(in: text).map(\.kind)
    }

    private func texts(_ text: String) -> [String] {
        ProtectedSpanDetector.detect(in: text).map(\.text)
    }

    // MARK: - Бэктики

    func testBacktickedFragmentIsOneSpanIncludingTheDelimiters() {
        XCTAssertEqual(texts("запусти `swift test` сейчас"), ["`swift test`"])
        XCTAssertEqual(kinds("запусти `swift test` сейчас"), [.backticks])
    }

    /// Незакрытый бэктик — это диктовка, а не код.
    func testUnpairedBacktickIsNotASpan() {
        XCTAssertEqual(texts("тут просто `бэктик и всё"), [])
    }

    /// Внутри бэктиков не ищется ничего: там уже код, и он защищён целиком.
    func testBacktickSpanSwallowsEverythingInside() {
        let spans = ProtectedSpanDetector.detect(in: "`TextPipeline.Output --flag /etc/hosts`")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.kind, .backticks)
    }

    // MARK: - Пути

    func testAbsoluteAndHomePathsAreSpans() {
        XCTAssertEqual(texts("открой /etc/hosts"), ["/etc/hosts"])
        XCTAssertEqual(texts("лежит в ~/Documents/Code"), ["~/Documents/Code"])
        XCTAssertEqual(kinds("открой /etc/hosts"), [.path])
    }

    /// Один слэш между обычными словами — это «или», а не путь.
    ///
    /// «и/или» и «24/7» встречаются в живой речи заметно чаще, чем путь из двух
    /// голых сегментов, поэтому требуется либо второй слэш, либо точка/дефис
    /// внутри сегмента.
    func testRelativePathNeedsMoreThanASingleSlash() {
        XCTAssertEqual(texts("правь src/main.swift"), ["src/main.swift"])
        XCTAssertEqual(texts("путь a/b/c тоже"), ["a/b/c"])
        XCTAssertEqual(texts("это и/или то"), [])
        XCTAssertEqual(texts("работает 24/7"), [])
        XCTAssertEqual(texts("формат and/or"), [])
    }

    /// Точка в конце фразы принадлежит фразе, а не пути.
    func testTrailingSentencePunctuationStaysOutsideThePath() {
        XCTAssertEqual(texts("открой /etc/hosts."), ["/etc/hosts"])
        XCTAssertEqual(texts("смотри src/main.swift, там"), ["src/main.swift"])
    }

    func testUrlIsOneSpanIncludingTheScheme() {
        XCTAssertEqual(
            texts("зайди на https://wai.computer/dictation"),
            ["https://wai.computer/dictation"]
        )
    }

    // MARK: - Флаги

    func testLongAndShortFlagsAreSpans() {
        XCTAssertEqual(texts("добавь --dry-run"), ["--dry-run"])
        XCTAssertEqual(texts("ключ -x поставь"), ["-x"])
        XCTAssertEqual(kinds("добавь --dry-run"), [.flag])
    }

    func testLongFlagCarriesItsValue() {
        XCTAssertEqual(texts("передай --out=build/app"), ["--out=build/app"])
    }

    /// Дефис внутри слова флага не делает: перед ним буква.
    ///
    /// Отдельно важен русский тире-дефис в «слово — слово»: там дальше пробел,
    /// и правило его не касается.
    func testHyphenInsideAWordIsNotAFlag() {
        XCTAssertEqual(texts("это well-known вещь"), [])
        XCTAssertEqual(texts("пишем тайп-скрипт"), [])
        XCTAssertEqual(texts("минус -5 градусов"), [])
        XCTAssertEqual(texts("Москва — столица"), [])
        XCTAssertEqual(texts("просто -- и всё"), [])
    }

    // MARK: - Идентификаторы

    /// CamelCase — это переход со строчной на заглавную. Аббревиатура им не является.
    func testCamelCaseIsASpanButAllCapsIsNot() {
        XCTAssertEqual(texts("правь TextPipeline"), ["TextPipeline"])
        XCTAssertEqual(texts("колбэк onTextInserted"), ["onTextInserted"])
        XCTAssertEqual(texts("класс URLSession"), ["URLSession"])
        XCTAssertEqual(texts("отдай API"), [])
        XCTAssertEqual(texts("формат JSON и HTTP"), [])
    }

    /// Точечному идентификатору нужна заглавная хотя бы в одном сегменте —
    /// иначе домены и версии стали бы спанами и словарь бы их не касался.
    func testDottedIdentifierNeedsAnUppercaseSegment() {
        XCTAssertEqual(texts("тип TextPipeline.Output"), ["TextPipeline.Output"])
        XCTAssertEqual(texts("зови AppState.shared"), ["AppState.shared"])
        XCTAssertEqual(texts("сайт wai.computer"), [])
        XCTAssertEqual(texts("версия 2.0.1"), [])
        XCTAssertEqual(texts("и т.д. дальше"), [])
    }

    /// Известная и принятая цена правила: склеенная английская фраза выглядит
    /// как идентификатор и остаётся склеенной. Кириллица не затронута — правило
    /// только про ASCII, поэтому «Готово.Дальше» полишер по-прежнему разобьёт.
    func testGluedEnglishSentenceIsProtectedAndThatIsTheKnownCost() {
        XCTAssertEqual(texts("Done.Next"), ["Done.Next"])
        XCTAssertEqual(texts("Готово.Дальше"), [])
    }

    // MARK: - Общие свойства

    /// Детекция идемпотентна: спаны того же текста те же.
    ///
    /// На этом держится весь контракт — стадии пересчитывают спаны после каждой
    /// правки текста, и если бы детекция «плыла», гейт байт-в-байт был бы ложным.
    func testDetectionIsIdempotent() {
        let text = "правь `swift test` в src/main.swift через --dry-run для TextPipeline.Output"
        let once = ProtectedSpanDetector.detect(in: text)
        let twice = ProtectedSpanDetector.detect(in: text)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.count, 4)
    }

    /// Диапазоны спанов действительно указывают на свой текст.
    func testRangesPointAtTheirOwnText() {
        let text = "открой /etc/hosts и правь TextPipeline"
        let characters = Array(text)
        for span in ProtectedSpanDetector.detect(in: text) {
            XCTAssertEqual(String(characters[span.range]), span.text)
        }
    }

    func testSpansNeverOverlapAndComeInOrder() {
        let text = "`код` потом /usr/local/bin затем --flag и AppState.shared"
        let spans = ProtectedSpanDetector.detect(in: text)
        XCTAssertEqual(spans.count, 4)
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.range.upperBound, later.range.lowerBound)
        }
    }

    func testOrdinaryRussianSpeechHasNoSpans() {
        XCTAssertEqual(texts("Привет, как дела? Сегодня хорошая погода."), [])
        XCTAssertEqual(texts("Надо купить молока и хлеба."), [])
    }

    func testEmptyText() {
        XCTAssertEqual(ProtectedSpanDetector.detect(in: ""), [])
    }
}
