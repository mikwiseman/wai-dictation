import XCTest
@testable import DictationCore

/// Отчёт о скорости: три отметки от отпускания клавиши.
@MainActor
final class DictationSpeedTests: XCTestCase {
    /// Вставщик со сценарием отметок — снаружи их не поймать.
    private actor MarkingInserter: TextInserting {
        private var marks: InsertionMarks
        private(set) var insertedTexts: [String] = []
        private var error: Error?

        init(marks: InsertionMarks) { self.marks = marks }

        func setError(_ error: Error) { self.error = error }

        func insert(_ text: String, into target: TargetApplication?) async throws {
            _ = try await insertReportingMarks(text, into: target)
        }

        func insertReportingMarks(
            _ text: String,
            into target: TargetApplication?
        ) async throws -> InsertionMarks {
            if let error { throw error }
            insertedTexts.append(text)
            return marks
        }

        func pressReturn() async throws {}
        nonisolated func frontmostApplication() -> TargetApplication? { nil }
    }

    /// Захват со сценарным разогревом микрофона.
    private actor TimedCapture: AudioCapturing {
        private let latency: Duration?
        private var url: URL?

        init(latency: Duration?) { self.latency = latency }

        func startRecording() async throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "speed-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            self.url = url
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let url else { throw AudioCaptureError.notRecording }
            return (url, 2)
        }

        func abortRecording() async {}
        func startupLatency() async -> Duration? { latency }
    }

    private func settle(_ iterations: Int = 20) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Часы, выдающие заранее известные моменты по очереди.
    private final class ScriptedClock: @unchecked Sendable {
        private let origin = ContinuousClock.now
        private var offsets: [Duration]
        private var index = 0
        private let lock = NSLock()

        init(offsets: [Duration]) { self.offsets = offsets }

        func next() -> ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            let offset = index < offsets.count ? offsets[index] : offsets.last ?? .zero
            index += 1
            return origin.advanced(by: offset)
        }

        func instant(at offset: Duration) -> ContinuousClock.Instant {
            origin.advanced(by: offset)
        }
    }

    func testSpeedIsMeasuredFromTheKeyRelease() async throws {
        // t0 = 0 мс (отпускание), t1 = 120 мс (движок вернул текст).
        let clock = ScriptedClock(offsets: [.milliseconds(0), .milliseconds(120)])
        let inserter = MarkingInserter(
            marks: InsertionMarks(
                pasteDispatchedAt: clock.instant(at: .milliseconds(150)),
                clipboardRestoredAt: clock.instant(at: .milliseconds(1150))
            )
        )
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: .milliseconds(130)),
            transcribe: { _ in ASRResult(text: "привет мир", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            monotonicNow: { clock.next() }
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let speed = try XCTUnwrap(report)
        XCTAssertEqual(speed.toRecognizedText, .milliseconds(120))
        XCTAssertEqual(speed.toPasteDispatched, .milliseconds(150))
        XCTAssertEqual(speed.toClipboardRestored, .milliseconds(1150))
        XCTAssertEqual(speed.microphoneStartup, .milliseconds(130))
    }

    /// Отметки идут по порядку: текст → вставка → восстановление буфера.
    func testMarksAreOrdered() async throws {
        let clock = ScriptedClock(offsets: [.milliseconds(0), .milliseconds(120)])
        let inserter = MarkingInserter(
            marks: InsertionMarks(
                pasteDispatchedAt: clock.instant(at: .milliseconds(150)),
                clipboardRestoredAt: clock.instant(at: .milliseconds(1150))
            )
        )
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in ASRResult(text: "привет", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            monotonicNow: { clock.next() }
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let speed = try XCTUnwrap(report)
        let paste = try XCTUnwrap(speed.toPasteDispatched)
        let restored = try XCTUnwrap(speed.toClipboardRestored)
        XCTAssertLessThanOrEqual(speed.toRecognizedText, paste)
        XCTAssertLessThanOrEqual(paste, restored)
    }

    /// Настенные часы на отчёт не влияют вовсе.
    ///
    /// Ради этого и заведены отдельные монотонные часы: сон, переход на летнее
    /// время или подводка по NTP посреди диктовки иначе дали бы отрицательное
    /// «stop → текст», то есть просто враньё.
    func testReportIgnoresWallClockJumps() async throws {
        let clock = ScriptedClock(offsets: [.milliseconds(0), .milliseconds(120)])
        let wall = WallClockBox()
        let inserter = MarkingInserter(marks: InsertionMarks())
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in
                // Пока идёт распознавание, «часы перевели» на час назад.
                wall.rewindAnHour()
                return ASRResult(text: "привет", audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            now: { wall.current },
            monotonicNow: { clock.next() }
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertEqual(try XCTUnwrap(report).toRecognizedText, .milliseconds(120))
    }

    /// Вставка не удалась — честного числа нет, отчёта тоже.
    func testFailedInsertionProducesNoReport() async throws {
        let inserter = MarkingInserter(marks: InsertionMarks())
        await inserter.setError(TextInsertionError.secureInputActive)
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in ASRResult(text: "привет", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertNil(report)
    }

    /// Край без измерения отдаёт `nil`, а не ноль: мгновенным он не бывает.
    func testUnmeasuredEdgesReportNilNotZero() async throws {
        let inserter = MarkingInserter(marks: InsertionMarks())
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in ASRResult(text: "привет", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let speed = try XCTUnwrap(report)
        XCTAssertNil(speed.toPasteDispatched)
        XCTAssertNil(speed.toClipboardRestored)
        XCTAssertNil(speed.microphoneStartup)
    }

    /// Реализация по умолчанию не притворяется измеряющей и вставляет ровно раз.
    func testDefaultInsertReportingMarksCallsInsertExactlyOnce() async throws {
        let plain = PlainInserter()
        let marks = try await plain.insertReportingMarks("привет", into: nil)
        XCTAssertNil(marks.pasteDispatchedAt)
        XCTAssertNil(marks.clipboardRestoredAt)
        let count = await plain.insertCount
        XCTAssertEqual(count, 1, "ни рекурсии, ни двойной вставки")
    }

    private actor PlainInserter: TextInserting {
        private(set) var insertCount = 0
        func insert(_ text: String, into target: TargetApplication?) async throws { insertCount += 1 }
        func pressReturn() async throws {}
        nonisolated func frontmostApplication() -> TargetApplication? { nil }
    }

    private final class WallClockBox: @unchecked Sendable {
        private var value = Date()
        private let lock = NSLock()
        var current: Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func rewindAnHour() {
            lock.lock(); defer { lock.unlock() }
            value = value.addingTimeInterval(-3600)
        }
    }
}
