import DictationCore
import LocalASR
import XCTest

/// Проводка приложения: что происходит на краях, где всё обычно и ломается.
@MainActor
final class AppStateTests: XCTestCase {
    func testОшибкаАудиоконвертераНеМаскируетсяПодНехваткуМеста() {
        let message = AppState.captureFailureMessage(
            .unsupportedAudioFormat("48 kHz stereo couldn't be converted")
        )

        XCTAssertTrue(message.contains("audio format"))
        XCTAssertTrue(message.contains("48 kHz stereo"))
        XCTAssertFalse(message.contains("disk space"))
    }

    private var harness: AppHarness!

    private var root: URL { harness.root }
    private var defaults: UserDefaults { harness.defaults }
    private var permissions: FakePermissions { harness.permissions }
    private var accessibilityManager: FakeAccessibilityManager { harness.accessibilityManager }
    private var monitor: FakeHotkeyMonitor { harness.monitor }
    private var overlay: FakeOverlay { harness.overlay }
    private var capture: FakeCapture { harness.capture }

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func makeState() -> AppState { harness.makeState() }

    private func installModelMarker() throws { try harness.installModelMarker() }

    // MARK: - Разрешения

    func testБезУниверсальногоДоступаСлежениеНеИдёт() {
        permissions.accessibilityGranted = false

        let state = makeState()

        XCTAssertFalse(state.accessibilityGranted)
        XCTAssertFalse(state.isDictationReady)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(state.accessibilityState, .denied)
    }

    func testЗапросAccessibilityОткрываетНастройкиИНачинаетОжидание() {
        permissions.accessibilityGranted = false
        let state = makeState()

        state.requestAccessibility()

        XCTAssertEqual(accessibilityManager.requestCount, 1)
        XCTAssertEqual(accessibilityManager.openSettingsCount, 1)
        XCTAssertEqual(accessibilityManager.resetCount, 0)
        XCTAssertEqual(state.accessibilityState, .waitingForSettings)
    }

    func testВозвратИзНастроекБезДоступаПредлагаетПерезапуск() async {
        permissions.accessibilityGranted = false
        let state = makeState()
        state.requestAccessibility()

        harness.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(state.accessibilityState, .restartRequired)
    }

    func testПерезапускДляAccessibilityЗапоминаетНезавершенноеВосстановление() async {
        permissions.accessibilityGranted = false
        let state = makeState()

        state.restartForAccessibility()
        await Task.yield()

        XCTAssertEqual(accessibilityManager.relaunchCount, 1)
        XCTAssertTrue(defaults.bool(forKey: AppState.accessibilityRelaunchPendingKey))
    }

    func testПослеНеудачногоПерезапускаПредлагаетсяRepair() {
        permissions.accessibilityGranted = false
        defaults.set(true, forKey: AppState.accessibilityRelaunchPendingKey)

        let state = makeState()

        XCTAssertEqual(state.accessibilityState, .repairRequired)
        XCTAssertEqual(accessibilityManager.resetCount, 0)
    }

    func testПолученныйПослеПерезапускаДоступОчищаетRepairMarker() {
        permissions.accessibilityGranted = true
        defaults.set(true, forKey: AppState.accessibilityRelaunchPendingKey)

        let state = makeState()

        XCTAssertEqual(state.accessibilityState, .granted)
        XCTAssertFalse(defaults.bool(forKey: AppState.accessibilityRelaunchPendingKey))
    }

    func testЯвныйRepairСбрасываетТолькоПослеКомандыИПерезапускаетПриложение() async {
        permissions.accessibilityGranted = false
        defaults.set(true, forKey: AppState.accessibilityRelaunchPendingKey)
        let state = makeState()
        XCTAssertEqual(accessibilityManager.resetCount, 0)

        state.repairAccessibility()
        for _ in 0..<20 where accessibilityManager.relaunchCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(accessibilityManager.resetCount, 1)
        XCTAssertEqual(accessibilityManager.relaunchCount, 1)
        XCTAssertFalse(defaults.bool(forKey: AppState.accessibilityRelaunchPendingKey))
    }

    func testОшибкаRepairНеПерезапускаетИНазываетПроблему() async {
        permissions.accessibilityGranted = false
        accessibilityManager.resetError = CocoaError(.fileWriteNoPermission)
        let state = makeState()

        state.repairAccessibility()
        for _ in 0..<20 where state.accessibilityState == .repairing {
            await Task.yield()
        }

        guard case .failed = state.accessibilityState else {
            return XCTFail("Ожидалась видимая ошибка восстановления")
        }
        XCTAssertEqual(accessibilityManager.relaunchCount, 0)
    }

    func testПоказатьПриложениеДляРучногоДобавления() {
        let state = makeState()

        state.revealApplicationForAccessibility()

        XCTAssertEqual(accessibilityManager.revealApplicationCount, 1)
    }

    func testСДоступомСлежениеЗапускается() {
        permissions.accessibilityGranted = true

        _ = makeState()

        XCTAssertTrue(monitor.isRunning)
    }

    /// Доступ отобрали, пока приложение работало.
    ///
    /// Слежение обязано остановиться: система всё равно перестала отдавать
    /// события, а живая подписка создавала бы вид, что клавиша работает.
    func testОтозванныйДоступОстанавливаетСлежение() {
        permissions.accessibilityGranted = true
        let state = makeState()
        XCTAssertTrue(monitor.isRunning)

        permissions.accessibilityGranted = false
        state.refreshPermissions()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(state.isDictationReady)
    }

    func testОтозванныйAccessibilityВоВремяЗаписиСохраняетWAV() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.dictationState, .listening)

        permissions.accessibilityGranted = false
        state.refreshPermissions()
        for _ in 0..<60 where state.recoveredRecording == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertNotNil(state.recoveredRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.recoveredRecording?.path ?? ""))
    }

    func testОтозванныйМикрофонВоВремяЗаписиСохраняетWAV() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.dictationState, .listening)

        permissions.microphoneGranted = false
        state.refreshPermissions()
        for _ in 0..<60 where state.recoveredRecording == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertFalse(state.isDictationReady)
        XCTAssertNotNil(state.recoveredRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.recoveredRecording?.path ?? ""))
    }

    func testОтзывAccessibilityВоВремяРаспознаванияСразуПоказываетNotice() async throws {
        try installModelMarker()
        harness.transcription.delay = .milliseconds(300)
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        monitor.onRelease?()
        for _ in 0..<40 where state.dictationState != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.dictationState, .transcribing)

        permissions.accessibilityGranted = false
        state.refreshPermissions()

        XCTAssertEqual(state.lastNotice?.message.contains("Accessibility access was revoked"), true)
    }

    func testБезМикрофонаДиктовкаНеГотова() {
        permissions.microphoneGranted = false

        let state = makeState()

        XCTAssertFalse(state.isDictationReady)
    }

    /// Нажатие клавиши без разрешений не должно запускать запись.
    func testБезРазрешенийНажатиеНичегоНеЗапускает() {
        permissions.accessibilityGranted = false
        permissions.microphoneGranted = false
        let state = makeState()

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Модель

    func testБезМоделиНажатиеНичегоНеЗапускает() async {
        let state = makeState()
        await state.refreshModelState()
        XCTAssertFalse(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Первая успешная диктовка

    func testСчётчикРастётТолькоПослеУспешнойВставки() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertEqual(state.successfulDictationCount, 0)

        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.successfulDictationCount, 0)
        monitor.onRelease?()
        for _ in 0..<60 where state.dictationState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.successfulDictationCount, 1)
    }

    func testЯвнаяОтменаЗаписиПодтверждаетУдаление() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        state.cancelCurrentDictation()
        for _ in 0..<40 where state.dictationState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.lastNotice?.message, "Dictation cancelled. The recording was deleted.")
        XCTAssertEqual(state.successfulDictationCount, 0)
    }

    func testСМодельюИРазрешениямиНажатиеЗапускаетДиктовку() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .preparing)
    }

    /// Удаление модели посреди диктовки.
    ///
    /// Модель сейчас в работе. Снести её из-под себя значит потерять уже
    /// сказанное и показать вместо этого невнятную ошибку загрузки.
    func testМодельНеУдаляетсяВоВремяДиктовки() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertNotEqual(state.dictationState, .idle)

        state.deleteModel()

        XCTAssertEqual(state.lastNotice?.kind, .warning)
        XCTAssertEqual(state.modelState.isReady, true)
        // Сообщение обязано дойти до экрана, а не осесть в поле. Показывается
        // оно задачей, поэтому даём ей дойти до оверлея.
        try await Task.sleep(for: .milliseconds(100))
        let notices = await overlay.notices
        XCTAssertTrue(notices.contains { $0.message.contains("Wait for it to finish") })
    }

    func testВПокоеМодельУдаляется() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.modelState.isReady)

        state.deleteModel()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(state.modelState.isReady)
    }

    func testСтарыйКаталогТекстовыхRecoveryУдаляетсяПриЗапуске() async throws {
        // Прошлые сборки писали нераспознанный текст в Recovered/. Обещание
        // «распознанный текст не пишется на диск» обязано покрывать и их следы.
        let legacy = harness.root.appending(path: "WaiDictation", directoryHint: .isDirectory)
            .appending(path: "Recovered", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("старая диктовка".utf8).write(to: legacy.appending(path: "recovery-1.txt"))

        _ = makeState()
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: legacy.path) { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.path),
            "Тексты диктовок старых сборок обязаны исчезнуть при первом же запуске"
        )
    }

    func testДоборПодсказчикаПослеОбновленияПриложения() async throws {
        // Человек обновился со сборки, где подсказчика ещё не было: основная
        // модель стоит, подсказчика нет. Для него это «модель не готова», а
        // кнопка обязана называть настоящий остаток, а не полные 586 МБ.
        try harness.installMainModelMarkerOnly()
        let state = makeState()

        await state.refreshModelState()

        XCTAssertFalse(state.modelState.isReady)
        XCTAssertEqual(state.remainingDownloadMegabytes, 103)
    }

    func testПадениеПрогреваПереживаетОбновлениеСостоянияМодели() async throws {
        // Файлы модели целы, но Core ML их не поднимает. Осмотр диска такое
        // состояние увидеть не может: он снова скажет «готово».
        try installModelMarker()
        harness.warmUpEngine = FailingASREngine()
        let state = makeState()

        // Прогрев на старте падает и просит явное восстановление.
        for _ in 0..<200 {
            if case .repairRequired = state.modelState { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .repairRequired = state.modelState else {
            return XCTFail("Прогрев обязан был кончиться repairRequired, а не \(state.modelState)")
        }

        // Человек открыл настройки — экран обновил состояние модели с диска.
        await state.refreshModelState()

        // Кнопка восстановления не имеет права исчезнуть: диктовка не работает,
        // а «Готовлю модель…» без конца — это тупик без выхода.
        guard case .repairRequired = state.modelState else {
            return XCTFail(
                "Осмотр диска затёр repairRequired: \(state.modelState). Человек остался без кнопки восстановления."
            )
        }
        XCTAssertFalse(state.isEngineReady)
    }

    // MARK: - Нажатие в неготовности

    /// Дождаться сообщения на панели. Объяснение уходит туда через задачу, и
    /// сразу после нажатия его там ещё нет.
    private func waitForNotice(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let messages = await overlay.notices.map(\.message)
            if messages.contains(where: { $0.contains(fragment) }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        let messages = await overlay.notices.map(\.message)
        XCTFail("не дождались «\(fragment)». Сказано: \(messages)", file: file, line: line)
    }

    /// Раньше нажатие в неготовности не делало ровным счётом ничего: ядро
    /// отклоняло старт молча, и человек оставался с рабочей на вид программой,
    /// которая не отзывается на клавишу.
    func testНажатиеБезМоделиОбъясняетПочемуНичегоНеНачалось() async throws {
        let state = makeState()
        await state.refreshModelState()
        XCTAssertFalse(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
        try await waitForNotice(containing: "model isn't downloaded")
    }

    func testНажатиеБезМикрофонаНазываетМикрофон() async throws {
        try installModelMarker()
        harness.permissions.microphoneGranted = false
        let state = makeState()
        await state.refreshModelState()

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
        try await waitForNotice(containing: "microphone access")
    }

    /// Тот же ответ на жест без удержания: молчать на двойное нажатие так же
    /// нечестно, как на обычное.
    func testДвойноеНажатиеВНеготовностиТожеОбъясняется() async throws {
        let state = makeState()
        await state.refreshModelState()

        monitor.onDoubleTap?()

        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertFalse(state.isHandsFreeActive)
        try await waitForNotice(containing: "model isn't downloaded")
    }

    /// В готовности объяснять нечего: панель показывает саму диктовку.
    func testВГотовностиНажатиеНеПородитЛишнегоСообщения() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        let before = await overlay.notices.count

        monitor.onPress?()
        XCTAssertEqual(state.dictationState, .preparing)

        // Дать задаче объяснения шанс сработать, если бы она была заведена.
        try await Task.sleep(for: .milliseconds(50))
        let after = await overlay.notices.count
        XCTAssertEqual(after, before, "готовая диктовка не имеет права ничего объяснять")
    }

    /// Нажатие поверх идущей диктовки ядро тоже отклоняет — и здесь молчание
    /// уместно: панель на экране, человек и так видит, что происходит.
    func testНажатиеПосредиДиктовкиНеПридирается() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertEqual(state.dictationState, .preparing)
        let before = await overlay.notices.count

        monitor.onPress?()

        try await Task.sleep(for: .milliseconds(50))
        let after = await overlay.notices.count
        XCTAssertEqual(after, before)
    }

    // MARK: - Жесты

    func testДвойноеНажатиеВПокоеНачинаетДиктовкуБезУдержания() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        monitor.onDoubleTap?()

        XCTAssertEqual(state.dictationState, .preparing)
        XCTAssertTrue(state.isHandsFreeActive)
    }

    /// Двойное нажатие приходит уже после того, как первое запустило сессию.
    ///
    /// Начать новую в этот момент нельзя — она не прошла бы проверку на
    /// свободное состояние, и режим без удержания остался бы недостижим.
    func testДвойноеНажатиеПоверхИдущейСессииПереводитЕёВРежимБезУдержания() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertFalse(state.isHandsFreeActive)

        monitor.onDoubleTap?()

        XCTAssertTrue(state.isHandsFreeActive)
        XCTAssertTrue(monitor.isHandsFreeActive, "монитору нужно знать режим, иначе следующее нажатие начнёт новую диктовку вместо остановки")
    }

    func testEscapeВПокоеНичегоНеОтменяет() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        // Пока диктовки нет, Escape — обычная клавиша чужого приложения.
        monitor.onEscape?()

        XCTAssertEqual(state.dictationState, .idle)
        let aborts = await capture.abortCount
        XCTAssertEqual(aborts, 0)
    }

    func testEscapeВоВремяДиктовкиОтменяетЕё() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()

        monitor.onEscape?()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Настройки

    func testУспешнаяДиктовкаЗапоминаетсяИПравкаУчитСловарь() async throws {
        try installModelMarker()
        harness.transcription.text = "Открой поуст герз и проверь индексы"
        let state = makeState()
        await state.refreshModelState()

        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let last = try XCTUnwrap(state.lastDictation)
        XCTAssertTrue(last.insertedText.contains("поуст герз"))

        // Человек поправил термин — словарь выучил ровно эту пару.
        let learned = state.learnCorrections(
            editedText: last.insertedText.replacingOccurrences(of: "поуст герз", with: "Postgres")
        )

        XCTAssertEqual(learned, 1)
        XCTAssertTrue(state.replacements.contains { $0.spoken == "поуст герз" && $0.written == "Postgres" })

        // Повторная та же правка не плодит дубликатов.
        XCTAssertEqual(state.learnCorrections(
            editedText: last.insertedText.replacingOccurrences(of: "поуст герз", with: "Postgres")
        ), 0)
    }

    func testОбучениеНаПравкахПоУмолчаниюВыключено() {
        let state = makeState()

        XCTAssertFalse(
            state.learnFromEdits,
            """
            Обучение на правках перечитывает через Accessibility содержимое поля \
            ЧУЖОГО приложения. Пока оно включено по умолчанию, обещание «читаем ровно \
            bundle id — не экран, не содержимое» ложное. Включать это вправе только человек.
            """
        )
    }

    func testОбучениеНаПравкахСохраняетсяИПереживаетПерезапуск() {
        let state = makeState()

        state.learnFromEdits = true
        XCTAssertTrue(harness.defaults.bool(forKey: AppState.learnFromEditsKey))

        // «Перезапуск»: новый AppState с теми же defaults.
        XCTAssertTrue(makeState().learnFromEdits, "Осознанный выбор человека не должен сбрасываться")

        state.learnFromEdits = false
        XCTAssertFalse(makeState().learnFromEdits)
    }

    /// Выключенный тумблер обязан означать «поле не читается», а не «прочитали и промолчали».
    ///
    /// Разница видна только снаружи: у наблюдателя нет наблюдаемого следа, кроме
    /// самого обращения к полю. Поэтому считаем захваты, а не результат.
    func testВыключенноеОбучениеНеЧитаетЧужоеПоле() async throws {
        try installModelMarker()
        harness.transcription.text = "Открой поуст герз"
        let state = makeState()
        state.learnFromEdits = false
        await state.refreshModelState()

        try await dictateOnce(state)

        XCTAssertEqual(
            harness.focusedField.captured, 0,
            "Тумблер выключен — приложение не имеет права заглядывать в чужое поле"
        )
    }

    /// Положительный контроль к предыдущему тесту: без него он пройдёт и на
    /// сломанной проводке, где поле не читается никогда.
    func testВключённоеОбучениеЧитаетПолеОдинРаз() async throws {
        try installModelMarker()
        harness.transcription.text = "Открой поуст герз"
        let state = makeState()
        state.learnFromEdits = true
        await state.refreshModelState()

        try await dictateOnce(state)

        XCTAssertEqual(harness.focusedField.captured, 1)
    }

    /// Одна полная диктовка: нажали, дождались записи, отпустили, дождались вставки.
    private func dictateOnce(_ state: AppState) async throws {
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try XCTUnwrap(state.lastDictation)
    }

    func testЯзыкРаспознаванияСохраняетсяИПереживаетПерезапуск() {
        let state = makeState()
        XCTAssertNil(state.recognitionLanguage, "По умолчанию — автоопределение")

        state.recognitionLanguage = "en"
        XCTAssertEqual(harness.defaults.string(forKey: AppState.recognitionLanguageKey), "en")

        // «Перезапуск»: новый AppState с теми же defaults.
        let restarted = makeState()
        XCTAssertEqual(restarted.recognitionLanguage, "en")

        // Возврат к автоопределению убирает ключ, а не пишет пустую строку.
        restarted.recognitionLanguage = nil
        XCTAssertNil(harness.defaults.string(forKey: AppState.recognitionLanguageKey))
    }

    func testСменаКлавишиДоходитДоМонитораИСохраняется() {
        let state = makeState()

        state.hotkey = .leftControl

        XCTAssertEqual(monitor.hotkey, .leftControl)
        XCTAssertEqual(defaults.string(forKey: "hotkey"), "leftControl")
        XCTAssertEqual(makeState().hotkey, .leftControl)
    }

    func testПредупреждениеПоказываетсяТолькоДляFn() {
        defaults.set(1, forKey: "AppleFnUsageType")
        let state = makeState()

        XCTAssertNil(state.hotkeyWarning)

        state.hotkey = .fn

        XCTAssertNotNil(state.hotkeyWarning)
    }

    // MARK: - Словарь

    func testСловарьСохраняетсяИПереживаетПерезапуск() {
        let state = makeState()

        state.addReplacement(spoken: "сентри", written: "Sentry")

        XCTAssertEqual(state.replacements.map(\.written), ["Sentry"])
        XCTAssertEqual(makeState().replacements.map(\.written), ["Sentry"])
    }

    func testПустыеПоляНеДобавляются() {
        let state = makeState()

        state.addReplacement(spoken: "   ", written: "Sentry")
        state.addReplacement(spoken: "сентри", written: " ")

        XCTAssertEqual(state.replacements, [])
    }

    /// Непрочитанный словарь блокирует запись целиком.
    ///
    /// Раньше он превращался в пустой массив, и первая же правка перезаписывала
    /// им ключ: человек терял всё накопленное молча и необратимо.
    func testНепрочитанныйСловарьНеПерезаписывается() async {
        let broken = "{это не json"
        defaults.set(Data(broken.utf8), forKey: "replacements")

        let state = makeState()
        XCTAssertFalse(state.isDictionaryEditable)
        XCTAssertNotNil(state.dictionaryProblem)

        state.addReplacement(spoken: "сентри", written: "Sentry")

        XCTAssertEqual(state.replacements, [])
        XCTAssertEqual(
            defaults.data(forKey: "replacements").map { String(decoding: $0, as: UTF8.self) },
            broken,
            "исходные данные обязаны остаться на месте"
        )
    }

    func testПроНепрочитанныйСловарьГоворятСразу() async {
        defaults.set(Data("{это не json".utf8), forKey: "replacements")

        _ = makeState()
        // Сообщение показывается задачей, поэтому даём ей дойти до оверлея.
        try? await Task.sleep(for: .milliseconds(100))

        let notices = await overlay.notices
        XCTAssertTrue(notices.contains { $0.message.contains("replacement dictionary") })
    }

    func testСловарьИзБудущегоНеТрогается() {
        let future = #"{"version": 99, "items": []}"#
        defaults.set(Data(future.utf8), forKey: "replacements")

        let state = makeState()
        state.addStarterDictionary()

        XCTAssertFalse(state.isDictionaryEditable)
        XCTAssertEqual(
            defaults.data(forKey: "replacements").map { String(decoding: $0, as: UTF8.self) },
            future
        )
    }

    func testУдалениеЗаменыСохраняется() {
        let state = makeState()
        state.addReplacement(spoken: "сентри", written: "Sentry")
        state.addReplacement(spoken: "деплой", written: "deploy")

        state.removeReplacements(at: IndexSet(integer: 0))

        XCTAssertEqual(state.replacements.map(\.written), ["deploy"])
        XCTAssertEqual(makeState().replacements.map(\.written), ["deploy"])
    }

    func testНаборТерминовДобавляетсяОдинРаз() {
        let state = makeState()
        let available = state.availableStarterCount
        XCTAssertGreaterThan(available, 0)

        state.addStarterDictionary()

        XCTAssertEqual(state.replacements.count, available)
        XCTAssertEqual(state.availableStarterCount, 0)
    }

    // MARK: - Уборка

    /// Записи, уцелевшие после падения приложения, становятся явным Retry/Delete.
    func testЗапускИмпортируетБрошенныеЗаписиВRecovery() async throws {
        let paths = AppPaths(root: root)
        let orphan = try paths.takes().appending(path: "take-старая.wav")
        try writeAbandonedTestWAV(to: orphan)

        let state = makeState()
        for _ in 0..<40 where state.recoveredRecording == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertNotNil(state.recoveredRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.recoveredRecording?.path ?? ""))
        let repaired = try Data(contentsOf: XCTUnwrap(state.recoveredRecording))
        let payloadSize = repaired[40..<44].withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
        XCTAssertEqual(payloadSize, 3200)
    }
}

/// Спасённый текст остаётся только в памяти с Copy/Retry.
@MainActor
final class RecoveredFileTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func settle(_ iterations: Int = 30) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testПослеНеудачнойВставкиТекстДоступенВПамяти() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        XCTAssertNil(state.recoveredText, "Пока ничего не спасали, показывать нечего")

        await harness.inserter.setError(.accessibilityPermissionDenied)

        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()

        XCTAssertEqual(state.recoveredText, "Проверка связи")
    }

    func testНоваяОтменённаяДиктовкаНеТеряетСпасённыйТекст() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        XCTAssertNotNil(state.recoveredText)

        await harness.inserter.setError(nil)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onEscape?()
        await settle()

        XCTAssertEqual(state.recoveredText, "Проверка связи")
    }

    func testСпасённыйТекстУдаляетсяТолькоЯвно() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        XCTAssertEqual(state.recoveredText, "Проверка связи")

        state.deleteRecoveredText()

        XCTAssertNil(state.recoveredText)
    }

    func testДваRetryТекстаВставляютЕгоОдинРаз() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        await harness.inserter.setError(nil)

        state.retryRecoveredText()
        state.retryRecoveredText()
        await settle()

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Проверка связи"])
        XCTAssertNil(state.recoveredText)
    }
}

/// Живой предпросмотр и сохранённый язык распознавания.
@MainActor
final class LivePreviewToggleTests: XCTestCase {
    /// Движок, запоминающий команды предпросмотра.
    private final class PreviewEngine: ASREngineAdapting, LivePreviewCapable, @unchecked Sendable {
        private let lock = NSLock()
        private var _stops = 0
        var stopCount: Int { lock.withLock { _stops } }

        func loadModels(from directory: URL) async throws {}
        func transcribe(samples: [Float]) async throws -> ASRResult {
            ASRResult(text: "", audioDuration: 0, processingDuration: 0)
        }
        func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult {
            ASRResult(text: "", audioDuration: 0, processingDuration: 0)
        }
        func unload() async {}
        func startPreview(
            onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
        ) async throws {}
        func feedPreview(samples: [Float]) async {}
        func stopPreview() async { lock.withLock { _stops += 1 } }
    }

    func testВыключениеГалочкиОстанавливаетПредпросмотрНемедленно() async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        let engine = PreviewEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()
        XCTAssertTrue(state.showLivePreview, "По умолчанию предпросмотр включён")

        state.showLivePreview = false

        // Остановка уходит асинхронной задачей — ждём опросом, не сном.
        for _ in 0..<200 where engine.stopCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(
            engine.stopCount, 1,
            "Человек снял галочку, чтобы предпросмотр погас сейчас, а не при следующей смене состояния"
        )
    }

    func testНезнакомыйСохранённыйЯзыкЧитаетсяКакАвтоопределение() throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        harness.defaults.set("xx-not-a-language", forKey: AppState.recognitionLanguageKey)

        let state = harness.makeState()

        XCTAssertNil(
            state.recognitionLanguage,
            "Код, которого движок не знает, ронял бы каждую диктовку и копил WAV в спасении"
        )
    }

    func testЗнакомыйСохранённыйЯзыкПереживаетПерезапуск() throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        harness.defaults.set("ru", forKey: AppState.recognitionLanguageKey)

        let state = harness.makeState()

        XCTAssertEqual(state.recognitionLanguage, "ru")
    }
}

/// Правка словаря доезжает до акустического подсказчика без перезапуска.
@MainActor
final class VocabularyRebuildTests: XCTestCase {
    /// Движок, считающий пересборки подсказчика.
    private final class RebuildCountingEngine: ASREngineAdapting, VocabularyBoostCapable, @unchecked Sendable {
        private let lock = NSLock()
        private var _prepares = 0
        private var _lastTermCount = -1
        var prepares: Int { lock.withLock { _prepares } }
        var lastTermCount: Int { lock.withLock { _lastTermCount } }

        func loadModels(from directory: URL) async throws {}
        func transcribe(samples: [Float]) async throws -> ASRResult {
            ASRResult(text: "", audioDuration: 0, processingDuration: 0)
        }
        func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult {
            ASRResult(text: "", audioDuration: 0, processingDuration: 0)
        }
        func unload() async {}
        func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws {
            lock.withLock {
                _prepares += 1
                _lastTermCount = boost.terms.count
            }
        }
    }

    func testПравкаСловаряПересобираетПодсказчикСразу() async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        try harness.installModelMarker()
        let engine = RebuildCountingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        // Дождаться прогрева — первая подготовка подсказчика происходит там.
        for _ in 0..<400 where !state.isEngineReady {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(state.isEngineReady, "Прогрев обязан пройти")
        let after = engine.prepares

        state.addReplacement(spoken: "сентри", written: "Sentry")

        for _ in 0..<400 where engine.prepares == after {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(
            engine.prepares, after,
            "Текстовая замена работает сразу — акустика не имеет права ждать перезапуска"
        )
    }
}
