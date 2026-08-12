import AppKit
import AVFoundation
import DictationCore
import Darwin
import LocalASR
import XCTest

/// Жизнь приложения между диктовками.
///
/// Оно неделями сидит в строке меню и ничего не делает. Всё, что оно делает в
/// это время, — чистые издержки, а всё, чего оно не делает при пробуждении
/// компьютера или отключении наушников, — застрявшая диктовка с включённым
/// микрофоном.
@MainActor
final class AppStateIdleTests: XCTestCase {
    private var harness: AppHarness!

    private var monitor: FakeHotkeyMonitor { harness.monitor }
    private var capture: FakeCapture { harness.capture }
    private var overlay: FakeOverlay { harness.overlay }

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    // MARK: - Опрос разрешений

    /// Опрос идёт и когда всё выдано — так решено сознательно: отзыв доступа не
    /// присылает события, а молчащая клавиша неотличима от поломки. Подробности
    /// решения — в шапке `PermissionPollPolicy`.
    func testОпросИдётДажеКогдаВсёВыдано() {
        harness.permissionPollInterval = 1

        let state = harness.makeState()

        XCTAssertEqual(state.permissionPollingInterval, 1)
        XCTAssertTrue(state.isPollingPermissions)
    }

    /// Пока разрешения нет, человек стоит в системных настройках и ждёт, что
    /// экран отзовётся.
    func testПокаРазрешенияНетОпросЧастый() {
        harness.permissionPollInterval = 1
        harness.permissions.microphoneGranted = false

        let state = harness.makeState()

        XCTAssertEqual(state.permissionPollingInterval, 1)
    }

    func testВыданноеРазрешениеСразуЗамедляетОпрос() {
        harness.permissionPollInterval = 1
        harness.permissions.accessibilityGranted = false
        let state = harness.makeState()
        XCTAssertEqual(state.permissionPollingInterval, 1)

        harness.permissions.accessibilityGranted = true
        state.refreshPermissions()

        XCTAssertEqual(state.permissionPollingInterval, 1)
    }

    func testОпросМожноВыключитьСовсем() {
        harness.permissionPollInterval = 0

        let state = harness.makeState()

        XCTAssertEqual(state.permissionPollingInterval, 0)
        XCTAssertFalse(state.isPollingPermissions)
    }

    // MARK: - Таймеры в покое

    func testВПокоеПределДлительностиНеТикает() async throws {
        let state = try await makeReadyState()
        XCTAssertFalse(state.isCountingDuration)

        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }
        XCTAssertTrue(state.isCountingDuration, "предел в час проверять нечем")

        monitor.onRelease?()
        try await waitFor("диктовка закончилась") { state.dictationState == .idle }

        XCTAssertFalse(state.isCountingDuration, "таймер продолжает будить процесс после диктовки")
    }

    // MARK: - Микрофон

    /// Прямое обещание продукта: индикатор записи гаснет, когда мы не слушаем.
    func testПослеОбычнойДиктовкиМикрофонВыключен() async throws {
        let state = try await makeReadyState()

        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }
        monitor.onRelease?()
        try await waitFor("диктовка закончилась") { state.dictationState == .idle }

        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    func testПослеОтменыМикрофонВыключен() async throws {
        let state = try await makeReadyState()

        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }
        monitor.onEscape?()
        try await waitFor("диктовка отменена") { state.dictationState == .idle }

        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    // MARK: - Сон и пробуждение

    /// Mac уснул посреди диктовки.
    ///
    /// Отпускание клавиши, случившееся во сне, до нас не дойдёт. Без остановки
    /// сессия остаётся в «слушаю» навсегда: микрофон включён, индикатор записи
    /// горит, и выйти из этого можно только через Escape.
    func testСонПосредиЗаписиЕёЗаканчивает() async throws {
        let state = try await makeReadyState()
        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        try await waitFor("диктовка закончилась") { state.dictationState == .idle }
        let recording = await capture.isRecording
        XCTAssertFalse(recording, "микрофон остался включённым на спящей машине")
    }

    /// Записанное до сна не выбрасывается: человек это уже сказал.
    func testСонОстанавливаетЗаписьЧерезРаспознавание() async throws {
        let state = try await makeReadyState()
        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitFor("диктовка закончилась") { state.dictationState == .idle }

        let stops = await capture.stopCount
        let aborts = await capture.abortCount
        XCTAssertEqual(stops, 1, "запись оборвали вместо того, чтобы дописать её на диск")
        XCTAssertEqual(aborts, 0)
        XCTAssertEqual(state.lastNotice?.kind, .info)
        XCTAssertEqual(state.lastNotice?.message.contains("sleep"), true)

        // Объяснение обязано дойти до экрана. Сказанное посреди остановки его
        // не достигает: ядро тут же перерисовывает панель под «распознаю».
        try await waitFor("объяснение дошло до панели") {
            await self.overlay.notices.contains { $0.message.contains("sleep") }
        }
    }

    /// Сон посреди диктовки без удержания клавиши.
    ///
    /// В этом режиме отпускание клавиши ничего не значит: запись идёт до
    /// следующего нажатия. Остановить её обычным путём нельзя — обращение
    /// пройдёт мимо, и микрофон останется включённым до часового предела.
    func testСонПосредиДиктовкиБезУдержанияТожеЕёЗаканчивает() async throws {
        let state = try await makeReadyState()
        monitor.onDoubleTap?()
        try await waitFor("началась запись") { state.dictationState == .listening }
        XCTAssertTrue(state.isHandsFreeActive)

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        try await waitFor("диктовка закончилась") { state.dictationState == .idle }
        let recording = await capture.isRecording
        XCTAssertFalse(recording, "запись без удержания пережила сон компьютера")
    }

    /// Сон застал приложение до первого кадра звука — записывать было нечего.
    func testСонДоНачалаЗаписиПростоОтменяетСессию() async throws {
        let state = try await makeReadyState()
        monitor.onPress?()
        XCTAssertEqual(state.dictationState, .preparing)

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        try await waitFor("сессия закрыта") { state.dictationState == .idle }
        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    func testСонВПокоеНичегоНеТрогает() async throws {
        let state = try await makeReadyState()

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertNil(state.lastNotice)
        let starts = await capture.startCount
        XCTAssertEqual(starts, 0)
    }

    /// После пробуждения слежение начинается заново.
    ///
    /// Клавишу за время сна успели отпустить, а события об этом не было:
    /// монитор до сих пор считает её зажатой и следующее нажатие проглотит.
    func testПробуждениеПерезапускаетСлежениеЗаКлавишей() async throws {
        let state = harness.makeState()
        XCTAssertTrue(monitor.isRunning)
        let stopsBefore = monitor.stopCount

        harness.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitFor("слежение перезапущено") { self.monitor.stopCount > stopsBefore }

        XCTAssertTrue(monitor.isRunning, "после пробуждения клавиша перестала слушаться")
        XCTAssertTrue(state.accessibilityGranted)
    }

    // MARK: - Смена аудиоустройства

    /// Наушники вынули посреди фразы.
    ///
    /// Движок остаётся запущенным, но кадры в него больше не приходят: человек
    /// говорит в тишину и узнал бы об этом только по пустому результату.
    /// Запись длиннее предела распознавания — иначе спасать нечего.
    func testСменаМикрофонаПосредиЗаписиЕёЗаканчивает() async throws {
        let state = try await makeReadyState(recordingDuration: 2)
        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }

        harness.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)

        try await waitFor("диктовка закончилась") { state.dictationState == .idle }
        try await waitFor("WAV доступна для Retry") { state.recoveredRecording != nil }
        XCTAssertEqual(state.lastNotice?.kind, .failure)
        XCTAssertEqual(state.lastNotice?.message.contains("audio device was disconnected"), true)
        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    /// После disconnect распознавание не запускается на обрезанном аудио.
    func testСменаМикрофонаНеЗапускаетASRНаОбрезаннойЗаписи() async throws {
        harness.transcription.error = ASREngineError.modelsNotLoaded
        let state = try await makeReadyState(recordingDuration: 2)
        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }

        harness.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await waitFor("диктовка закончилась") { state.dictationState == .idle }

        let notices = await overlay.notices
        XCTAssertTrue(
            notices.contains { $0.message.contains("audio device was disconnected") },
            "нужна точная причина остановки"
        )
        XCTAssertFalse(
            notices.contains { $0.message.contains("transcribe") },
            "после disconnect ASR не должен запускаться"
        )
    }

    /// Устройства меняются и просто так: подключили монитор, ушли наушники в
    /// сон. Пока мы не слушаем, это не наше дело.
    func testСменаМикрофонаВПокоеНичегоНеПоказывает() async throws {
        let state = try await makeReadyState()

        harness.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(state.lastNotice)
        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Загрузка модели

    /// Открытые настройки не должны стирать идущую загрузку.
    ///
    /// Вкладка «Модель» осматривает диск при появлении. Метки готовности во
    /// время загрузки ещё нет, поэтому осмотр объявлял модель неустановленной —
    /// и человек, зашедший посмотреть на прогресс, видел вместо него кнопку
    /// «Скачать модель».
    func testОсмотрДискаНеСтираетИдущуюЗагрузку() async throws {
        let state = harness.makeState()
        state.installModel()
        try await waitFor("загрузка началась") {
            if case .downloading = state.modelState { return true }
            return false
        }

        await state.refreshModelState()

        guard case .downloading = state.modelState else {
            XCTFail("осмотр диска стёр идущую загрузку: \(state.modelState)")
            return
        }

        harness.downloader.release()
        try await waitFor("загрузка закончилась") { state.modelState == .notInstalled }
    }

    // MARK: - Многие циклы подряд

    /// Двести диктовок подряд.
    ///
    /// Приложение живёт неделями, и утечка размером в один объект на диктовку
    /// не видна ни на второй, ни на десятой.
    func testМногиеЦиклыДиктовкиНеНакапливаютПамятьИРесурсы() async throws {
        let state = try await makeReadyState()

        // Прогрев: первые круги поднимают внутренние буферы и кэши, и без него
        // их разовая цена выглядела бы утечкой.
        for _ in 0..<20 { try await runCycle(state) }
        let before = residentBytes()

        for _ in 0..<200 { try await runCycle(state) }

        let after = residentBytes()
        let grown = after > before ? after - before : 0
        XCTAssertLessThan(
            grown,
            4 * 1024 * 1024,
            "за 200 диктовок приложение выросло на \(grown / 1024) КБ"
        )

        // Каждая начатая запись обязана быть закрытой — иначе микрофон остался
        // бы включённым, а число невидимо разъехалось бы.
        let starts = await capture.startCount
        let stops = await capture.stopCount
        let aborts = await capture.abortCount
        XCTAssertEqual(starts, 220)
        XCTAssertEqual(stops + aborts, starts)

        XCTAssertFalse(state.isCountingDuration)
        XCTAssertEqual(state.dictationState, .idle)
    }

    /// После работы приложение целиком отпускается.
    ///
    /// Замыкания краёв системы держат его слабо; стоит одному из них взяться за
    /// него крепко — и живым остаётся всё: контроллер, захват, таймеры.
    func testПослеЦикловСостояниеПриложенияОсвобождается() async throws {
        weak var weakState: AppState?

        try await autoreleasepoolAsync {
            let state = try await makeReadyState()
            weakState = state
            for _ in 0..<5 { try await runCycle(state) }
        }

        // Хвосты задач держат состояние ещё мгновение после выхода из области.
        try await waitFor("состояние освобождено") { weakState == nil }
        XCTAssertNil(weakState)
    }

    // MARK: - Вспомогательное

    /// Приложение с выданными разрешениями и разложенной моделью.
    ///
    /// Длительность записи ниже предела — сессия закрывается, не заходя в
    /// распознавание: настоящей модели на диске всё равно нет.
    private func makeReadyState(recordingDuration: TimeInterval = 0.1) async throws -> AppState {
        try harness.installModelMarker()
        await capture.setDuration(recordingDuration)
        let state = harness.makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.isDictationReady)
        return state
    }

    private func runCycle(_ state: AppState) async throws {
        monitor.onPress?()
        try await waitFor("началась запись") { state.dictationState == .listening }
        monitor.onRelease?()
        try await waitFor("диктовка закончилась") { state.dictationState == .idle }
    }

    private func waitFor(
        _ what: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("не дождались: \(what)", file: file, line: line)
    }

    /// Сколько памяти занято процессом прямо сейчас.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// `autoreleasepool` не пропускает через себя `await`, поэтому область
    /// жизни объекта здесь задаётся обычной функцией.
    private func autoreleasepoolAsync(_ body: () async throws -> Void) async rethrows {
        try await body()
    }
}
