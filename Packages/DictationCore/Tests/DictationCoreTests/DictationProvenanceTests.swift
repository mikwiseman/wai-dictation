import XCTest
@testable import DictationCore

/// Происхождение диктовки доезжает до приложения — и только при вставке.
@MainActor
final class DictationProvenanceTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var overlay: FakeOverlay!
    private var sounds: FakeSounds!

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
        overlay = FakeOverlay()
        sounds = FakeSounds()
    }

    private func makeController(
        recognized: String,
        replacements: [DictionaryReplacement] = []
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline(replacements: replacements) }
        )
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testProvenanceIsReportedForEverySuccessfulInsertion() async throws {
        let controller = makeController(
            recognized: "открой поуст герз",
            replacements: [
                DictionaryReplacement(spoken: "поуст герз", written: "Postgres", inflects: false)
            ]
        )
        var reported: PipelineProvenance?
        controller.onDictationCompleted = { reported = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let provenance = try XCTUnwrap(reported)
        XCTAssertEqual(provenance.raw, "открой поуст герз", "дословное — то, что сказал человек")
        XCTAssertEqual(provenance.afterDictionary, "открой Postgres")
        XCTAssertEqual(provenance.finalText, "Открой Postgres")

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, [provenance.finalText], "вставлено ровно то, что записано финальным")
    }

    /// Ничего не вставили — происхождения нет.
    ///
    /// Иначе «скопировать дословно» отдало бы текст, которого человек никогда
    /// не видел, — а он ждёт последнюю вставленную диктовку.
    func testProvenanceIsNotReportedWhenNothingWasInserted() async throws {
        let controller = makeController(recognized: "   ")
        var reported: PipelineProvenance?
        controller.onDictationCompleted = { reported = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertNil(reported)
    }

    func testProvenanceIsNotReportedWhenInsertionFails() async throws {
        let controller = makeController(recognized: "привет мир")
        await inserter.setError(TextInsertionError.secureInputActive)
        var reported: PipelineProvenance?
        controller.onDictationCompleted = { reported = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertNil(reported, "неудачная вставка не даёт происхождения")
    }
}
