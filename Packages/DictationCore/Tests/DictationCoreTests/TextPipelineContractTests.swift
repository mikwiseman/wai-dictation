import XCTest
@testable import DictationCore

/// Контракт конвейера: границы стадий и гейт защищённых спанов.
final class TextPipelineContractTests: XCTestCase {
    private let dictionary = [
        DictionaryReplacement(spoken: "поуст герз", written: "Postgres", inflects: false),
        DictionaryReplacement(spoken: "сентри", written: "Sentry", inflects: false),
    ]

    // MARK: - Гейт спанов

    /// **Главный гейт волны.** Спаны, посчитанные после словаря, доезжают до
    /// вставки байт-в-байт.
    ///
    /// Корпус включает коллизионные фикстуры: термин словаря внутри бэктиков и
    /// фонетический сосед внутри пути.
    func testSpansSurviveEveryPostDictionaryStageByteForByte() {
        let corpus = [
            "правь TextPipeline.Output прямо сейчас",
            "смотри `сентри` и просто сентри",
            "лежит в /Users/mik/сентри/log точно",
            "запусти `swift  test` с --dry-run",
            "открой /etc/hosts, потом AppState.shared",
            "onTextInserted сработал, а поуст герз нет",
            "зайди на https://wai.computer/dictation сейчас",
        ]

        let pipeline = TextPipeline(replacements: dictionary)
        for text in corpus {
            let exact = DictionaryReplacements.applyExact(dictionary, to: text)
            let afterDictionary = DictionaryReplacements.applyPhonetic(
                dictionary,
                to: exact,
                protecting: ProtectedSpanDetector.detect(in: exact)
            )
            let expected = ProtectedSpanDetector.detect(in: afterDictionary).map(\.text)

            let final = pipeline.run(text).provenance.spans.map(\.text)
            XCTAssertEqual(expected, final, "спаны обязаны дожить до вставки: \(text)")
        }
    }

    /// Спаны в записи происхождения действительно принадлежат финальному тексту.
    func testProvenanceSpansBelongToTheFinalText() {
        let run = TextPipeline(replacements: dictionary)
            .run("правь TextPipeline.Output и /etc/hosts")
        XCTAssertEqual(
            ProtectedSpanDetector.detect(in: run.provenance.finalText),
            run.provenance.spans
        )
    }

    // MARK: - Границы стадий

    /// Команда отделяется до словаря — иначе словарь заденет её слова.
    func testCommandIsStrippedBeforeTheDictionary() {
        let terms = [DictionaryReplacement(spoken: "строка", written: "line", inflects: false)]
        let output = TextPipeline(replacements: terms).process("пиши сюда с новой строки")
        XCTAssertFalse(output.text.contains("line"), "слово команды словарю не достаётся")
    }

    /// `afterDictionary` снимается до косметики: пробелы ещё не схлопнуты,
    /// первая буква ещё строчная.
    func testAfterDictionaryIsTakenBeforeTypographyAndPolish() {
        let provenance = TextPipeline().run("привет   мир").provenance
        XCTAssertEqual(provenance.afterDictionary, "привет   мир")
        XCTAssertEqual(provenance.finalText, "Привет мир")
    }

    /// Свёртка типографики стоит до полишера: иначе неразрывный пробел дожил бы
    /// до вставки, а полишер его не схлопывает.
    func testTypographyFoldRunsBeforeThePolisher() {
        XCTAssertEqual(TextPipeline().process("два\u{00A0}\u{00A0}слова").text, "Два слова")
    }

    /// `.newLine` обязан материализоваться после полишера.
    ///
    /// Полишер начинается с `trimmingCharacters(in: .whitespacesAndNewlines)` —
    /// перенос, добавленный раньше, он бы просто срезал, и команда пропала бы.
    func testNewLineMustRunAfterPolishOtherwiseItIsTrimmed() {
        let output = TextPipeline().process("привет с новой строки")
        XCTAssertTrue(output.text.hasSuffix("\n"), "перенос обязан дожить до вставки")
        XCTAssertNil(output.command, "команда уже выполнена текстом")
        XCTAssertEqual(TranscriptPolisher.polish(output.text), "Привет", "а полишер бы её срезал")
    }

    // MARK: - Совместимость

    /// `process` — это `run().output`, ровно один путь и никакой второй ветки.
    func testProcessIsExactlyRunOutput() {
        let pipeline = TextPipeline(replacements: dictionary)
        for text in ["открой поуст герз", "правь Foo.Bar", "", "с новой строки"] {
            XCTAssertEqual(pipeline.process(text), pipeline.run(text).output)
        }
    }

    func testEmptyInputStaysEmpty() {
        let run = TextPipeline().run("")
        XCTAssertEqual(run.output.text, "")
        XCTAssertEqual(run.provenance.raw, "")
        XCTAssertEqual(run.provenance.spans, [])
    }
}

/// Запись происхождения последней диктовки.
final class PipelineProvenanceTests: XCTestCase {
    func testRawIsRecordedBeforeAnyStageTouchesIt() {
        let terms = [DictionaryReplacement(spoken: "поуст герз", written: "Postgres", inflects: false)]
        let provenance = TextPipeline(replacements: terms).run("открой поуст герз").provenance
        XCTAssertEqual(provenance.raw, "открой поуст герз")
        XCTAssertEqual(provenance.afterDictionary, "открой Postgres")
        XCTAssertEqual(provenance.finalText, "Открой Postgres")
    }

    func testFinalTextIsExactlyWhatWillBeInserted() {
        let pipeline = TextPipeline()
        for text in ["привет мир", "с новой строки", "правь Foo.Bar"] {
            let run = pipeline.run(text)
            XCTAssertEqual(run.provenance.finalText, run.output.text)
        }
    }

    /// Происхождение строится при любом сочетании тумблеров.
    ///
    /// Это и есть требование «независимо от настроек»: ветки, где записи нет,
    /// в продукте не существует.
    func testProvenanceIsProducedRegardlessOfEveryToggle() {
        for allowReturn in [true, false] {
            for phonetic in [true, false] {
                let pipeline = TextPipeline(
                    replacements: StarterDictionary.developer,
                    allowPressReturnCommand: allowReturn,
                    phoneticMatching: phonetic
                )
                let provenance = pipeline.run("надо сделать деплой").provenance
                XCTAssertEqual(provenance.raw, "надо сделать деплой")
                XCTAssertFalse(provenance.finalText.isEmpty)
            }
        }
    }

    /// «Никогда на диск» держится на отсутствии конформанса, а не на дисциплине.
    ///
    /// Если кто-то добавит `Codable`, чтобы «просто сохранить историю», этот
    /// тест упадёт раньше, чем текст диктовки окажется в файле.
    func testProvenanceIsNotEncodable() {
        XCTAssertFalse(
            PipelineProvenance.self is any Encodable.Type,
            "происхождение не сериализуется — это и есть гарантия, что оно не попадёт на диск"
        )
    }

    /// Описание не выносит наружу ни слова из диктовки.
    func testProvenanceDescriptionLeaksNoDictatedText() {
        let secret = "совершенно секретная фраза"
        let provenance = TextPipeline().run(secret).provenance
        let described = String(describing: provenance)

        XCTAssertFalse(described.contains("секретная"))
        XCTAssertFalse(described.contains(secret))
        XCTAssertTrue(described.contains("симв."), "а счётчики — можно")
    }
}
