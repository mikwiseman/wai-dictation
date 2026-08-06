import XCTest
@testable import DictationCore

/// Обучение на правках и защищённые спаны.
///
/// Правка внутри кода — это правка кода, а не термина. Превращать её в
/// молчаливое правило будущих диктовок нельзя: человек чинил конкретную строку,
/// а не учил приложение языку.
final class CorrectionLearningSpanTests: XCTestCase {
    func testProposalsAreNeverBuiltFromTextInsideASpan() {
        let inserted = "запусти `сентри` сейчас"
        let spans = ProtectedSpanDetector.detect(in: inserted)
        XCTAssertEqual(spans.map(\.kind), [.backticks], "предусловие теста")

        let proposals = CorrectionLearning.propose(
            original: inserted,
            edited: "запусти `Sentry` сейчас",
            protecting: spans
        )
        XCTAssertTrue(proposals.isEmpty, "правка внутри бэктиков термина не делает")
    }

    func testPathEditsDoNotTeachTheDictionary() {
        let inserted = "лежит в /Users/mik/сентри/log"
        let proposals = CorrectionLearning.propose(
            original: inserted,
            edited: "лежит в /Users/mik/sentry/log",
            protecting: ProtectedSpanDetector.detect(in: inserted)
        )
        XCTAssertTrue(proposals.isEmpty)
    }

    /// Та же правка вне спана учит как раньше — иначе тест выше проходил бы
    /// и на «обучение сломано полностью».
    func testTheSameEditOutsideASpanStillTeaches() {
        let inserted = "запусти сентри сейчас"
        let proposals = CorrectionLearning.propose(
            original: inserted,
            edited: "запусти Sentry сейчас",
            protecting: ProtectedSpanDetector.detect(in: inserted)
        )
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.spoken, "сентри")
        XCTAssertEqual(proposals.first?.written, "Sentry")
    }

    /// Дефолт пустого списка держит прежнее поведение.
    ///
    /// Сравниваются пары, а не структуры целиком: `id` — свежий UUID на каждый
    /// вызов, и равенства структур не будет никогда.
    func testWithoutSpansProposalsAreExactlyWhatTheyWere() {
        let original = "открой поуст герз и сентри"
        let edited = "открой Postgres и Sentry"
        let pairs = { (proposals: [DictionaryReplacement]) in
            proposals.map { [$0.spoken, $0.written, "\($0.inflects)"] }
        }
        XCTAssertEqual(
            pairs(CorrectionLearning.propose(original: original, edited: edited)),
            pairs(CorrectionLearning.propose(original: original, edited: edited, protecting: []))
        )
    }
}
