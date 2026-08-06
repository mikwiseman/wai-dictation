import DictationCore
import XCTest

/// «Скопировать дословно»: то, что человек сказал, до словаря и косметики.
@MainActor
final class CopyRawTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    private func dictate(_ text: String, replacements: [DictionaryReplacement] = []) async throws -> AppState {
        try harness.installModelMarker()
        harness.transcription.text = text
        let state = harness.makeState()
        for replacement in replacements {
            state.addReplacement(spoken: replacement.spoken, written: replacement.written)
        }
        await state.refreshModelState()

        harness.monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        return state
    }

    func testДоСловарьНичегоНеСказаноКопироватьНечего() {
        XCTAssertFalse(harness.makeState().canCopyRawDictation)
    }

    /// Главное: дословный текст — это то, что сказал человек, а не то, что
    /// получилось после словаря и полишера.
    func testДословныйТекстОтличаетсяОтВставленного() async throws {
        let state = try await dictate(
            "открой поуст герз",
            replacements: [DictionaryReplacement(spoken: "поуст герз", written: "Postgres")]
        )

        let last = try XCTUnwrap(state.lastDictation)
        XCTAssertEqual(last.provenance.raw, "открой поуст герз")
        XCTAssertEqual(last.insertedText, "Открой Postgres")
        XCTAssertTrue(state.canCopyRawDictation)
    }

    /// Ничего не распознали — копировать нечего, и пункт меню не появляется.
    func testПустаяДиктовкаНеДаётЧтоКопировать() async throws {
        try harness.installModelMarker()
        harness.transcription.text = "   "
        let state = harness.makeState()
        await state.refreshModelState()

        harness.monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.monitor.onRelease?()
        for _ in 0..<60 { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertFalse(state.canCopyRawDictation)
    }

    /// Новая диктовка заменяет прежнюю: слот один, истории нет.
    func testНоваяДиктовкаЗамещаетПрежнийДословныйТекст() async throws {
        let state = try await dictate("первая фраза")
        XCTAssertEqual(state.lastDictation?.provenance.raw, "первая фраза")

        harness.transcription.text = "вторая фраза"
        harness.monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation?.provenance.raw != "вторая фраза" {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.lastDictation?.provenance.raw, "вторая фраза")
    }
}
