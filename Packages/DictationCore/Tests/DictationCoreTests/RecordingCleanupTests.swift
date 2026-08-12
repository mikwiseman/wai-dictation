import XCTest
@testable import DictationCore

/// Запись голоса не должна оставаться на диске после того, как текст распознан.
///
/// Дефект, который эти тесты стерегут, был настоящим: файлы не удалялись
/// никогда. Полчаса диктовки в день — это около двадцати гигабайт за год и,
/// что важнее, архив всего сказанного вслух у продукта, который обещает
/// приватность.
@MainActor
final class RecordingCleanupTests: XCTestCase {
    private var directory: URL!

    /// Захват, который создаёт настоящий файл — иначе проверять нечего.
    ///
    /// Прервать умеет только незакрытую запись, как настоящий: после
    /// `stopRecording` файл уже закрыт и отдан наружу, и удалять его теперь
    /// некому, кроме владельца сессии.
    private final class FileCapture: AudioCapturing, @unchecked Sendable {
        let directory: URL
        let duration: TimeInterval
        private(set) var lastFile: URL?
        private var isRecording = false
        /// Задержка ровно там, где она есть у настоящего захвата: файл уже
        /// закрыт и лежит на диске, а вызов ещё не вернулся. С этого момента
        /// прерывание записи не удаляет ничего — удалять умеет только владелец.
        private let stopGate: Gate?

        init(directory: URL, duration: TimeInterval = 3.0, stopGate: Gate? = nil) {
            self.directory = directory
            self.duration = duration
            self.stopGate = stopGate
        }

        func startRecording() async throws -> URL {
            let url = directory.appending(path: "take-\(UUID().uuidString).wav")
            try Data("звук".utf8).write(to: url)
            lastFile = url
            isRecording = true
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let lastFile, isRecording else { throw AudioCaptureError.notRecording }
            isRecording = false
            if let stopGate { await stopGate.pass() }
            return (lastFile, duration)
        }

        func abortRecording() async {
            guard isRecording, let lastFile else { return }
            isRecording = false
            try? FileManager.default.removeItem(at: lastFile)
        }
    }

    // Асинхронные варианты, а не `setUpWithError`: тот вызывается вне главного
    // актора, а класс к нему привязан — обращение к `directory` пересекало бы
    // границу изоляции. Сейчас это предупреждение, но каталог при этом уже
    // читается не оттуда, откуда пишется.
    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "takes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settle(_ iterations: Int = 15) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeController(
        capture: FileCapture,
        transcribeError: Error? = nil,
        transcribeDelay: Duration = .zero,
        transcribeGate: Gate? = nil,
        transcribeEntered: Gate? = nil,
        insertError: TextInsertionError? = nil,
        overlay: any OverlayPresenting = FakeOverlay(),
        recordingRecovery: any RecordingRecoveryStoring = DiscardingRecordingRecovery()
    ) -> DictationController {
        let inserter = FakeInserter()
        if let insertError {
            Task { await inserter.setError(insertError) }
        }
        return DictationController(
            capture: capture,
            transcribe: { _ in
                if transcribeDelay > .zero { try await Task.sleep(for: transcribeDelay) }
                if let transcribeEntered { await transcribeEntered.open() }
                if let transcribeGate { await transcribeGate.pass() }
                if let transcribeError { throw transcribeError }
                return ASRResult(text: "распознано", audioDuration: 3, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: FakeSounds(),
            recordingRecovery: recordingRecovery
        )
    }

    func testRecordingIsDeletedAfterSuccessfulInsertion() async throws {
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "После вставки запись голоса должна быть удалена: \(leftovers)")
    }

    func testRecordingIsPreservedWhenRecognitionFails() async throws {
        // При сбое ASR WAV — единственный путь повторить диктовку без потери.
        let capture = FileCapture(directory: directory)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let controller = makeController(
            capture: capture,
            transcribeError: ASREngineError.inferenceFailed("сбой"),
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let recordings = try FileManager.default.contentsOfDirectory(
            at: recovered,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recordings.filter { $0.pathExtension == "wav" }.count, 1)
    }

    func testRecordingIsDeletedWhenInsertionFails() async throws {
        // Текст сохранён отдельным файлом, а сам голос хранить незачем.
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture, insertError: .accessibilityPermissionDenied)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "После неудачной вставки запись удаляется: \(leftovers)")
    }

    func testRecordingIsDeletedOnCancel() async throws {
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.cancel()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "Отменённая диктовка не оставляет записи: \(leftovers)")
    }

    func testAccidentalTapLeavesNoRecording() async throws {
        // Случайное касание клавиши: распознавать нечего — и именно поэтому
        // запись легко забыть. Файл при этом настоящий, с голосом, и лежит он
        // до следующего запуска приложения, которое живёт в меню неделями.
        let capture = FileCapture(directory: directory, duration: 0.1)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "Слишком короткая запись тоже удаляется: \(leftovers)")
    }

    func testCancelBeforeRecognitionFailureLeavesNeitherFileNorNotice() async throws {
        // Человек нажал Escape, а движок в это время всё-таки успел упасть.
        // Отмена уже случилась: WAV отменённой диктовки не имеет права осесть
        // в папке повтора, а сбой — объявиться сообщением. Иначе Escape
        // оставляет ровно тот след, от которого он и должен избавлять.
        let gate = Gate()
        let entered = Gate()
        let capture = FileCapture(directory: directory)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let overlay = CollectingOverlay()
        let controller = makeController(
            capture: capture,
            transcribeError: ASREngineError.inferenceFailed("сбой"),
            transcribeGate: gate,
            transcribeEntered: entered,
            overlay: overlay,
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        // Ждём не состояния, а того, что движок действительно начал работу:
        // состояние переключается синхронно, задача — нет, и отмена, посланная
        // раньше первой строки задачи, проверяла бы совсем другую ветку.
        await entered.pass()
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        await settle()
        await gate.open()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        await settle()

        let saved = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertTrue(saved.isEmpty, "Отменённая диктовка не сохраняется для Retry: \(saved)")

        let takes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        XCTAssertTrue(takes.isEmpty, "Отменённая диктовка не оставляет запись в Takes: \(takes)")

        let presented = await overlay.notices
        XCTAssertTrue(
            presented.allSatisfy { $0.kind != .failure },
            "После отмены сообщать не о чем: \(presented.map(\.message))"
        )
        XCTAssertTrue(notices.allSatisfy { $0.recoveryAudio == nil })
    }

    func testCancelDuringRescueLeavesNeitherFileNorNotice() async throws {
        // Устройство пропало посреди речи: контроллер закрывает WAV и готовит
        // его к Retry. Пока файл закрывается, человек нажимает Escape — и с
        // этого момента у диктовки один исход. Отменённая запись не имеет
        // права ни осесть на диске «для повтора», ни объявиться сообщением о
        // сбое поверх той сессии, которую человек начал следом.
        let gate = Gate()
        let capture = FileCapture(directory: directory, stopGate: gate)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let overlay = CollectingOverlay()
        var notices: [DictationNotice] = []
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "распознано", audioDuration: 3, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: overlay,
            sounds: FakeSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.preserveActiveRecording(reason: "Устройство отключилось.")
        await settle()
        XCTAssertEqual(controller.state, .transcribing, "Спасение записи обязано начаться")

        controller.cancel()
        await settle()
        await gate.open()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        await settle()

        let takes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        XCTAssertTrue(takes.isEmpty, "Отменённая диктовка не оставляет запись в Takes: \(takes)")

        let saved = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertTrue(saved.isEmpty, "Отменённая диктовка не сохраняется для Retry: \(saved)")

        let presented = await overlay.notices
        XCTAssertTrue(
            presented.allSatisfy { $0.kind != .failure },
            "После отмены сообщение о сбое спасения показывать не за что: \(presented.map(\.message))"
        )
        XCTAssertTrue(
            notices.allSatisfy { $0.recoveryAudio == nil },
            "Отменённая запись не предлагается для Retry"
        )
        XCTAssertEqual(controller.state, .idle)
    }

    /// Устройство пропало через мгновение после старта — спасать нечего.
    ///
    /// Обрывок короче предела распознавания главный путь молча удаляет:
    /// человек ничего не потерял. Спасение обязано вести себя так же, иначе
    /// секундный сбой устройства оставляет «запись для повтора», повтор
    /// которой навсегда даёт пустой результат.
    func testRescueOfTooShortRecordingDiscardsInsteadOfSaving() async throws {
        let capture = FileCapture(directory: directory, duration: 0.1)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let overlay = CollectingOverlay()
        var notices: [DictationNotice] = []
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "распознано", audioDuration: 3, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: overlay,
            sounds: FakeSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.preserveActiveRecording(reason: "Устройство отключилось.")
        for _ in 0..<100 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let saved = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertTrue(saved.isEmpty, "Обрывок короче предела не сохраняется: \(saved)")
        let takes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        XCTAssertTrue(takes.isEmpty, "И в Takes не остаётся: \(takes)")

        XCTAssertTrue(notices.allSatisfy { $0.recoveryAudio == nil })
        XCTAssertTrue(
            notices.contains { $0.message.contains("Устройство отключилось.") },
            "Причину обрыва называть всё равно обязаны: \(notices.map(\.message))"
        )
        XCTAssertFalse(
            notices.contains { $0.message.contains("saved locally") || $0.message.contains("Couldn't save") },
            "Про спасение записи, которой нет, говорить нечего: \(notices.map(\.message))"
        )
    }

    func testRecordingIsDeletedWhenCancelledDuringTranscription() async throws {
        // Отмена приходит, когда запись уже закрыта и лежит на диске: прервать
        // тут нечего, а удалить — обязательно.
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture, transcribeDelay: .milliseconds(800))

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        // Момент «распознавание идёт» ловится опросом: фиксированный сон на
        // перегруженном CI-runner спит дольше всего распознавания целиком.
        for _ in 0..<400 where controller.state != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<400 {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            if entries.isEmpty, controller.state == .idle { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "Отмена во время распознавания не оставляет голос на диске: \(leftovers)")
    }
}
