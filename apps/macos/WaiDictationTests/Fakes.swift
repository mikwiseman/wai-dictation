import AppKit
import DictationAudio
import DictationCore
import Foundation
import LocalASR

/// Собственный crash-WAV: payload уже сброшен на диск, а размеры в header ещё
/// нулевые, потому что process не дошёл до `WAVWriter.close()`.
func writeAbandonedTestWAV(to url: URL, sampleBytes: Int = 3200) throws {
    var data = Data()
    func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    u32(36)
    data.append(contentsOf: "WAVEfmt ".utf8)
    u32(16)
    u16(1)
    u16(1)
    u32(16_000)
    u32(32_000)
    u16(2)
    u16(16)
    data.append(contentsOf: "data".utf8)
    u32(0)
    data.append(Data(repeating: 7, count: sampleBytes))
    try data.write(to: url)
}

// Подставные края системы.
//
// Исходники приложения компилируются прямо в тестовый бандл, поэтому импорта
// приложения здесь нет: всё лежит в одном модуле.

/// Общий журнал вызовов.
///
/// Нужен там, где важен порядок между разными краями: например, фокус обязан
/// вернуться раньше, чем мы тронем буфер обмена.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(entry)
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Источник событий клавиатуры

@MainActor
final class FakeHotkeyEventSource: HotkeyEventSource {
    var isTrusted = true
    /// Отдавать ли токен подписки. `false` — система отказала.
    var grantsFlagsMonitor = true
    var grantsKeyMonitor = true

    private(set) var flagsMonitorCount = 0
    private(set) var keyMonitorCount = 0
    private(set) var removedTokens: [String] = []

    private var flagsHandler: (@MainActor (HotkeyEvent) -> Void)?
    private var keyHandler: (@MainActor (HotkeyEvent) -> Void)?

    /// Сколько подписок сейчас живо.
    var liveMonitorCount: Int {
        flagsMonitorCount + keyMonitorCount - removedTokens.count
    }

    func addFlagsMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        guard grantsFlagsMonitor else { return nil }
        flagsMonitorCount += 1
        flagsHandler = handler
        return "flags-\(flagsMonitorCount)"
    }

    func addKeyDownMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        guard grantsKeyMonitor else { return nil }
        keyMonitorCount += 1
        keyHandler = handler
        return "keys-\(keyMonitorCount)"
    }

    func removeMonitor(_ token: Any) {
        removedTokens.append(token as? String ?? "?")
    }

    /// Прислать событие модификаторов, как это сделала бы система.
    func sendFlags(_ event: HotkeyEvent) {
        flagsHandler?(event)
    }

    func sendKeyDown(_ event: HotkeyEvent) {
        keyHandler?(event)
    }
}

// MARK: - Края вставки текста

/// Подставные края системы для вставки.
///
/// Класс с замком, а не актор: методы `InputSystem` синхронные — так их и
/// вызывает вставка, — а синхронно к актору не обратиться.
final class FakeInputSystem: InputSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var secureInput = false
    private var trusted = true
    private var frontmost: TargetApplication?
    private var activateResult = true
    /// Что вернёт `heldModifiers()` на каждом обращении. Последний элемент
    /// повторяется дальше.
    private var heldPlan: [CGEventFlags] = [[]]
    private var heldCalls = 0
    private var postError: TextInsertionError?
    private var posted: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []

    let log: CallLog

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    // MARK: Настройка

    func setSecureInput(_ value: Bool) { withLock { secureInput = value } }
    func setTrusted(_ value: Bool) { withLock { trusted = value } }
    func setFrontmost(_ value: TargetApplication?) { withLock { frontmost = value } }
    func setActivateResult(_ value: Bool) { withLock { activateResult = value } }
    func setHeldPlan(_ plan: [CGEventFlags]) { withLock { heldPlan = plan.isEmpty ? [[]] : plan } }
    func setPostError(_ error: TextInsertionError?) { withLock { postError = error } }

    // MARK: Наблюдение

    var postedKeys: [(keyCode: CGKeyCode, flags: CGEventFlags)] { withLock { posted } }
    var heldModifiersCallCount: Int { withLock { heldCalls } }

    // MARK: InputSystem

    var isSecureInputEnabled: Bool { withLock { secureInput } }
    var isAccessibilityTrusted: Bool { withLock { trusted } }

    func frontmostApplication() -> TargetApplication? { withLock { frontmost } }

    func heldModifiers() -> CGEventFlags {
        withLock {
            let value = heldPlan[min(heldCalls, heldPlan.count - 1)]
            heldCalls += 1
            return value
        }
    }

    func activate(_ target: TargetApplication) async -> Bool {
        log.record("activate")
        return withLock { activateResult }
    }

    func post(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        log.record("post")
        if let error = withLock({ postError }) { throw error }
        withLock { posted.append((keyCode, flags)) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakePasteboard: DictationPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var error: TextInsertionError?
    private var restoreError: TextInsertionError?
    private var transactions: [PasteboardTransaction] = []
    var onBegin: (@Sendable () -> Void)?

    let log: CallLog

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    func setError(_ error: TextInsertionError?) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }

    func setRestoreError(_ error: TextInsertionError?) {
        lock.lock()
        defer { lock.unlock() }
        restoreError = error
    }

    var writtenTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func beginHostOnlyWrite(_ text: String) throws -> PasteboardTransaction {
        log.record("pasteboard")
        lock.lock()
        let failure = error
        if failure == nil { written.append(text) }
        lock.unlock()
        if let failure { throw failure }
        let transaction = PasteboardTransaction()
        lock.lock()
        transactions.append(transaction)
        lock.unlock()
        onBegin?()
        return transaction
    }

    func restore(_ transaction: PasteboardTransaction) throws {
        log.record("restore")
        lock.lock()
        transactions.removeAll { $0 == transaction }
        let failure = restoreError
        lock.unlock()
        if let failure { throw failure }
    }
}

// MARK: - Края диктовки

actor FakeCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    /// Слышит ли микрофон прямо сейчас.
    ///
    /// На этом держится обещание «индикатор записи гаснет, когда мы не слушаем»:
    /// проверять его надо не по состоянию на экране, а по тому, закрыт ли захват.
    private(set) var isRecording = false
    /// Что вернуть как длительность записи.
    ///
    /// Короче предела — и сессия закончится без распознавания. Так проверяется
    /// полный круг диктовки, не трогая настоящую модель.
    private var duration: TimeInterval = 2.0

    private let file = FileManager.default.temporaryDirectory
        .appending(path: "wai-dictation-test-take-\(UUID().uuidString).wav")

    func setDuration(_ value: TimeInterval) { duration = value }

    func startRecording() async throws -> URL {
        startCount += 1
        isRecording = true
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        isRecording = false
        try Data("RIFF-test-audio".utf8).write(to: file, options: .atomic)
        return (file, duration)
    }

    func abortRecording() async {
        abortCount += 1
        isRecording = false
    }
}

actor FakeInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    nonisolated(unsafe) var frontmost: TargetApplication?
    /// Чем отказать. Отказ вставки — не редкость: защищённый ввод, отозванный
    /// доступ, закрывшееся окно получателя.
    private var error: TextInsertionError?

    func setError(_ error: TextInsertionError?) { self.error = error }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if let error { throw error }
        insertedTexts.append(text)
    }

    func pressReturn() async throws { returnPresses += 1 }

    nonisolated func frontmostApplication() -> TargetApplication? { frontmost }
}

actor FakeOverlay: OverlayPresenting {
    private(set) var presentedStates: [DictationState] = []
    private(set) var notices: [DictationNotice] = []
    private(set) var dismissCount = 0

    func present(_ state: DictationState, elapsed: TimeInterval) async {
        presentedStates.append(state)
    }

    func dismiss() async { dismissCount += 1 }

    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

// MARK: - Разрешения и монитор клавиши

@MainActor
final class FakePermissions: PermissionReading {
    var accessibilityGranted: Bool
    var microphoneGranted: Bool

    init(accessibility: Bool = true, microphone: Bool = true) {
        accessibilityGranted = accessibility
        microphoneGranted = microphone
    }
}

@MainActor
final class FakeAccessibilityManager: AccessibilityManaging {
    var requestResult = false
    var resetError: Error?
    var relaunchError: Error?

    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0
    private(set) var revealApplicationCount = 0
    private(set) var resetCount = 0
    private(set) var relaunchCount = 0

    func requestAccess() -> Bool {
        requestCount += 1
        return requestResult
    }

    func openSettings() {
        openSettingsCount += 1
    }

    func revealApplication() {
        revealApplicationCount += 1
    }

    func resetAccess() async throws {
        resetCount += 1
        if let resetError { throw resetError }
    }

    func relaunchApplication() async throws {
        relaunchCount += 1
        if let relaunchError { throw relaunchError }
    }
}

// MARK: - Приложение целиком

/// Подставное окружение приложения.
///
/// Собрано в одном месте, чтобы разные наборы проверок не разъезжались в том,
/// каким приложение видит компьютер. Центры уведомлений здесь свои, не
/// системные: проверка не должна ни слышать настоящий сон машины, ни будить
/// чужих подписчиков.
@MainActor
final class AppHarness {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let permissions = FakePermissions()
    let accessibilityManager = FakeAccessibilityManager()
    let monitor = FakeHotkeyMonitor()
    let overlay = FakeOverlay()
    let capture = FakeCapture()
    let inserter = FakeInserter()
    let workspaceNotifications = NotificationCenter()
    let notifications = NotificationCenter()
    let downloader = BlockingModelDownloader()

    /// Ноль — опрос разрешений выключен: в проверке они меняются нами, а не
    /// системой.
    var permissionPollInterval: TimeInterval = 0

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(
                path: "wai-dictation-harness-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        suiteName = "is.waiwai.dictation.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.defaults = defaults

        Self.sweepStaleTestDomains(except: suiteName)
    }

    /// Подмести файлы настроек, оставшиеся от прошлых прогонов.
    ///
    /// Уборка в конце теста забирает не всё: служба настроек выписывает
    /// опустевший файл на диск уже после того, как тест закончился, и успеть за
    /// ней нельзя. Поэтому подметаем в начале — к этому моменту всё прошлое уже
    /// дописано. Без этого каждый прогон оставлял по паре десятков файлов в
    /// личной папке разработчика, и за время работы их накопилось под тысячу.
    private static func sweepStaleTestDomains(except current: String) {
        guard let library = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let preferences = library.appending(path: "Preferences", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: preferences,
            includingPropertiesForKeys: nil
        ) else { return }

        let prefix = "is.waiwai.dictation.tests."
        for entry in entries
        where entry.lastPathComponent.hasPrefix(prefix)
            && entry.lastPathComponent != "\(current).plist" {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        // Домен убран из настроек, но файл остаётся: служба настроек всё равно
        // выпишет опустевший plist на диск. Один прогон — один файл; за время
        // работы над проектом их накопилось под тысячу. Убираем и файл тоже.
        if let preferences = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let file = preferences
                .appending(path: "Preferences", directoryHint: .isDirectory)
                .appending(path: "\(suiteName).plist", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Что «услышит» распознавание. Настоящей модели в тесте нет, а без ответа
    /// диктовка обрывалась бы на полпути и путь до вставки остался бы непроверенным.
    let transcription = FakeTranscription()

    /// Движок для прогрева. Обычным проверкам он не нужен: без него прогрев
    /// считается пройденным. Задаётся там, где проверяется сам прогрев.
    var warmUpEngine: (any ASREngineAdapting)?

    func makeState() -> AppState {
        AppState(
            environment: AppEnvironment(
                defaults: defaults,
                paths: AppPaths(root: root),
                permissions: permissions,
                accessibilityManager: accessibilityManager,
                hotkeyMonitor: monitor,
                inserter: inserter,
                overlay: overlay,
                makeCapture: { [capture] _, _, _ in capture },
                transcribe: { [transcription] _, _ in
                    { _ in
                        if let delay = transcription.delay {
                            try await Task.sleep(for: delay)
                        }
                        if let error = transcription.error { throw error }
                        return ASRResult(
                            text: transcription.text,
                            audioDuration: 2,
                            processingDuration: 0.05
                        )
                    }
                },
                permissionPollInterval: permissionPollInterval,
                modelDownloader: downloader,
                workspaceNotifications: workspaceNotifications,
                notifications: notifications,
                localTranscriber: warmUpEngine.map { LocalTranscriber(engine: $0) }
            )
        )
    }

    /// Разложить тестовый inventory и метку готовой модели.
    ///
    /// Файлы sparse: логический размер соответствует manifest, но блоки на
    /// диске не занимают 483 МБ. Marker фиксирует тот же size/mtime, который
    /// записывает прошедшая SHA-проверку production-установка.
    func installModelMarker() throws {
        // Продукт считает модель готовой, только когда готовы обе: основная и
        // подсказчик терминов. Тестовая установка кладёт метки обеим.
        try installMarker(for: try ModelManifest.bundled())
        try installMarker(for: try ModelManifest.bundledVocabulary())
    }

    /// Состояние после обновления со сборки без подсказчика: основная модель
    /// стоит, подсказчика нет — проверка сценария добора.
    func installMainModelMarkerOnly() throws {
        try installMarker(for: try ModelManifest.bundled())
    }

    private func installMarker(for manifest: ModelManifest) throws {
        let paths = AppPaths(root: root)
        let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
        try FileManager.default.createDirectory(
            at: layout.engineDirectory,
            withIntermediateDirectories: true
        )
        var installedFiles: [ModelReadyMarker.InstalledFile] = []
        for file in manifest.files {
            let url = layout.engineDirectory.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.byteCount))
            try handle.close()
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            installedFiles.append(
                .init(
                    path: file.path,
                    byteCount: file.byteCount,
                    modifiedAt: values.contentModificationDate
                )
            )
        }
        let marker = ModelReadyMarker(
            manifest: manifest,
            verifiedAt: Date(),
            installedFiles: installedFiles.sorted { $0.path < $1.path }
        )
        try JSONEncoder().encode(marker).write(to: layout.readyMarker)
    }
}

// MARK: - Голос интерфейса

/// Подставной VoiceOver.
///
/// Настоящие объявления уходят в систему и обратно не возвращаются: без этой
/// подмены нельзя проверить ни одного из них, а для незрячего человека они и
/// есть весь интерфейс диктовки.
@MainActor
final class FakeAnnouncer: AccessibilityAnnouncing {
    private(set) var announcements: [(message: String, urgent: Bool)] = []

    var messages: [String] { announcements.map(\.message) }

    func announce(_ message: String, urgent: Bool) {
        announcements.append((message, urgent))
    }

    /// Забыть сказанное. Нужно там, где проверяется одно объявление, а до него
    /// по делу прозвучали другие.
    func reset() {
        announcements = []
    }
}

// MARK: - Загрузка модели

/// Загрузчик, который никуда не идёт и не отпускает, пока не разрешат.
///
/// Нужен, чтобы поймать приложение в состоянии «идёт загрузка» и посмотреть,
/// что с ним в этот момент делают другие экраны.
final class BlockingModelDownloader: ModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false

    var hasStarted: Bool { lock.withLock { started } }

    func release() { lock.withLock { released = true } }

    func download(
        from url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        lock.withLock { started = true }

        onProgress(expectedBytes / 2)

        while !lock.withLock({ released }) {
            try await Task.sleep(for: .milliseconds(5))
        }

        // Отпущенная загрузка заканчивается отменой: доводить установку до
        // проверки сумм здесь не на чем — настоящих файлов модели нет.
        throw ModelDownloadError.cancelled
    }
}

@MainActor
final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onSingleTapWhileHandsFree: (() -> Void)?
    var onAbortShortcut: (() -> Void)?
    var onEscape: (() -> Void)?

    var isHandsFreeActive = false
    private(set) var isRunning = false
    private(set) var hotkey: DictationHotkey?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func setHotkey(_ hotkey: DictationHotkey) { self.hotkey = hotkey }

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}


/// Заранее известный ответ распознавания.
final class FakeTranscription: @unchecked Sendable {
    var text = "Проверка связи"
    var error: (any Error)?
    var delay: Duration?
}

/// Движок, у которого Core ML не поднимается, хотя файлы модели на диске целы.
///
/// Ровно такой отказ случается в жизни: проверка SHA-256 прошла, а загрузка
/// в нейромодуль упала. Осмотр диска это состояние увидеть не может.
final class FailingASREngine: ASREngineAdapting, @unchecked Sendable {
    func loadModels(from directory: URL) async throws {
        throw ASREngineError.modelsUnavailable("Core ML отказал при загрузке")
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
        throw ASREngineError.modelsNotLoaded
    }

    func unload() async {}
}
