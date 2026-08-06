import XCTest
@testable import DictationCore

/// Проверки на реальном выходе модели.
///
/// Тексты ниже — не выдумка: так Parakeet распознал фразу
/// «Нужно сделать pull request и запустить deploy через Sentry»,
/// продиктованную по-русски. Модель пишет англицизмы кириллицей, и словарь
/// существует ровно для того, чтобы вернуть им обычный вид.
final class StarterDictionaryTests: XCTestCase {
    func testFixesRealTranscriptionOfDeveloperSpeech() {
        let pipeline = TextPipeline(replacements: StarterDictionary.developer)

        // Ровно то, что вернула модель на живом прогоне.
        let recognized = "Проверяю диктовку. Нужно сделать пул реквест и запустить деплой через центри."

        let output = pipeline.process(recognized)

        XCTAssertEqual(
            output.text,
            "Проверяю диктовку. Нужно сделать pull request и запустить deploy через Sentry."
        )
    }

    func testHandlesBothSpellingsOfPullRequest() {
        let pipeline = TextPipeline(replacements: StarterDictionary.developer)

        // Модель может написать слитно или раздельно — оба варианта должны сработать.
        XCTAssertEqual(pipeline.process("закинул пулреквест").text, "Закинул pull request")
        XCTAssertEqual(pipeline.process("закинул пул реквест").text, "Закинул pull request")
    }

    func testDoesNotTouchWordsInsideOtherWords() {
        let pipeline = TextPipeline(replacements: StarterDictionary.developer)

        // «апи» есть в словаре, но «апрель» и «лапи» трогать нельзя.
        let output = pipeline.process("в апреле лапидарно")

        XCTAssertEqual(output.text, "В апреле лапидарно")
    }

    func testContainsNoPointlessSelfReplacements() {
        // Замена слова на само себя ничего не делает, только засоряет список,
        // который пользователь потом просматривает глазами.
        for replacement in StarterDictionary.developer {
            XCTAssertNotEqual(
                replacement.spoken.lowercased(),
                replacement.written.lowercased(),
                "Бессмысленная замена: \(replacement.spoken)"
            )
        }
    }

    func testMissingSkipsWhatUserAlreadyHas() {
        let existing = [
            DictionaryReplacement(spoken: "деплой", written: "выкатка"),
        ]

        let missing = StarterDictionary.missing(from: existing)

        // Своя замена важнее нашей заготовки — дубликат не предлагаем.
        XCTAssertFalse(missing.contains { $0.spoken.lowercased() == "деплой" })
        XCTAssertTrue(missing.contains { $0.spoken == "пул реквест" })
    }

    func testEveryEntryIsUsable() {
        for replacement in StarterDictionary.developer {
            XCTAssertFalse(replacement.spoken.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(replacement.written.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

final class ShortRecordingPolicyTests: XCTestCase {
    func testVeryShortRecordingIsNotWorthTranscribing() {
        // Движок отказывается работать с записями короче 300 мс, но главное не
        // это: человек, нажавший и сразу отпустивший клавишу, просто передумал.
        // Показывать ему ошибку распознавания — пугать на ровном месте.
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: 0.1))
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: 0.3))
        XCTAssertTrue(DictationDurationPolicy.isWorthTranscribing(duration: 0.5))
        XCTAssertTrue(DictationDurationPolicy.isWorthTranscribing(duration: 5))
    }
}

/// Признак «не бустить акустикой» живёт в данных заготовки.
final class StarterDictionaryBoostFlagTests: XCTestCase {
    /// Главный tripwire задачи.
    ///
    /// Хардкод убран из `VocabularyBoost`, и если признак не проставлен здесь,
    /// deploy/Sentry/commit молча вернутся в акустику — то есть откатится
    /// замер, который стоил отдельного дня.
    func testDangerousTermsCarryTheFlagInTheData() {
        let flagged = Set(
            StarterDictionary.developer.filter(\.noAcousticBoost).map(\.written)
        )
        XCTAssertEqual(flagged, ["deploy", "Sentry", "commit"])
    }

    /// Все написания опасного термина отмечены, а не только первое: «коммит» и
    /// «комет» ведут к одному `commit`, и пропуск любого вернул бы его обратно.
    func testEverySpellingOfAFlaggedTermIsFlagged() {
        for term in StarterDictionary.developer where ["deploy", "Sentry", "commit"].contains(term.written) {
            XCTAssertTrue(term.noAcousticBoost, "\(term.spoken) → \(term.written)")
        }
    }

    func testOrdinaryTermsAreStillBoosted() {
        for term in StarterDictionary.developer where term.written == "Postgres" || term.written == "Docker" {
            XCTAssertFalse(term.noAcousticBoost, term.written)
        }
    }

    /// Словари, записанные до появления признака, читаются как «бустится» —
    /// раньше решал список, а не запись.
    func testOldDictionariesDecodeWithoutTheFlag() throws {
        let json = """
        {"id":"\(UUID().uuidString)","spoken":"графана","written":"Grafana"}
        """
        let decoded = try JSONDecoder().decode(DictionaryReplacement.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.noAcousticBoost)
        XCTAssertTrue(decoded.inflects)
    }

    func testFlagSurvivesRoundTrip() throws {
        let original = DictionaryReplacement(
            spoken: "касса", written: "Kassa", inflects: false, noAcousticBoost: true
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(DictionaryReplacement.self, from: data)
        XCTAssertEqual(restored, original)
    }
}
