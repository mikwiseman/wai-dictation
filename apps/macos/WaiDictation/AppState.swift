import AVFoundation
import AppKit
import ServiceManagement
import DictationAudio
import DictationCore
import Foundation
import LocalASR
import SwiftUI

/// Края системы, из которых собирается приложение.
///
/// Здесь ровно то, что в тесте трогать нельзя: настройки пользователя, папки на
/// диске, выданные разрешения, микрофон, чужие приложения и экран. В приложении
/// подставляются настоящие реализации, в тесте — подставные.
@MainActor
public struct AppEnvironment {
    public var defaults: UserDefaults
    public var paths: AppPaths
    public var permissions: any PermissionReading
    public var accessibilityManager: any AccessibilityManaging
    public var hotkeyMonitor: any HotkeyMonitoring
    public var inserter: any TextInserting
    public var overlay: any OverlayPresenting
    /// Фабрика захвата: папка записей, обработчик сбоя и слушатель живых
    /// отсчётов (для предпросмотра и уровня микрофона).
    public var makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void, @escaping @Sendable ([Float]) -> Void) -> any AudioCapturing
    /// Чем распознавать. Такой же край системы, как микрофон и вставка: в
    /// приложении это модель на диске, в тесте — заранее известный ответ. Без
    /// этого шва путь диктовки целиком в приложении нельзя было проверить
    /// вовсе — тесты доходили только до начала записи.
    /// Фабрика распознавания: папка движка и поставщик подсказки языка.
    /// Подсказка читается на каждый вызов — человек мог сменить язык между
    /// диктовками, и закреплять её при сборке значило бы игнорировать выбор.
    public var transcribe: (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult
    /// Как часто опрашивать разрешения в самом занятом режиме. Ноль — не опрашивать.
    public var permissionPollInterval: TimeInterval
    /// Чем скачивать модель. Единственная сеть, которая есть у приложения.
    public var modelDownloader: any ModelDownloading
    /// Уведомления рабочего стола: сон и пробуждение.
    public var workspaceNotifications: NotificationCenter
    /// Общий центр уведомлений: оттуда приходит смена аудиоустройства.
    public var notifications: NotificationCenter
    /// Единственный production instance движка. В тестах `nil`: там ASR
    /// подставлен через `transcribe` и настоящая модель не нужна.
    public var localTranscriber: LocalTranscriber?

    public init(
        defaults: UserDefaults,
        paths: AppPaths,
        permissions: any PermissionReading,
        accessibilityManager: any AccessibilityManaging,
        hotkeyMonitor: any HotkeyMonitoring,
        inserter: any TextInserting,
        overlay: any OverlayPresenting,
        makeCapture: @escaping (URL, @escaping @Sendable (AudioCaptureError) -> Void, @escaping @Sendable ([Float]) -> Void) -> any AudioCapturing,
        transcribe: @escaping (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult,
        permissionPollInterval: TimeInterval,
        modelDownloader: any ModelDownloading,
        workspaceNotifications: NotificationCenter,
        notifications: NotificationCenter,
        localTranscriber: LocalTranscriber? = nil
    ) {
        self.defaults = defaults
        self.paths = paths
        self.permissions = permissions
        self.accessibilityManager = accessibilityManager
        self.hotkeyMonitor = hotkeyMonitor
        self.inserter = inserter
        self.overlay = overlay
        self.makeCapture = makeCapture
        self.transcribe = transcribe
        self.permissionPollInterval = permissionPollInterval
        self.modelDownloader = modelDownloader
        self.workspaceNotifications = workspaceNotifications
        self.notifications = notifications
        self.localTranscriber = localTranscriber
    }

    /// Настоящие края — то, из чего собирается работающее приложение.
    public static func system() -> AppEnvironment {
        let transcriber = LocalTranscriber()
        return AppEnvironment(
            defaults: .standard,
            paths: .standard(),
            permissions: SystemPermissions(),
            accessibilityManager: SystemAccessibilityManager(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            inserter: TextInserter(),
            overlay: DictationOverlay(),
            makeCapture: { MicrophoneCapture(directory: $0, onFailure: $1, onSamples: $2) },
            transcribe: { engineDirectory, languageHint in
                return { url in
                    try await transcriber.prepare(modelDirectory: engineDirectory)
                    return try await transcriber.transcribe(
                        fileURL: url,
                        languageHint: languageHint()
                    )
                }
            },
            permissionPollInterval: 1,
            modelDownloader: URLSessionModelDownloader(),
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            notifications: .default,
            localTranscriber: transcriber
        )
    }
}

/// Всё состояние приложения в одном месте.
///
/// Связывает горячую клавишу, захват звука, распознавание и вставку. Сама
/// логика диктовки живёт в `DictationController` — здесь только подключение
/// системных краёв и то, что видит интерфейс.
@MainActor
public final class AppState: ObservableObject {
    // Показывается в интерфейсе.
    @Published public private(set) var dictationState: DictationState = .idle
    @Published public private(set) var modelState: ModelState = .notInstalled
    @Published public private(set) var accessibilityGranted = false
    @Published public private(set) var accessibilityState: AccessibilityPermissionState = .denied
    @Published public private(set) var microphoneGranted = false
    @Published public private(set) var lastNotice: DictationNotice?
    @Published public private(set) var isPreparingEngine = false
    @Published public private(set) var isEngineReady = false
    /// Сколько скачает кнопка установки: полный объём или добор после обновления.
    @Published public private(set) var remainingDownloadMegabytes = 586
    /// Язык распознавания: nil — автоопределение по звуку. Код BCP-47 («en»).
    /// Ручной выбор — выход для случая, когда акцент уводит автоопределение
    /// не в тот язык; смешанной речи он противопоказан, поэтому по умолчанию
    /// всегда автоматика.
    @Published public var recognitionLanguage: String? {
        didSet {
            guard oldValue != recognitionLanguage else { return }
            if let recognitionLanguage {
                defaults.set(recognitionLanguage, forKey: Self.recognitionLanguageKey)
            } else {
                defaults.removeObject(forKey: Self.recognitionLanguageKey)
            }
        }
    }

    nonisolated static let recognitionLanguageKey = "recognitionLanguage"

    /// Текст неудачной вставки. Никогда не пишется на диск.
    @Published public private(set) var recoveredText: String?
    /// WAV после технической ошибки, доступный для Retry/Delete.
    @Published public private(set) var recoveredRecording: URL?
    /// Идёт ли запись без удержания клавиши — показывается в меню.
    @Published public private(set) var isHandsFreeActive = false
    /// Только успешная вставка считается пройденной пробой в онбординге.
    @Published public private(set) var successfulDictationCount = 0

    /// Последняя успешная диктовка — только в памяти процесса. Из неё окно
    /// правки учит словарь; на диск текст не попадает никогда.
    public struct LastDictation: Equatable {
        public let insertedText: String
    }
    @Published public private(set) var lastDictation: LastDictation?

    /// Что не так со словарём. Пока не `nil`, словарь заблокирован на запись.
    @Published public private(set) var dictionaryProblem: ReplacementsStore.Problem?

    // Настройки.
    @Published public var hotkey: DictationHotkey {
        didSet {
            guard oldValue != hotkey else { return }
            defaults.set(hotkey.rawValue, forKey: Keys.hotkey)
            hotkeyMonitor.setHotkey(hotkey)
        }
    }

    @Published public var soundsEnabled: Bool {
        didSet {
            guard oldValue != soundsEnabled else { return }
            defaults.set(soundsEnabled, forKey: Keys.sounds)
        }
    }

    /// Словарь замен. Меняется только через методы ниже: прямая запись обошла
    /// бы проверку на то, что словарь вообще можно сохранять.
    @Published public private(set) var replacements: [DictionaryReplacement]

    private enum Keys {
        static let hotkey = "hotkey"
        static let sounds = "soundsEnabled"
        static let replacements = "replacements"
        /// Глобальная настройка macOS: что делает нажатие 🌐.
        static let fnUsage = "AppleFnUsageType"
    }

    /// Маркер переживает relaunch. Если новый процесс всё ещё не trusted,
    /// повторять перезапуск бессмысленно — нужен явный repair старой TCC-записи.
    static let accessibilityRelaunchPendingKey = "accessibilityRelaunchPending"

    private let defaults: UserDefaults
    private let paths: AppPaths
    private let permissions: any PermissionReading
    private let accessibilityManager: any AccessibilityManaging
    private let hotkeyMonitor: any HotkeyMonitoring
    private let inserter: any TextInserting
    private let overlay: any OverlayPresenting
    private let makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void, @escaping @Sendable ([Float]) -> Void) -> any AudioCapturing
    private let transcribe: (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult
    private let permissionPollInterval: TimeInterval
    private let modelDownloader: any ModelDownloading
    private let workspaceNotifications: NotificationCenter
    private let notifications: NotificationCenter
    private let replacementsStore: ReplacementsStore

    /// Обновления. Отдельный объект со своими подписчиками: галочка
    /// автопроверки живёт в настройках Sparkle, а не в наших `defaults`.
    public let updater = SparkleUpdater()

    private var store: ModelStore?
    private var vocabularyStore: ModelStore?
    private var vocabularyDirectory: URL?
    private var mainModelBytes: Int64 = 0
    private var vocabularyModelBytes: Int64 = 0
    private var mainModelFileCount = 0
    private var vocabularyModelFileCount = 0
    private var transcriber: LocalTranscriber?
    private var recordingRecovery: RecordingRecoveryStore?
    private var engineDirectory: URL?
    private var controller: DictationController?
    /// Идёт ли установка модели прямо сейчас.
    private var isInstalling = false
    /// Отказ Core ML при прогреве. Файлы на диске при этом целы, поэтому осмотр
    /// диска отказа не видит — состояние держится здесь до явного восстановления.
    private var engineLoadFailure: String?
    /// Retry/Delete recovery выполняются по одному и блокируют hotkey.
    private var isRecoveryOperationActive = false
    /// Сообщение, которое ждёт конца сессии.
    private var noticeAfterSession: DictationNotice?
    /// Отложенная подсказка «нет звука» — отменяется первым же живым сигналом.
    private var silenceHintTask: Task<Void, Never>?

    /// Живой предпросмотр распознавания в панели. Украшение — выключается.
    @Published public var showLivePreview: Bool {
        didSet {
            guard oldValue != showLivePreview else { return }
            defaults.set(showLivePreview, forKey: Self.showLivePreviewKey)
            // Выключили посреди диктовки — предпросмотр гаснет сейчас, а не
            // «когда-нибудь при смене состояния». Человек снял галочку, чтобы
            // текст ушёл с экрана немедленно.
            if !showLivePreview {
                previewFeedGate.close()
                (overlay as? PreviewPresenting)?.updatePreview(confirmed: "", volatile: "")
                if let transcriber { Task { await transcriber.stopPreview() } }
            } else if dictationState == .listening {
                previewFeedGate.open()
                updateLivePreview(for: .listening)
            }
        }
    }
    nonisolated static let showLivePreviewKey = "showLivePreview"

    /// Кран между аудиопотоком и предпросмотром.
    ///
    /// Колбэк захвата живёт вне главного актора и не может читать @Published:
    /// затвор — единственная точка правды, доступная с обеих сторон. Закрыт —
    /// и на каждый из ~23 кадров в секунду не создаётся задача ради вызова,
    /// который всё равно кончился бы ничем.
    private let previewFeedGate = PreviewFeedGate()

    /// Запуск при входе в систему. Приложение без иконки в Dock, которое не
    /// запустилось после перезагрузки, неотличимо от сломанного: клавиша
    /// молчит, и некому объяснить почему.
    @Published public var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    private var didCompleteInitialPermissionRefresh = false

    // Таймеры и подписки помечены `nonisolated(unsafe)`, потому что их снимает
    // `deinit`, а он у изолированного класса — вне изоляции. Трогают их только
    // с главного потока: приложение целиком живёт на нём.
    nonisolated(unsafe) private var permissionTimer: Timer?
    nonisolated(unsafe) private var durationTimer: Timer?
    nonisolated(unsafe) private var systemObservers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    public var isDictationReady: Bool {
        accessibilityGranted && microphoneGranted && modelState.isReady && isEngineReady
    }

    /// Как часто сейчас опрашиваются разрешения. Ноль — опрос не идёт.
    ///
    /// Наружу видно намеренно: обещание «в покое приложение ничего не делает»
    /// проверяется именно этим числом.
    public private(set) var permissionPollingInterval: TimeInterval = 0

    public var isPollingPermissions: Bool { permissionTimer != nil }

    /// Идёт ли проверка предела длительности. В покое её быть не должно.
    public var isCountingDuration: Bool { durationTimer != nil }

    /// Предупреждение о выбранной клавише, если оно есть.
    public var hotkeyWarning: String? {
        HotkeyAdvice.warning(
            for: hotkey,
            fnUsage: FnKeyUsage(rawValue: defaults.object(forKey: Keys.fnUsage) as? Int)
        )
    }

    public convenience init() {
        self.init(environment: .system())
    }

    public init(environment: AppEnvironment) {
        defaults = environment.defaults
        // Сохранённый код сверяется со списком движка. Список — свойство
        // библиотеки и может сузиться при её обновлении; без проверки каждая
        // диктовка падала бы на «unsupported language hint», WAV копились бы
        // в спасении, а пикер показывал бы пустую строку. Незнакомый код —
        // это автоопределение, как и было до выбора.
        let storedLanguage = environment.defaults.string(forKey: Self.recognitionLanguageKey)
        recognitionLanguage = storedLanguage.flatMap {
            FluidAudioAdapter.supportedLanguageHints.contains($0) ? $0 : nil
        }
        showLivePreview = environment.defaults.object(forKey: Self.showLivePreviewKey) == nil
            ? true
            : environment.defaults.bool(forKey: Self.showLivePreviewKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        paths = environment.paths
        permissions = environment.permissions
        accessibilityManager = environment.accessibilityManager
        hotkeyMonitor = environment.hotkeyMonitor
        inserter = environment.inserter
        overlay = environment.overlay
        makeCapture = environment.makeCapture
        transcribe = environment.transcribe
        permissionPollInterval = environment.permissionPollInterval
        modelDownloader = environment.modelDownloader
        workspaceNotifications = environment.workspaceNotifications
        notifications = environment.notifications
        transcriber = environment.localTranscriber
        // Тестовые окружения подставляют готовое ASR-замыкание и не нуждаются
        // в Core ML warmup. Production всегда передаёт shared transcriber.
        isEngineReady = environment.localTranscriber == nil
        replacementsStore = ReplacementsStore(
            defaults: environment.defaults,
            key: Keys.replacements
        )

        hotkey = DictationHotkey(rawValue: environment.defaults.string(forKey: Keys.hotkey) ?? "")
            ?? .rightCommand
        soundsEnabled = environment.defaults.object(forKey: Keys.sounds) as? Bool ?? true

        let loaded = replacementsStore.load()
        replacements = loaded.replacements
        dictionaryProblem = loaded.problem

        setUp()

        // Сообщаем уже после сборки: до неё показывать сообщение было бы некуда.
        if let problem = loaded.problem {
            notify(DictationNotice(kind: .warning, message: problem.message))
        }
    }

    deinit {
        // Таймер, оставленный в цикле выполнения, продолжает будить процесс и
        // после смерти владельца: слабая ссылка внутри спасает от падения, но
        // не от пробуждений.
        permissionTimer?.invalidate()
        durationTimer?.invalidate()
        for observer in systemObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    // MARK: - Сборка

    private func setUp() {
        let sounds = SystemSounds(enabled: { [weak self] in self?.soundsEnabled ?? true })

        do {
            let previewFeed = transcriber
            let capture = makeCapture(
                try paths.takes(),
                { [weak self] error in
                    // Аудиопоток перестал быть пригодным посреди речи. Ждать
                    // остановки нельзя: человек говорит в пустоту, а причина
                    // должна быть показана точно.
                    Task { @MainActor in
                        self?.controller?.interrupt(
                            reason: Self.captureFailureMessage(error)
                        )
                    }
                },
                { [weak self, previewFeed, previewFeedGate] samples in
                    // Живые отсчёты: в предпросмотр и в индикатор уровня.
                    // Пик достаточен — RMS здесь не точнее для глаза.
                    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                    Task { @MainActor in self?.registerInputLevel(peak) }
                    if let previewFeed, previewFeedGate.isOpen {
                        Task { await previewFeed.feedPreview(samples: samples) }
                    }
                }
            )
            let recordingRecovery = RecordingRecoveryStore(directory: try paths.audioRecovery())
            self.recordingRecovery = recordingRecovery

            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            let store = ModelStore(manifest: manifest, layout: layout, downloader: modelDownloader)
            self.store = store
            mainModelBytes = manifest.totalByteCount
            mainModelFileCount = manifest.files.count

            // Акустический подсказчик терминов — вторая модель с собственным
            // манифестом. Для человека обе — одна «модель»: см. ModelPairState.
            let vocabularyManifest = try ModelManifest.bundledVocabulary()
            let vocabularyLayout = try ModelInstallLayout(
                manifest: vocabularyManifest,
                root: try paths.models()
            )
            vocabularyStore = ModelStore(
                manifest: vocabularyManifest,
                layout: vocabularyLayout,
                downloader: modelDownloader
            )
            vocabularyDirectory = vocabularyLayout.engineDirectory
            vocabularyModelBytes = vocabularyManifest.totalByteCount
            vocabularyModelFileCount = vocabularyManifest.files.count

            let engineDirectory = layout.engineDirectory
            self.engineDirectory = engineDirectory
            let controller = DictationController(
                capture: capture,
                transcribe: transcribe(
                    engineDirectory,
                    { [box = UncheckedBox(defaults)] in
                        // Провайдер зовётся из фонового контекста распознавания.
                        // UserDefaults потокобезопасен (документировано), а
                        // хранилище — тот же источник истины, что и
                        // published-свойство; box лишь проносит его через
                        // Sendable-границу.
                        box.value.string(forKey: Self.recognitionLanguageKey)
                    }
                ),
                inserter: inserter,
                overlay: overlay,
                sounds: sounds,
                recordingRecovery: recordingRecovery,
                pipeline: { [weak self] in
                    TextPipeline(replacements: self?.replacements ?? [])
                }
            )
            controller.onStateChange = { [weak self] state in
                self?.dictationState = state
                self?.updateDurationTimer(for: state)
                self?.flushNoticeAfterSession(state)
                self?.updateLivePreview(for: state)
            }
            controller.onNotice = { [weak self] notice in
                self?.lastNotice = notice
                if let text = notice.recoverableText { self?.recoveredText = text }
                if let audio = notice.recoveryAudio { self?.recoveredRecording = audio }
                // Ядро само объяснилось. Своё объяснение поверх его слов было бы
                // хуже молчания: у сессии одна причина конца, а не две.
                self?.noticeAfterSession = nil
            }
            controller.onHandsFreeChange = { [weak self] active in
                // Монитору нужно знать режим: в нём одиночное нажатие означает
                // «останови», а не «начни новую диктовку».
                self?.hotkeyMonitor.isHandsFreeActive = active
                self?.isHandsFreeActive = active
            }
            controller.onTextInserted = { [weak self] text in
                self?.successfulDictationCount += 1
                self?.lastDictation = LastDictation(insertedText: text)
            }
            self.controller = controller
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Couldn't prepare the app's working folders: \(error.localizedDescription)"
                )
            )
        }

        wireHotkey()
        observeSystemEvents()
        refreshPermissions()
        Task {
            removeLegacyTextRecovery()
            await importAbandonedRecordings()
            await refreshModelState()
            if modelState.isReady { await warmUpEngine() }
        }
    }

    /// Старые сборки писали нераспознанный текст на диск в `Recovered/`.
    /// Теперь такой текст живёт только в памяти, и обещание «распознанный текст
    /// не пишется на диск» обязано покрывать и следы прошлых версий.
    private func removeLegacyTextRecovery() {
        guard let support = try? paths.support() else { return }
        let legacy = support.appending(path: "Recovered", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacy)
        } catch {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Couldn't delete the old version's recovery texts. "
                        + "Delete them manually: ~/Library/Application Support/WaiDictation/Recovered"
                )
            )
        }
    }

    static func captureFailureMessage(_ error: AudioCaptureError) -> String {
        switch error {
        case .unsupportedAudioFormat(let detail):
            return "Couldn't handle the selected microphone's audio format: \(detail)"
        case .microphonePermissionDenied:
            return "No microphone access. Open System Settings."
        case .engineUnavailable(let detail):
            return "The microphone stopped responding: \(detail)"
        case .diskFull:
            return "Couldn't record audio: no free disk space."
        case .writeFailed(let detail):
            return "Couldn't record audio: \(detail)"
        case .notRecording:
            return "Recording stopped unexpectedly."
        }
    }

    private func importAbandonedRecordings() async {
        guard let recordingRecovery else { return }
        do {
            let result = try await recordingRecovery.importAbandoned(from: paths.takes())
            recoveredRecording = result.recordings.first
            if recoveredRecording != nil {
                notify(
                    DictationNotice(
                        kind: result.discardedCorruptCount == 0 ? .warning : .failure,
                        message: result.discardedCorruptCount == 0
                            ? "A local recording was found after an interruption — you can retry transcription or delete it."
                            : "One recording was saved for retry. A damaged fragment couldn't be recovered and was deleted.",
                        recoveryAudio: recoveredRecording
                    )
                )
            } else if result.discardedCorruptCount > 0 {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "An unfinished recording was damaged: it can't be recovered, the fragment was deleted."
                    )
                )
            }
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Couldn't prepare recording recovery: \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - Copy / Retry / Delete recovery

    public func copyRecoveredText() {
        guard let recoveredText else { return }
        do {
            try HostOnlyPasteboard().copyHostOnly(recoveredText)
            notify(DictationNotice(kind: .info, message: "Text copied to this Mac only."))
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the text."))
        }
    }

    public func retryRecoveredText() {
        guard dictationState == .idle,
              !isRecoveryOperationActive,
              let recoveredText
        else { return }
        let target = inserter.frontmostApplication()
        isRecoveryOperationActive = true
        dictationState = .inserting
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.dictationState = .idle
                self.isRecoveryOperationActive = false
            }
            await overlay.present(.inserting, elapsed: 0)
            do {
                try await inserter.insert(recoveredText, into: target)
                self.recoveredText = nil
                await overlay.dismiss()
            } catch {
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "Retry insert failed — the text is still available via Copy and Retry.",
                        recoverableText: recoveredText
                    )
                )
            }
        }
    }

    public func deleteRecoveredText() {
        guard !isRecoveryOperationActive else { return }
        recoveredText = nil
    }

    public func retryRecoveredRecording() {
        guard dictationState == .idle,
              !isRecoveryOperationActive,
              modelState.isReady,
              let url = recoveredRecording,
              let engineDirectory,
              let recordingRecovery
        else { return }
        let target = inserter.frontmostApplication()

        isRecoveryOperationActive = true
        dictationState = .transcribing
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.dictationState = .idle
                self.isRecoveryOperationActive = false
            }
            await overlay.present(.transcribing, elapsed: 0)
            let recognizedText: String
            do {
                let result = try await transcribe(
                    engineDirectory,
                    { [box = UncheckedBox(defaults)] in
                        box.value.string(forKey: Self.recognitionLanguageKey)
                    }
                )(url)
                let output = TextPipeline(replacements: replacements).process(result.text)
                guard !output.text.isEmpty else { throw ASREngineError.inferenceFailed("empty result") }
                recognizedText = output.text
            } catch {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Retry transcription failed. The recording is still saved locally.",
                        recoveryAudio: url
                    )
                )
                return
            }

            dictationState = .inserting
            await overlay.present(.inserting, elapsed: 0)
            do {
                try await inserter.insert(recognizedText, into: target)
            } catch {
                recoveredText = recognizedText
                do {
                    try await recordingRecovery.delete(url)
                    recoveredRecording = try await recordingRecovery.recordings().first
                    notify(
                        DictationNotice(
                            kind: .warning,
                            message: "The recording was transcribed, but the text wasn't inserted — Copy and Retry are in the menu.",
                            recoverableText: recognizedText
                        )
                    )
                } catch {
                    recoveredRecording = url
                    notify(
                        DictationNotice(
                            kind: .failure,
                            message: "The text is available via Copy and Retry, but the local WAV couldn't be deleted: \(error.localizedDescription)",
                            recoverableText: recognizedText,
                            recoveryAudio: url
                        )
                    )
                }
                return
            }

            do {
                try await recordingRecovery.delete(url)
                recoveredRecording = try await recordingRecovery.recordings().first
                await overlay.dismiss()
            } catch {
                recoveredRecording = url
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "The text was inserted, but the local WAV couldn't be deleted: \(error.localizedDescription)",
                        recoveryAudio: url
                    )
                )
            }
        }
    }

    public func deleteRecoveredRecording() {
        guard !isRecoveryOperationActive, let url = recoveredRecording else { return }
        isRecoveryOperationActive = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRecoveryOperationActive = false }
            do {
                try await recordingRecovery?.delete(url)
                recoveredRecording = try await recordingRecovery?.recordings().first
            } catch {
                notify(DictationNotice(kind: .failure, message: "Couldn't delete the local recording."))
            }
        }
    }

    /// Подписаться на то, что происходит с компьютером помимо нас.
    ///
    /// Обе подписки существуют ради одного и того же: диктовка не должна
    /// оставаться включённой, когда слушать уже нечем.
    private func observeSystemEvents() {
        observe(workspaceNotifications, NSWorkspace.willSleepNotification) { $0.handleSleep() }
        observe(workspaceNotifications, NSWorkspace.didWakeNotification) { $0.handleWake() }
        observe(notifications, .AVAudioEngineConfigurationChange) { $0.handleAudioConfigurationChange() }
        observe(notifications, NSApplication.didBecomeActiveNotification) {
            $0.handleApplicationBecameActive()
        }
    }

    private func handleApplicationBecameActive() {
        let wasWaitingForSettings = accessibilityState == .waitingForSettings
        refreshPermissions()
        if wasWaitingForSettings, !accessibilityGranted,
           accessibilityState != .repairRequired {
            accessibilityState = .restartRequired
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        handler: @escaping @MainActor (AppState) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            // Смена аудиоустройства приходит с потока звукового движка, сон —
            // с главного. Общий переход на главный поток дешевле, чем разбор,
            // откуда именно нас позвали.
            Task { @MainActor in
                guard let self else { return }
                handler(self)
            }
        }
        systemObservers.append((center, token))
    }

    /// Компьютер уходит в сон.
    ///
    /// Отпускание клавиши, случившееся во сне, до нас не дойдёт: система не
    /// присылает событий спящей машины. Без остановки сессия осталась бы в
    /// «слушаю» навсегда — с включённым микрофоном и горящим индикатором
    /// записи, и выйти из этого можно было бы только через Escape.
    private func handleSleep() {
        switch dictationState {
        case .listening:
            // Сказанное до сна уже записано. Распознаём его, а не выбрасываем.
            noticeAfterSession = DictationNotice(
                kind: .info,
                message: "The Mac went to sleep — recording had to stop."
            )
            stopCurrentRecording()
        case .preparing:
            // Записать ещё ничего не успели — терять нечего.
            controller?.cancel()
        case .idle, .transcribing, .inserting:
            break
        }
    }

    /// Компьютер проснулся.
    ///
    /// Клавишу за время сна успели отпустить, а события об этом не было:
    /// монитор до сих пор считает её зажатой и следующее нажатие проглотит.
    /// Перезапуск слежения — единственное, что стирает память о начатом жесте.
    private func handleWake() {
        hotkeyMonitor.stop()
        refreshPermissions()
    }

    /// Аудиоустройство сменилось посреди записи.
    ///
    /// Наушники вынули, монитор с микрофоном отключили — движок остаётся
    /// запущенным, но кадры в него больше не приходят. Человек говорит в
    /// тишину и узнаёт об этом только по пустому результату.
    private func handleAudioConfigurationChange() {
        guard dictationState == .listening else { return }
        controller?.preserveActiveRecording(
            reason: "The microphone or audio device was disconnected. Dictation stopped."
        )
    }

    /// Сказать то, что ждало конца сессии.
    ///
    /// Сразу сказать нельзя: следом за остановкой ядро перерисовывает панель
    /// под «распознаю», и объяснение живёт на экране доли секунды. А сказать
    /// надо — иначе непонятно, почему запись оборвалась на полуслове.
    private func flushNoticeAfterSession(_ state: DictationState) {
        guard state == .idle, let pending = noticeAfterSession else { return }
        noticeAfterSession = nil
        notify(pending)
    }

    /// Закончить идущую запись так, как её закончил бы человек.
    ///
    /// В режиме без удержания отпускание клавиши ничего не значит, и обычная
    /// остановка была бы проигнорирована — запись продолжалась бы в никуда.
    private func stopCurrentRecording() {
        if isHandsFreeActive {
            controller?.stopHandsFree()
        } else {
            controller?.stop()
        }
    }

    /// Видимая кнопка в menu bar: пользователь не обязан помнить жест.
    public func finishCurrentDictation() {
        guard !isRecoveryOperationActive,
              dictationState == .preparing || dictationState == .listening
        else { return }
        stopCurrentRecording()
    }

    /// Общая безопасная отмена для Escape и menu bar.
    public func cancelCurrentDictation() {
        guard !isRecoveryOperationActive, dictationState != .idle else { return }
        controller?.cancel()
        notify(DictationNotice(kind: .info, message: "Dictation cancelled. The recording was deleted."))
    }

    private func wireHotkey() {
        hotkeyMonitor.setHotkey(hotkey)
        hotkeyMonitor.onPress = { [weak self] in
            guard let self else { return }
            guard !self.isRecoveryOperationActive else { return }
            guard self.explainIfNotReady() else { return }
            self.controller?.begin(
                handsFree: false,
                isEnabled: self.isDictationReady,
                isModelReady: self.modelState.isReady
            )
        }
        hotkeyMonitor.onRelease = { [weak self] in
            self?.controller?.stop()
        }
        hotkeyMonitor.onDoubleTap = { [weak self] in
            guard let self else { return }

            switch self.dictationState {
            case .preparing, .listening:
                // Сессия уже идёт — первое нажатие её запустило. Переводим её в
                // режим без удержания вместо того, чтобы начинать новую: новая
                // всё равно не началась бы, потому что эта ещё не закончилась.
                self.controller?.promoteToHandsFree()
            case .idle:
                guard self.explainIfNotReady() else { return }
                self.controller?.begin(
                    handsFree: true,
                    isEnabled: self.isDictationReady,
                    isModelReady: self.modelState.isReady
                )
            case .transcribing, .inserting:
                break
            }
        }
        hotkeyMonitor.onSingleTapWhileHandsFree = { [weak self] in
            self?.controller?.stopHandsFree()
        }
        hotkeyMonitor.onAbortShortcut = { [weak self] in
            // Удержание оказалось шорткатом (Ctrl+C поверх выбранной клавиши):
            // запись обрывается тихо — без вставки, без сообщений и без звука
            // ошибки. Человек нажимал шорткат, а не диктовал.
            self?.controller?.cancel()
        }
        hotkeyMonitor.onEscape = { [weak self] in
            // Escape отменяет только идущую диктовку. В остальное время это
            // обычная клавиша, и перехватывать её нельзя.
            self?.cancelCurrentDictation()
        }
    }

    /// Можно ли начинать диктовку; если нет — сказать, почему.
    ///
    /// Ядро отклоняет старт молча, и это правильно: у него нет ни экрана, ни
    /// слов. Но снаружи молчание в ответ на нажатие неотличимо от сломанного
    /// приложения — особенно в окне прогрева после установки, где всё выдано,
    /// всё скачано, а клавиша ещё десятки секунд не работает.
    ///
    /// Спрашивается только в покое. Нажатие посреди идущей диктовки ядро тоже
    /// отклоняет, но там молчание уместно: человек видит панель и знает, что
    /// происходит, а объяснение на каждое лишнее нажатие было бы придиркой.
    ///
    /// Возвращает `true`, если препятствий нет.
    private func explainIfNotReady() -> Bool {
        guard dictationState == .idle else { return true }
        guard let reason = DictationReadiness.reason(
            accessibilityGranted: accessibilityGranted,
            microphoneGranted: microphoneGranted,
            modelState: modelState,
            isEngineReady: isEngineReady
        ) else { return true }

        // Именно warning: для VoiceOver это срочное объявление, а человек
        // только что нажал клавишу и ждёт ответа сейчас, а не после того, как
        // синтезатор дочитает чужую фразу.
        notify(DictationNotice(kind: .warning, message: reason))
        return false
    }

    /// Показать сообщение человеку.
    ///
    /// Через оверлей, а не только полем `lastNotice`: его ни одно окно не
    /// показывает, и сообщения вроде «сейчас идёт диктовка» не доходили вовсе.
    private func notify(_ notice: DictationNotice) {
        lastNotice = notice
        Task { await overlay.presentNotice(notice) }
    }

    // MARK: - Разрешения

    public func refreshPermissions() {
        let accessibility = permissions.accessibilityGranted
        let microphone = permissions.microphoneGranted
        let previousAccessibility = accessibilityGranted
        let previousMicrophone = microphoneGranted

        // Проверяем на изменение: интерфейс подписан на эти поля, а сюда
        // приходят и по таймеру, и с каждым открытием настроек.
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if microphone != microphoneGranted { microphoneGranted = microphone }

        if accessibility {
            accessibilityState = .granted
            defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
        } else if defaults.bool(forKey: Self.accessibilityRelaunchPendingKey) {
            accessibilityState = .repairRequired
        } else {
            switch accessibilityState {
            case .waitingForSettings, .restartRequired, .repairRequired, .repairing, .failed:
                break
            case .denied, .granted:
                accessibilityState = .denied
            }
        }

        if !didCompleteInitialPermissionRefresh {
            didCompleteInitialPermissionRefresh = true
            if !accessibility || !microphone {
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "Dictation is off: grant Accessibility and Microphone access in System Settings."
                    )
                )
            }
        } else if previousAccessibility, !accessibility {
            if dictationState == .preparing || dictationState == .listening {
                controller?.preserveActiveRecording(
                    reason: "Accessibility access was revoked. Dictation stopped; open System Settings."
                )
            } else {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Accessibility access was revoked. Open System Settings."
                    )
                )
            }
        } else if previousMicrophone, !microphone {
            if dictationState == .preparing || dictationState == .listening {
                controller?.preserveActiveRecording(
                    reason: "Microphone access was revoked. Dictation stopped; open System Settings."
                )
            } else {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Microphone access was revoked. The app may need a relaunch."
                    )
                )
            }
        }

        // Монитор регистрируется заново при каждой проверке: система начинает
        // отдавать ему события только после выдачи доступа, и без повторного
        // запуска клавиша молчала бы до перезапуска приложения.
        if accessibility {
            hotkeyMonitor.start()
        } else {
            hotkeyMonitor.stop()
        }

        reschedulePermissionPolling()
    }

    /// Подобрать частоту опроса под текущее положение дел.
    ///
    /// Пока чего-то не хватает, человек стоит в системных настройках и ждёт
    /// отклика — спрашиваем часто. Когда всё выдано, ждать больше нечего:
    /// приложение неделями сидит в строке меню, и будить процесс каждую секунду
    /// ради ответа, который не изменится, незачем.
    private func reschedulePermissionPolling() {
        let interval = PermissionPollPolicy.interval(
            accessibilityGranted: accessibilityGranted,
            microphoneGranted: microphoneGranted,
            base: permissionPollInterval
        )
        guard interval != permissionPollingInterval else { return }

        permissionPollingInterval = interval
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard interval > 0 else { return }

        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    public func requestAccessibility() {
        guard !accessibilityGranted else { return }
        accessibilityState = .waitingForSettings
        _ = accessibilityManager.requestAccess()
        accessibilityManager.openSettings()
        refreshPermissions()
    }

    public func openAccessibilitySettings() {
        accessibilityManager.openSettings()
    }

    public func revealApplicationForAccessibility() {
        accessibilityManager.revealApplication()
    }

    public func restartForAccessibility() {
        defaults.set(true, forKey: Self.accessibilityRelaunchPendingKey)
        Task {
            do {
                try await accessibilityManager.relaunchApplication()
            } catch {
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                accessibilityState = .failed(error.localizedDescription)
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Couldn't relaunch Wai Dictation: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    /// Вызывается только после отдельного подтверждения в UI: команда удаляет
    /// Accessibility-записи ровно этого bundle id и потребует выдать доступ
    /// заново. Автоматического reset при запуске или запросе нет.
    public func repairAccessibility() {
        guard !accessibilityGranted, accessibilityState != .repairing else { return }
        accessibilityState = .repairing
        Task {
            do {
                try await accessibilityManager.resetAccess()
                // После reset отсутствие grant ожидаемо: новый процесс должен
                // снова показать обычную кнопку «Выдать», а не попасть в цикл
                // «repair required». Pending относится только к перезапуску
                // без reset, который обязан был подхватить уже включённый grant.
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                try await accessibilityManager.relaunchApplication()
            } catch {
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                accessibilityState = .failed(error.localizedDescription)
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Couldn't repair Accessibility access: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    public func requestMicrophone() {
        Task {
            let granted = await Permissions.requestMicrophone()
            if !granted { Permissions.openMicrophoneSettings() }
            refreshPermissions()
        }
    }

    // MARK: - Модель

    public func refreshModelState() async {
        guard let store else { return }
        // Пока идёт установка, осмотр диска сбрасывал бы состояние в «модель не
        // установлена»: метки готовности ещё нет. Прогресс с экрана пропадал бы
        // ровно тогда, когда человек открыл настройки на него посмотреть.
        guard !isInstalling else { return }
        let mainState = await store.refreshState()
        let vocabularyState = await vocabularyStore?.refreshState() ?? .notInstalled
        modelState = combinedModelState(main: mainState, vocabulary: vocabularyState)
        remainingDownloadMegabytes = Int(
            (ModelPairState.remainingBytes(
                main: mainState,
                vocabulary: vocabularyState,
                mainTotalBytes: mainModelBytes,
                vocabularyTotalBytes: vocabularyModelBytes
            ) + 500_000) / 1_000_000
        )
        // Осмотр диска не видит отказ Core ML: файлы целы, а модель не поднялась.
        // Пока человек явно не запросил восстановление, отказ остаётся на экране —
        // иначе кнопка восстановления исчезает, а диктовка так и не работает.
        if let engineLoadFailure, modelState.isReady {
            modelState = .repairRequired(engineLoadFailure)
        }
        if transcriber == nil {
            isEngineReady = modelState.isReady
        } else if !modelState.isReady {
            isEngineReady = false
        }
    }

    private func combinedModelState(main: ModelState, vocabulary: ModelState) -> ModelState {
        ModelPairState.combine(
            main: main,
            vocabulary: vocabulary,
            mainTotalBytes: mainModelBytes,
            vocabularyTotalBytes: vocabularyModelBytes,
            mainFileCount: mainModelFileCount,
            vocabularyFileCount: vocabularyModelFileCount
        )
    }

    public func installModel() {
        // Повторное нажатие во время загрузки ничего не начинает: кнопка на
        // экране живёт до первого пришедшего состояния, и успеть нажать её
        // дважды проще, чем кажется.
        guard let store, !isInstalling else { return }
        isInstalling = true
        isEngineReady = false
        // Отказ Core ML оставляет файлы на диске «целыми» — оба хранилища
        // скажут «готово». Явное восстановление обязано сдержать обещание из
        // сообщения и перекачать заново, а не молча повторить прогрев.
        let engineRejectedModels = engineLoadFailure != nil
        // Явная команда человека открывает новую попытку: прежний отказ Core ML
        // больше не держится, свежая установка прогреется заново.
        engineLoadFailure = nil

        Task {
            // Обе модели ставятся последовательно, а прогресс на экране общий:
            // каждое событие любого из хранилищ пересобирает объединённое
            // состояние. Уже готовая модель не трогается — так добор после
            // обновления скачивает только недостающий подсказчик.
            var mainLatest = await store.refreshState()
            let vocabularyLatest = UncheckedBox(
                await vocabularyStore?.refreshState() ?? .notInstalled
            )

            if !mainLatest.isReady || engineRejectedModels {
                let states = await store.states()
                let monitor = Task { @MainActor in
                    for await state in states {
                        modelState = combinedModelState(
                            main: state,
                            vocabulary: vocabularyLatest.value
                        )
                    }
                }
                if mainLatest.isReady || mainLatest.requiresRepair {
                    await store.repair()
                } else {
                    await store.install()
                }
                monitor.cancel()
                mainLatest = await store.currentState()
            }

            if mainLatest.isReady, let vocabularyStore,
               !vocabularyLatest.value.isReady || engineRejectedModels {
                let states = await vocabularyStore.states()
                let mainSnapshot = mainLatest
                let monitor = Task { @MainActor in
                    for await state in states {
                        vocabularyLatest.value = state
                        modelState = combinedModelState(main: mainSnapshot, vocabulary: state)
                    }
                }
                if vocabularyLatest.value.isReady || vocabularyLatest.value.requiresRepair {
                    await vocabularyStore.repair()
                } else {
                    await vocabularyStore.install()
                }
                monitor.cancel()
            }

            isInstalling = false
            await refreshModelState()

            // Первая загрузка компилирует модель под нейромодуль и занимает
            // секунды. Делаем это сразу, чтобы пользователь не ждал в момент
            // первой диктовки.
            if modelState.isReady { await warmUpEngine() }
        }
    }

    public func cancelModelInstall() {
        guard isInstalling else { return }
        Task {
            await store?.cancelInstall()
            await vocabularyStore?.cancelInstall()
        }
    }

    public func deleteModel() {
        // Идёт диктовка — модель сейчас в работе. Удалять её из-под себя значит
        // потерять уже сказанное и показать вместо этого ошибку загрузки.
        //
        // Проверка стоит раньше остальных намеренно: человеку нужен ответ на
        // своё нажатие, а не молчание из-за того, что чего-то нет внутри.
        guard dictationState == .idle else {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Dictation is in progress. Wait for it to finish."
                )
            )
            return
        }
        guard let store else { return }
        Task {
            isEngineReady = false
            engineLoadFailure = nil
            await transcriber?.unload()
            await store.delete()
            await vocabularyStore?.delete()
            await refreshModelState()
        }
    }

    private func warmUpEngine() async {
        guard let transcriber, let store else { return }
        guard case .ready = await store.currentState() else { return }
        isEngineReady = false
        isPreparingEngine = true
        defer { isPreparingEngine = false }

        do {
            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
            // Подсказчик терминов — часть той же готовности: без него диктовка
            // работала бы тише заявленного, а молчаливое «хуже, но работает»
            // здесь запрещено.
            if let vocabularyDirectory {
                // Собственные замены человека — включая выученные из правок —
                // усиливают акустику с теми же предохранителями, что и
                // стартовый набор.
                try await transcriber.prepareVocabulary(
                    modelDirectory: vocabularyDirectory,
                    boost: .withUserReplacements(
                        replacements.map { (spoken: $0.spoken, written: $0.written) }
                    )
                )
            }
            isEngineReady = true
            engineLoadFailure = nil
        } catch let boost as VocabularyBoostError {
            // Беда со списком терминов человека, а не с весами модели.
            // Раньше это падало в общий catch и классифицировалось как порча
            // модели: интерфейс предлагал перекачать сотни мегабайт, которые
            // ничем бы не помогли — термин никуда не делся бы, и круг
            // повторялся бы. Данные пользователя нельзя лечить перекачкой.
            engineLoadFailure = nil
            isEngineReady = true
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "One of the dictionary terms couldn't be used for acoustic "
                        + "boosting; dictation works, text replacements still apply. "
                        + "(\(boost))"
                )
            )
        } catch {
            let detail =
                "the files passed verification, but Core ML couldn't load the model: \(error.localizedDescription)"
            engineLoadFailure = detail
            modelState = .repairRequired(detail)
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "The model didn't load. An explicit repair will redownload "
                        + "\(remainingDownloadMegabytes == 0 ? 586 : remainingDownloadMegabytes) MB."
                )
            )
        }
    }

    /// Правка словаря доезжает до акустики сейчас, а не после перезапуска.
    ///
    /// Текстовые замены применяются к следующей диктовке сразу — если акустика
    /// при этом живёт старым списком, поведение словаря раздваивается без
    /// объяснения: половина фичи работает, половина ждёт перезапуска, и
    /// человек не может понять систему. Пересборка стоит доли секунды, веса
    /// подсказчика переживают её без перезагрузки.
    private func rebuildVocabularyBoost() {
        guard isEngineReady, let transcriber, let vocabularyDirectory else { return }
        let pairs = replacements.map { (spoken: $0.spoken, written: $0.written) }
        Task { [weak self] in
            do {
                try await transcriber.prepareVocabulary(
                    modelDirectory: vocabularyDirectory,
                    boost: .withUserReplacements(pairs)
                )
            } catch {
                // Акустика не пересобралась — текстовые замены уже работают, и
                // единственная честная реакция — сказать, а не откатить правку.
                await MainActor.run { [weak self] in
                    self?.notify(
                        DictationNotice(
                            kind: .warning,
                            message: "The dictionary was saved, but acoustic boosting "
                                + "couldn't pick it up: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    // MARK: - Предел длительности

    // MARK: - Живой предпросмотр

    /// Запись пошла — включить предпросмотр; запись кончилась — выключить.
    ///
    /// Предпросмотр — украшение: его отказ не имеет права трогать диктовку,
    /// поэтому ошибки старта не всплывают сообщением — отсутствие текста в
    /// панели видно само по себе, а вставка работает как раньше.
    private func updateLivePreview(for state: DictationState) {
        // Настройка закрывает только ЗАПУСК. Остановка обязана идти всегда:
        // раньше guard стоял на входе, и выключение предпросмотра посреди
        // диктовки означало, что stopPreview не вызовется никогда — вторая
        // ASR-сессия и её задача жили вечно, а панель продолжала показывать
        // предпросмотр при выключенной галочке.
        guard let transcriber else { return }
        switch state {
        case .listening where showLivePreview:
            previewFeedGate.open()
            silenceHintTask?.cancel()
            silenceHintTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                (self?.overlay as? PreviewPresenting)?.showSilenceHint()
            }
            Task { [weak self] in
                try? await transcriber.startPreview { confirmed, volatile in
                    Task { @MainActor in
                        (self?.overlay as? PreviewPresenting)?
                            .updatePreview(confirmed: confirmed, volatile: volatile)
                    }
                }
            }
        case .listening:
            break
        default:
            previewFeedGate.close()
            silenceHintTask?.cancel()
            silenceHintTask = nil
            Task { await transcriber.stopPreview() }
        }
    }

    /// Пик уровня с микрофона — в пульс точки записи. Сигнал громче порога
    /// отменяет подсказку «нет звука».
    private func registerInputLevel(_ peak: Float) {
        (overlay as? PreviewPresenting)?.updateInputLevel(peak)
        if peak > 0.02 {
            silenceHintTask?.cancel()
            silenceHintTask = nil
        }
    }

    /// Ошибка регистрации видима: молча оставить человека без автозапуска —
    /// значит вернуть проблему «после перезагрузки клавиша молчит».
    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Could not update the login item: \(error.localizedDescription)"
                )
            )
        }
    }

    private func updateDurationTimer(for state: DictationState) {
        durationTimer?.invalidate()
        durationTimer = nil
        guard state == .listening else { return }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller?.checkDurationLimit() }
        }
    }

    // MARK: - Словарь

    /// Можно ли сейчас менять словарь.
    ///
    /// Нельзя ровно в одном случае: прежний словарь не прочитался. Тогда любая
    /// запись затёрла бы его целиком — и человек потерял бы всё накопленное.
    public var isDictionaryEditable: Bool { dictionaryProblem == nil }

    /// Выучить правки последней диктовки: пословный diff с консервативным
    /// фильтром — учатся только термины (латиница, бренд-регистр), правки
    /// обычной речи не проходят. Возвращает, сколько замен добавлено.
    @discardableResult
    public func learnCorrections(editedText: String) -> Int {
        guard let lastDictation else { return 0 }
        let proposals = CorrectionLearning.propose(
            original: lastDictation.insertedText,
            edited: editedText,
            existing: replacements
        )
        for proposal in proposals {
            addReplacement(spoken: proposal.spoken, written: proposal.written)
        }
        if !proposals.isEmpty {
            notify(
                DictationNotice(
                    kind: .info,
                    message: proposals.count == 1
                        ? "Learned 1 replacement for future dictations."
                        : "Learned \(proposals.count) replacements for future dictations."
                )
            )
        }
        return proposals.count
    }

    /// Правка не дала ни одной замены — сказать прямо, а не закрыть окно молча.
    public func notifyNothingLearned() {
        notify(
            DictationNotice(
                kind: .info,
                message: "No new terms to learn — only term-like corrections become replacements."
            )
        )
    }

    public func addReplacement(spoken: String, written: String) {
        let spoken = spoken.trimmingCharacters(in: .whitespaces)
        let written = written.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty, !written.isEmpty else { return }
        updateReplacements(replacements + [DictionaryReplacement(spoken: spoken, written: written)])
    }

    public func removeReplacements(at offsets: IndexSet) {
        var updated = replacements
        updated.remove(atOffsets: offsets)
        updateReplacements(updated)
    }

    /// Добавить готовый набор терминов разработчика.
    ///
    /// Модель пишет англицизмы так, как слышит их в русской речи: «pull request»
    /// становится «пул реквест». Набор возвращает им обычный вид. Уже заведённые
    /// пользователем замены не трогаем — своё важнее заготовки.
    public func addStarterDictionary() {
        updateReplacements(replacements + StarterDictionary.missing(from: replacements))
    }

    /// Сколько заготовленных терминов ещё не добавлено.
    public var availableStarterCount: Int {
        StarterDictionary.missing(from: replacements).count
    }

    private func updateReplacements(_ updated: [DictionaryReplacement]) {
        guard let problem = dictionaryProblem else {
            do {
                try replacementsStore.save(updated)
            } catch {
                // Не сохранилось — значит и в памяти менять нельзя: список на
                // экране разошёлся бы с тем, что на диске, и человек узнал бы об
                // этом только после перезапуска.
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "The dictionary wasn't saved: \(error.localizedDescription)"
                    )
                )
                return
            }
            replacements = updated
            rebuildVocabularyBoost()
            return
        }

        notify(DictationNotice(kind: .warning, message: problem.message))
    }
}
