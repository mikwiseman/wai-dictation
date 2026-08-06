import Foundation

/// Что делать с распознанным текстом, если вставить его не удалось.
public struct RecoveredDictation: Sendable, Equatable {
    public let text: String
}

/// Ядро диктовки.
///
/// Держит состояние сессии и проводит её от нажатия клавиши до вставки текста.
/// Ничего не знает ни про AppKit, ни про микрофон, ни про модель — всё это
/// приходит снаружи через протоколы, поэтому здесь же и тестируется.
///
/// Инварианты, без которых продукт ломается на первых же пользователях,
/// собраны в отдельных проверках по ходу кода: каждый из них пришёл из
/// реального бага в предшествующем продукте.
@MainActor
public final class DictationController {
    // MARK: - Наблюдаемое состояние

    public private(set) var state: DictationState = .idle {
        didSet {
            // Равенство проверяем намеренно: интерфейс подписан на изменения,
            // а разрешения опрашиваются раз в секунду. Без этой проверки окно
            // настроек перерисовывалось бы каждую секунду.
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    public private(set) var pendingRecovery: RecoveredDictation?

    public var onStateChange: (@MainActor (DictationState) -> Void)?
    public var onNotice: (@MainActor (DictationNotice) -> Void)?
    /// Успешная вставка — единственное доказательство, что первая проба
    /// действительно прошла, а не была вручную напечатана в TextEditor.
    /// Успешная вставка — с текстом, который реально ушёл в приложение.
    /// Текст нужен окну «поправь последнюю диктовку»; на диск он не попадает.
    public var onTextInserted: (@MainActor (String) -> Void)?
    /// Происхождение только что вставленной диктовки: чем текст был и чем стал.
    ///
    /// Отдельный колбэк, а не расширение `onTextInserted`: тот дёргают четыре
    /// набора тестов, которые про происхождение ничего не знают, и менять его
    /// подпись пришлось бы во всех. Аддитивный опциональный колбэк их не видит.
    public var onDictationCompleted: (@MainActor (PipelineProvenance) -> Void)?
    /// Сколько заняло «отпустил → текст на месте». Только для успешных вставок:
    /// у неудачной честного числа нет.
    public var onSpeed: (@MainActor (DictationSpeedReport) -> Void)?
    /// Сообщает, идёт ли запись без удержания: от этого зависит, как
    /// истолковать следующее нажатие клавиши.
    public var onHandsFreeChange: (@MainActor (Bool) -> Void)?

    /// Идёт ли запись без удержания клавиши.
    public private(set) var isHandsFreeActive = false {
        didSet {
            guard oldValue != isHandsFreeActive else { return }
            onHandsFreeChange?(isHandsFreeActive)
        }
    }

    // MARK: - Зависимости

    private let capture: any AudioCapturing
    private let transcribe: @Sendable (URL) async throws -> ASRResult
    private let inserter: any TextInserting
    private let overlay: any OverlayPresenting
    private let sounds: any Sounding
    private let recordingRecovery: any RecordingRecoveryStoring
    private let pipeline: () -> TextPipeline
    /// Часы сессии. Отдельной зависимостью ровно по той же причине, что и
    /// микрофон: часовой предел иначе нельзя проверить, не прождав час.
    private let now: @Sendable () -> Date
    /// Монотонные часы — отдельно от настенных, и это не дублирование.
    ///
    /// `now` отвечает за часовой предел, а это идея настенного времени.
    /// Скорости настенные часы не годятся вовсе: сон, переход на летнее время
    /// или подводка по NTF посреди диктовки дали бы «−400 мс», то есть просто
    /// враньё. `MicrophoneCapture` и `TextInserter` уже живут на
    /// `ContinuousClock`, поэтому все отметки сравнимы между собой.
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    // MARK: - Состояние сессии

    /// Приложение, в которое вставим текст.
    ///
    /// Снимается в момент нажатия клавиши, а не в конце: пока идёт
    /// распознавание, фокус мог уйти, а текст обязан попасть туда, где диктовали.
    private var targetApplication: TargetApplication?

    /// Отпускание клавиши, пришедшее раньше, чем началась запись.
    ///
    /// Сбрасывается ровно в трёх местах: при старте сессии, при её отмене и в
    /// завершающей уборке. Потерянный флаг оставляет запись включённой.
    private var deferredStopRequested = false

    private var cancellationRequested = false
    private var isHandsFree = false
    private var finalizationTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    /// Момент отпускания клавиши — начало отсчёта «stop → текст».
    private var stopRequestedAt: ContinuousClock.Instant?

    /// Номер текущей сессии — растёт на каждом старте.
    ///
    /// Отмена не прерывает уже начатое ожидание, а только помечает его:
    /// распознавание дочитывает свой буфер и просыпается позже — когда человек
    /// успел начать следующую диктовку. Без номера такой хвост доводил уборку до
    /// конца и гасил ЧУЖУЮ, живую сессию: состояние показывало «свободно», а
    /// микрофон оставался включённым, и выйти из этого было нечем.
    private var currentSession = 0

    /// Сообщение, которое ждёт конца сессии.
    ///
    /// Сразу показать нельзя: следом за остановкой панель перерисовывается под
    /// «распознаю» и стирает сообщение — оно живёт на экране доли секунды.
    /// Пока ждало только объяснение часового предела: единственный путь, где
    /// сессию заканчивает не человек и не сбой.
    private var noticeAfterSession: DictationNotice?

    public init(
        capture: any AudioCapturing,
        transcribe: @escaping @Sendable (URL) async throws -> ASRResult,
        inserter: any TextInserting,
        overlay: any OverlayPresenting,
        sounds: any Sounding,
        recordingRecovery: any RecordingRecoveryStoring = DiscardingRecordingRecovery(),
        pipeline: @escaping () -> TextPipeline = { TextPipeline() },
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.capture = capture
        self.transcribe = transcribe
        self.inserter = inserter
        self.overlay = overlay
        self.sounds = sounds
        self.recordingRecovery = recordingRecovery
        self.pipeline = pipeline
        self.now = now
        self.monotonicNow = monotonicNow
    }

    // MARK: - Начало

    /// Нажата горячая клавиша.
    public func begin(handsFree: Bool, isEnabled: Bool, isModelReady: Bool) {
        // Первая проверка — синхронная, до всякого ожидания. Между ней и
        // асинхронным стартом успевает пройти повторное нажатие.
        guard DictationStopPolicy.canStart(
            state: state,
            isEnabled: isEnabled,
            isModelReady: isModelReady
        ) else { return }

        currentSession += 1
        let session = currentSession
        // Не трогаем прошлый Copy/Retry: новая запись может быть отменена или
        // завершиться ошибкой. Спасённый текст удаляется только явным действием
        // либо после успешного Retry.
        isHandsFree = handsFree
        isHandsFreeActive = handsFree
        cancellationRequested = false
        deferredStopRequested = false
        noticeAfterSession = nil
        // Цель запоминаем сразу: потом фокус уйдёт.
        targetApplication = inserter.frontmostApplication()
        state = .preparing

        Task { await startCapture(session: session) }
    }

    private func startCapture(session: Int) async {
        // Вторая проверка того же условия: между синхронной частью и этой
        // строкой прошёл переход между задачами, за который сессию могли отменить.
        guard isCurrent(session), state == .preparing, !cancellationRequested else {
            await finishWithoutInsertion(session: session)
            return
        }

        do {
            _ = try await capture.startRecording()
        } catch {
            await fail(session: session, with: .capture(String(describing: error)))
            return
        }

        // После ожидания состояние проверяется снова — отмена могла прийти
        // ровно в момент запуска движка.
        guard isCurrent(session), state == .preparing, !cancellationRequested else {
            // Запись успела пойти, а сессии уже нет. Свой микрофон гасим —
            // иначе он останется включённым, и остановить его будет нечем, —
            // но уборку не делаем: она принадлежит той сессии, что идёт сейчас.
            await capture.abortRecording()
            await finishWithoutInsertion(session: session)
            return
        }

        recordingStartedAt = now()
        state = .listening
        await overlay.present(.listening, elapsed: 0)

        // Отпускание, пришедшее пока поднимался движок, обрабатываем здесь —
        // ровно один раз. Раньше сигнала намеренно: ждать первого кадра ради
        // звука «говорите» в записи, которая уже кончилась, незачем, а
        // отложить из-за ожидания остановку значило бы держать микрофон
        // включённым на молчащем устройстве, пока кадр не придёт, — а он
        // может не прийти вовсе.
        if deferredStopRequested {
            deferredStopRequested = false
            finish()
            return
        }

        // Звук — только когда микрофон действительно начал отдавать кадры.
        // Движок запускается раньше, чем начинает слышать: между этими
        // моментами около десятой доли секунды, и человек, начинающий
        // говорить по сигналу, терял в неё первое слово.
        guard await capture.waitForFirstFrame() else { return }
        // Пока ждали кадр, сессию могли закрыть или начать следующую.
        guard isCurrent(session), state == .listening else { return }
        await sounds.playStart()
    }

    // MARK: - Остановка

    /// Отпущена горячая клавиша (или нажата второй раз в режиме громкой связи).
    public func stop() {
        switch DictationStopPolicy.decideStop(state: state, isHandsFree: isHandsFree) {
        case .stopNow:
            finish()
        case .deferUntilListening:
            deferredStopRequested = true
        case .ignore, .noSession:
            break
        }
    }

    /// Остановка в режиме без удержания — вторым нажатием клавиши.
    public func stopHandsFree() {
        guard isHandsFree else { return }

        switch state {
        case .listening:
            finish()
        case .preparing:
            // То же самое, что и с отпусканием клавиши, только нажатием: второе
            // нажатие успело прийти раньше, чем поднялся движок. Потерять его
            // нельзя — в этом режиме клавишу не держат, и остановить запись
            // больше нечем: микрофон работал бы до часового предела.
            deferredStopRequested = true
        case .idle, .transcribing, .inserting:
            break
        }
    }

    /// Перевести идущую сессию в режим без удержания.
    ///
    /// Двойное нажатие приходит уже после того, как первое запустило сессию, а
    /// первое отпускание попыталось её закончить. Начать новую в этот момент
    /// нельзя — она бы не прошла проверку на свободное состояние, и режим
    /// оставался бы недостижимым. Поэтому переключаем текущую.
    ///
    /// Отложенное отпускание сбрасывается: оно относилось к прошлому жесту, а в
    /// новом режиме клавишу и положено отпускать.
    public func promoteToHandsFree() {
        guard state == .preparing || state == .listening else { return }
        isHandsFree = true
        isHandsFreeActive = true
        deferredStopRequested = false
    }

    private func finish() {
        // Финализация запускается ровно один раз: иначе текст вставится дважды.
        guard finalizationTask == nil, state == .listening else { return }

        // Один вход на все четыре пути остановки: stop, stopHandsFree,
        // отложенное отпускание и часовой предел — все приходят сюда.
        stopRequestedAt = monotonicNow()
        let session = currentSession
        state = .transcribing
        let task = Task { [weak self] in
            await self?.finalize(session: session)
            await MainActor.run { self?.forgetFinalization(session: session) }
        }
        finalizationTask = task
    }

    /// Забыть завершившуюся задачу — но только если это всё ещё наша сессия.
    private func forgetFinalization(session: Int) {
        guard isCurrent(session) else { return }
        finalizationTask = nil
    }

    private func finalize(session: Int) async {
        await overlay.present(.transcribing, elapsed: elapsedSeconds())

        let recording: (url: URL, duration: TimeInterval)
        do {
            recording = try await capture.stopRecording()
        } catch {
            await fail(session: session, with: .capture(String(describing: error)))
            return
        }

        await sounds.playStop()

        guard shouldContinue(session) else {
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        }

        // Нажал и сразу отпустил — распознавать нечего. Движок на таких
        // записях отказывается работать, но показывать из-за этого ошибку
        // неправильно: человек просто передумал.
        guard DictationDurationPolicy.isWorthTranscribing(duration: recording.duration) else {
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        }

        let recognized: ASRResult
        do {
            recognized = try await transcribe(recording.url)
        } catch is CancellationError {
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        } catch let error as ASREngineError where error == .cancelled {
            // Отмена, дошедшая через движок: это не сбой, сообщать не о чем.
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        } catch {
            // Отмена, пришедшая пока работал движок, главнее его сбоя. Иначе
            // Escape оставлял бы ровно тот след, от которого избавляет:
            // сохранённый для Retry голос и сообщение о сбое — уже поверх той
            // сессии, которую человек начал следом.
            guard shouldContinue(session) else {
                await discard(recording.url)
                await finishWithoutInsertion(session: session)
                return
            }
            let saved: URL?
            let suffix: String
            do {
                saved = try await recordingRecovery.preserve(recording.url)
                suffix = saved == nil
                    ? " Couldn't save the recording for retry."
                    : " The recording is saved locally — you can retry or delete it."
            } catch {
                saved = nil
                suffix = " The recording is still on disk, but preparing Retry/Delete failed: \(error.localizedDescription)"
            }
            let notice = DictationNotice(
                kind: .failure,
                message: DictationError.recognition(String(describing: error)).userMessage + suffix,
                recoveryAudio: saved
            )
            await report(notice)
            await cleanup(session: session)
            return
        }

        // Проверка после каждого ожидания: пока шло распознавание, пользователь
        // мог нажать отмену.
        guard shouldContinue(session) else {
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        }

        // t1: движок вернул текст. Снимается до всех проверок ниже, чтобы в
        // число не попало наше собственное ветвление.
        let recognizedAt = monotonicNow()
        let microphoneStartup = await capture.startupLatency()

        let run = pipeline().run(recognized.text)
        let processed = run.output
        guard !processed.text.isEmpty else {
            // Пустой результат — не ошибка: человек мог промолчать, говорить
            // слишком тихо или в не тот микрофон. Но и молчать в ответ нельзя:
            // погасшая панель без текста неотличима от «вставилось не туда», и
            // человек идёт искать пропавшую фразу в чужом окне. Слишком
            // короткое нажатие сюда не попадает — оно отсеяно выше и объяснения
            // не требует.
            await discard(recording.url)
            let notice = DictationNotice(
                kind: .info,
                message: "Nothing was recognized — nothing was inserted."
            )
            await report(notice)
            await cleanup(session: session)
            return
        }

        await insert(
            processed,
            provenance: run.provenance,
            recognizedAt: recognizedAt,
            microphoneStartup: microphoneStartup,
            session: session
        )
        await discard(recording.url)
    }

    /// Собрать отчёт о скорости и отдать его наружу.
    ///
    /// Без отметки отпускания отчёта нет вовсе: посчитать «stop → текст» не от
    /// чего, а показать число, посчитанное от чего-то другого, — соврать.
    private func reportSpeed(
        recognizedAt: ContinuousClock.Instant,
        marks: InsertionMarks,
        microphoneStartup: Duration?
    ) {
        guard let onSpeed, let stopRequestedAt else { return }
        onSpeed(
            DictationSpeedReport(
                toRecognizedText: stopRequestedAt.duration(to: recognizedAt),
                toPasteDispatched: marks.pasteDispatchedAt.map { stopRequestedAt.duration(to: $0) },
                toClipboardRestored: marks.clipboardRestoredAt.map { stopRequestedAt.duration(to: $0) },
                microphoneStartup: microphoneStartup
            )
        )
    }

    private func insert(
        _ output: TextPipeline.Output,
        provenance: PipelineProvenance,
        recognizedAt: ContinuousClock.Instant,
        microphoneStartup: Duration?,
        session: Int
    ) async {
        state = .inserting
        await overlay.present(.inserting, elapsed: elapsedSeconds())

        // Последняя точка, где отмена ещё возможна. Дальше событие уходит в
        // чужое приложение и не отзывается.
        guard shouldContinue(session) else {
            await finishWithoutInsertion(session: session)
            return
        }

        let marks: InsertionMarks
        do {
            marks = try await inserter.insertReportingMarks(output.text, into: targetApplication)
        } catch {
            await handleInsertionFailure(error, text: output.text, session: session)
            return
        }
        onTextInserted?(output.text)
        // Происхождение — только после успешной вставки: у неудачной нет
        // «того, что человек увидел», и «скопировать дословно» ей нечего дать.
        onDictationCompleted?(provenance)
        reportSpeed(recognizedAt: recognizedAt, marks: marks, microphoneStartup: microphoneStartup)

        // Нажатие разбирается отдельно от вставки намеренно. Это разные
        // системные вызовы, и второй отказывает при живом первом — например,
        // когда пользователь так и не отпустил модификатор.
        if output.command == .pressReturn {
            do {
                try await inserter.pressReturn()
            } catch {
                await reportReturnFailure(session: session)
                return
            }
        }
        await cleanup(session: session)
    }

    /// Текст вставлен, а Return нажать не вышло.
    ///
    /// Общая ветка отказа здесь соврала бы дважды: сказала бы «текст не
    /// вставлен», когда он на месте, и сохранила бы вторую копию продиктованного
    /// на диск. Приватный инструмент не складывает сказанное без причины.
    private func reportReturnFailure(session: Int) async {
        let notice = DictationNotice(
            kind: .warning,
            message: "The text was inserted, but pressing Return failed."
        )
        await report(notice)
        await cleanup(session: session)
    }

    /// Текст распознан, но вставить не удалось — сохраняем, чтобы он не пропал.
    private func handleInsertionFailure(_ error: Error, text: String, session: Int) async {
        if let insertion = error as? TextInsertionError,
           insertion == .insertedButClipboardRestoreFailed {
            let notice = DictationNotice(
                kind: .warning,
                message: "The text was inserted, but the previous clipboard couldn't be restored."
            )
            await report(notice)
            await cleanup(session: session)
            return
        }
        pendingRecovery = RecoveredDictation(text: text)

        let message: String
        if let insertion = error as? TextInsertionError, insertion == .secureInputActive {
            // Не сбой, а нормальная ситуация: активно поле пароля.
            message = "Text not inserted: secure input is active. Copy and Retry are in the menu."
        } else if let insertion = error as? TextInsertionError, insertion == .protectedClipboard {
            // После перехода на снимок «любые байты как есть» сюда попадают
            // только пароль из менеджера, file promise и буфер больше 16 МиБ.
            message = "Your clipboard holds a password or a file — it was left untouched. Your text: Copy and Retry in the menu."
        } else {
            message = "The text couldn't be inserted. Copy and Retry are in the menu."
        }

        let notice = DictationNotice(kind: .warning, message: message, recoverableText: text)
        await report(notice)
        await cleanup(session: session)
    }

    // MARK: - Отмена

    /// Отменить диктовку.
    public func cancel() {
        guard DictationStopPolicy.canCancel(state: state) else { return }

        // Порядок важен: сначала флаг, потом отмена задачи. Отмена задачи не
        // прерывает уже идущее ожидание, а флаг проверяется после каждого из них.
        cancellationRequested = true
        finalizationTask?.cancel()

        let session = currentSession
        Task { [weak self] in
            await self?.capture.abortRecording()
            await self?.finishWithoutInsertion(session: session)
        }
    }

    /// Запись сорвалась сама — например, на диске кончилось место.
    ///
    /// Это не отмена: пользователь ничего не нажимал и продолжает говорить.
    /// Поэтому останавливаемся сразу и объясняем причину, а не ждём, пока он
    /// договорит фразу, которую уже некуда записывать.
    public func interrupt(reason message: String) {
        guard state == .preparing || state == .listening else { return }

        cancellationRequested = true
        finalizationTask?.cancel()

        let notice = DictationNotice(kind: .failure, message: message)
        noticeAfterSession = nil
        onNotice?(notice)

        let session = currentSession
        Task { [weak self] in
            guard let self else { return }
            await self.overlay.presentNotice(notice)
            await self.capture.abortRecording()
            await self.finishWithoutInsertion(session: session)
        }
    }

    /// Системное разрешение или устройство исчезло во время записи.
    /// Закрываем WAV и сохраняем его для явного Retry/Delete, не пытаясь
    /// распознавать или вставлять в уже недоверенное состояние системы.
    public func preserveActiveRecording(reason message: String) {
        guard state == .preparing || state == .listening else { return }
        if state == .preparing {
            cancel()
            let notice = DictationNotice(kind: .failure, message: message)
            noticeAfterSession = nil
            onNotice?(notice)
            Task { await overlay.presentNotice(notice) }
            return
        }
        guard finalizationTask == nil else { return }

        let session = currentSession
        state = .transcribing
        let task = Task { [weak self] in
            guard let self else { return }
            let recording: (url: URL, duration: TimeInterval)?
            do {
                recording = try await self.capture.stopRecording()
                await self.sounds.playStop()
            } catch {
                recording = nil
            }

            // Пока закрывался файл, человек мог нажать Escape. С этого момента
            // у диктовки один исход — отмена, и она главнее спасения: закрытый
            // WAV уже не удалит прерывание записи, а спасённый лёг бы в папку
            // повтора вопреки обещанию «отменённая диктовка удалена». Заодно
            // молчим: сообщение о сбое упало бы поверх той сессии, которую
            // человек начал следом.
            guard !Task.isCancelled else {
                if let recording { await self.discard(recording.url) }
                await self.cleanup(session: session)
                return
            }

            var saved: URL?
            if let recording {
                saved = try? await self.recordingRecovery.preserve(recording.url)
            }
            let notice = DictationNotice(
                kind: .failure,
                message: saved == nil
                    ? message + " Couldn't save the recording for retry."
                    : message + " The recording is saved locally — you can retry or delete it.",
                recoveryAudio: saved
            )
            await self.report(notice)
            await self.cleanup(session: session)
        }
        finalizationTask = task
    }

    // MARK: - Завершение

    /// Идёт ли ещё та сессия, ради которой начиналось ожидание.
    private func isCurrent(_ session: Int) -> Bool { session == currentSession }

    private func shouldContinue(_ session: Int) -> Bool {
        guard isCurrent(session) else { return false }
        return DictationFinalizationPolicy.shouldContinue(
            state: state,
            cancellationRequested: cancellationRequested,
            taskCancelled: Task.isCancelled
        )
    }

    private func fail(session: Int, with error: DictationError) async {
        // Сбой отменённой сессии показывать не за что: человек её уже закрыл, а
        // сообщение упало бы поверх той, что идёт сейчас.
        guard isCurrent(session) else { return }

        let notice = DictationNotice(kind: .failure, message: error.userMessage)
        await report(notice)
        await cleanup(session: session)
    }

    private func finishWithoutInsertion(session: Int) async {
        await cleanup(session: session)
    }

    /// Уборка после сессии — в строгом порядке.
    ///
    /// Микрофон гасится здесь и только здесь: обещание «индикатор записи не
    /// горит, пока мы не слушаем» держится на том, что этот метод вызывается
    /// на каждом пути завершения, включая ошибки и отмену.
    ///
    /// Убирать разрешено только за собственной сессией: хвост предыдущей,
    /// проснувшийся после отмены, иначе погасил бы уже идущую новую.
    private func cleanup(session: Int) async {
        guard isCurrent(session) else { return }

        finalizationTask = nil
        deferredStopRequested = false
        cancellationRequested = false
        isHandsFree = false
        isHandsFreeActive = false
        targetApplication = nil
        recordingStartedAt = nil
        // Отметка отпускания обнуляется вместе с остальным состоянием сессии.
        // Иначе t0 отменённой диктовки протёк бы в следующую, и та отчиталась
        // бы о времени, включающем чужое ожидание.
        stopRequestedAt = nil
        state = .idle

        // Отложенное сообщение показываем здесь — когда панель уже свободна.
        if let pending = noticeAfterSession {
            noticeAfterSession = nil
            onNotice?(pending)
            await overlay.presentNotice(pending)
        } else {
            await overlay.dismiss()
        }
    }

    private func elapsedSeconds() -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return now().timeIntervalSince(recordingStartedAt)
    }

    /// Показать сообщение: и подписчику, и на панели.
    ///
    /// Единственный выход сообщений наружу из ядра. Здесь же снимается
    /// отложенное: у сессии одна причина конца, а не две, и объяснение
    /// часового предела не имеет права затереть рассказ о сбое.
    private func report(_ notice: DictationNotice) async {
        noticeAfterSession = nil
        onNotice?(notice)
        await overlay.presentNotice(notice)
    }

    /// Убрать запись с диска.
    ///
    /// Отдельным методом, чтобы удаление нельзя было случайно пропустить на
    /// одной из веток завершения: голос пользователя не должен оставаться в
    /// файлах после того, как текст распознан.
    private func discard(_ url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let notice = DictationNotice(
                kind: .failure,
                message: "Couldn't delete the local recording: \(error.localizedDescription)"
            )
            await report(notice)
        }
    }

    /// Достигнут ли предел длительности — проверяется таймером снаружи.
    public func checkDurationLimit() {
        guard state == .listening else { return }
        if DictationDurationPolicy.action(elapsed: elapsedSeconds()) == .stopAndTranscribe {
            // Показать сейчас нельзя: `finish()` тут же перерисует панель под
            // «распознаю». А только через `onNotice` — значит никуда: панель
            // сообщений от подписчика не показывает, и объяснение обрыва на
            // полуслове не доходило вовсе.
            noticeAfterSession = DictationNotice(
                kind: .info,
                message: "Reached the one-hour limit. Transcribing what was recorded."
            )
            finish()
        }
    }
}

/// Ошибки, которые видит пользователь.
///
/// Отказ вставки сюда не входит намеренно: текст в этот момент уже распознан и
/// остаётся в памяти, и человеку надо сказать не «не удалось», а как получить
/// его через Copy/Retry. Это делает `handleInsertionFailure`.
public enum DictationError: Error, Sendable, Equatable {
    case capture(String)
    case recognition(String)

    public var userMessage: String {
        switch self {
        case .capture:
            return "Couldn't record audio."
        case .recognition:
            return "Couldn't transcribe speech."
        }
    }
}
