import AVFAudio
import CoreML
import DictationCore
import FluidAudio
import Foundation

/// Какой файл энкодера грузить.
///
/// В репозитории модели их два. Имена — из терминов библиотеки, а не описание
/// квантизации: `Encoder.mlmodelc` квантизован 6-битной палитрой (так и указано
/// в атрибуции CC BY), `EncoderInt4.mlmodelc` — четырёхбитной.
public enum EncoderVariant: String, Sendable, CaseIterable {
    case palettized6bit
    case int4
}

/// На чём считать энкодер.
///
/// Препроцессор библиотека всегда пришивает к CPU, декодер и joint идут на
/// нейромодуль. Настраивается только энкодер — самая тяжёлая часть.
public enum EncoderPlacement: String, Sendable, CaseIterable {
    case neuralEngine
    case gpu
}

/// Единственное место во всём проекте, где импортируется FluidAudio.
///
/// Всё остальное — включая контроллер диктовки и его тесты — работает через
/// `ASREngineAdapting` из DictationCore. Если API библиотеки поедет (а её
/// документация местами расходится с тегом), чинить придётся только этот файл.
public actor FluidAudioAdapter: ASREngineAdapting {
    private var models: AsrModels?
    private var manager: AsrManager?

    /// Собранный подсказчик терминов: всё, что нужно одному распознаванию.
    ///
    /// Пять полей вместо одного означали бы, что их можно подменить по
    /// отдельности. Здесь их подменяют только целиком, и распознавание берёт
    /// снимок один раз — иначе правка словаря в середине диктовки успела бы
    /// подсунуть улики от одного набора терминов и правило замены от другого.
    private struct VocabularyHelper: Sendable {
        let spotter: CtcKeywordSpotter
        let context: CustomVocabularyContext
        let rescorer: VocabularyRescorer
        let sizeConfig: ContextBiasingConstants.VocabSizeConfig
        let biasWeight: Float
    }

    // Акустический подсказчик терминов: CTC-модель ищет термины в звуке,
    // rescorer правит текст TDT по её уликам. Всё опционально: без явной
    // загрузки распознавание работает ровно как раньше.
    private var vocabulary: VocabularyHelper?

    /// Веса CTC-модели и её токенизатор. Держатся отдельно от набора терминов,
    /// потому что переживают его правку: список меняется часто, веса — никогда.
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
    private var ctcDirectory: URL?

    // Живой предпросмотр: pseudo-streaming менеджер на тех же весах, что и
    // batch-путь. Его текст — только для глаз во время речи; источником
    // истины остаётся batch-распознавание готовой записи.
    private var previewManager: SlidingWindowAsrManager?
    private var previewTask: Task<Void, Never>?

    /// Идёт ли прямо сейчас запуск предпросмотра, и какой именно.
    ///
    /// Поколение решает спор между запуском и остановкой, попавшей внутрь него:
    /// запуск, чьё поколение успело устареть, свой менеджер не устанавливает.
    private var previewStarting = false
    private var previewGeneration = 0

    /// Состояние декодера TDT.
    ///
    /// Библиотека требует его как `inout` и переиспользует между вызовами для
    /// потокового режима. У нас режим другой: каждая диктовка самостоятельна,
    /// поэтому состояние создаётся заново перед каждым распознаванием — иначе
    /// хвост предыдущей фразы протёк бы в следующую. Создание может бросить
    /// ошибку, поэтому хранится опционально.
    private var decoderState: TdtDecoderState?

    /// Приклеивать ли 80 мс предыдущего окна к следующему.
    ///
    /// У библиотеки этот флаг включён по умолчанию: на английской речи он лечит
    /// пустые предсказания на стыке окон. На многоязычной v3 он делает обратное,
    /// и об этом написано в самой библиотеке (issue #594): сдвиг распределения
    /// первого кадра уводит декодер к английскому приору, и текст на стыке
    /// **молча пропадает**.
    ///
    /// Здесь он выключен, потому что это измерено: на восьми записях с
    /// переключением языка внутри фразы включённый флаг съедал 47 слов из 1038,
    /// выключенный — 17. Обрыв виден в тексте буквально: «The recovery pass
    /// reads.» — и конец предложения исчезает без ошибки. Параметр оставлен,
    /// чтобы замер можно было повторить (`WAI_ASR_MEL_CONTEXT` в asr-bench).
    private let melChunkContext: Bool

    /// Вариант файла энкодера. Замер обоих — в `docs/benchmarks.md`.
    private let encoder: EncoderVariant

    /// Где считается энкодер.
    private let encoderPlacement: EncoderPlacement

    /// Второй проход декодера с арбитражем на стыке окон.
    ///
    /// Библиотека держит его выключенным по умолчанию и включает только для
    /// пути «v3 без mel-контекста» — то есть ровно для нашего. Стоит времени,
    /// поэтому включён по результату замера, а не по описанию.
    private let dualDecodeArbitration: Bool

    /// Потолок токенов на одно окно у TDT-декодера.
    ///
    /// Библиотека ставит 150 и при превышении **молча обрывает разбор окна** —
    /// `break` из цикла, без ошибки и без следа в тексте. Симптом тот же, что у
    /// уже вылеченного mel-контекста: у фразы пропадает середина.
    ///
    /// 150 хватает не всегда. Счётчик считает все раскодированные токены окна,
    /// включая двухсекундное перекрытие, которое в текст не попадает, — то есть
    /// бюджет на новую речь меньше числа в настройке. На плотной русской речи
    /// (340 слов в минуту, запись длиннее одного окна) потолок срабатывал и
    /// съедал куски: «каждый обработчик бе **Пока не закончит**». WER такой
    /// записи 9,8% против 4,3% без обрыва.
    ///
    /// 600 выбрано замером: 200 уже достаточно на самой плотной речи, которую
    /// удалось синтезировать, дальше текст не меняется вовсе; 600 даёт тройной
    /// запас и при этом остаётся втрое ниже теоретического максимума окна
    /// (187 кадров × 10 токенов на кадр = 1870), то есть защита от зацикливания
    /// декодера сохраняется. На корпусе текст не изменился ни в одном символе,
    /// скорость тоже. Цифры — в `docs/benchmarks.md`.
    private let maxTokensPerChunk: Int

    public init(
        melChunkContext: Bool = false,
        encoder: EncoderVariant = .palettized6bit,
        encoderPlacement: EncoderPlacement = .neuralEngine,
        dualDecodeArbitration: Bool = false,
        maxTokensPerChunk: Int = 600
    ) {
        self.melChunkContext = melChunkContext
        self.encoder = encoder
        self.encoderPlacement = encoderPlacement
        self.dualDecodeArbitration = dualDecodeArbitration
        self.maxTokensPerChunk = maxTokensPerChunk
    }

    /// Для теста, который сторожит выбранный потолок.
    var chunkTokenCeiling: Int { maxTokensPerChunk }

    /// Для теста, который сторожит выбранное значение флага.
    var usesMelChunkContext: Bool { melChunkContext }

    /// Загрузить модель из подготовленной директории.
    ///
    /// Сети здесь нет: `AsrModels.load(from:)` читает уже разложенные бандлы.
    /// Это подтверждено документацией библиотеки (Documentation/ASR/ManualModelLoading.md)
    /// и проверяется отдельным прогоном в песочнице с запрещённой сетью.
    public func loadModels(from directory: URL) async throws {
        // Wai Dictation управляет моделью самостоятельно: пользователь явно
        // скачивает зафиксированный manifest, после чего каждый файл проверяется
        // по SHA-256. FluidAudio не должен пытаться «починить» повреждение своей
        // сетевой загрузкой. Флаг ставится здесь — на единственной границе импорта
        // FluidAudio — до любого loader во всех клиентах LocalASR, включая bench.
        ModelHub.offlineMode = true
        guard models == nil else { return }

        // `.int8` — это имя варианта файла в терминах библиотеки
        // (Encoder.mlmodelc против EncoderInt4.mlmodelc), а не описание квантизации.
        // Фактически этот энкодер квантизован 6-битной палитрой — так и указано в
        // атрибуции лицензии CC BY.
        let precision: ParakeetEncoderPrecision = encoder == .int4 ? .int4 : .int8

        guard AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: precision) else {
            throw ASREngineError.modelsUnavailable(
                "\(directory.lastPathComponent) doesn't contain the full set of Parakeet v3 bundles"
            )
        }

        do {
            let loaded = try await AsrModels.load(
                from: directory,
                version: .v3,
                encoderPrecision: precision,
                encoderComputeUnits: encoderPlacement == .gpu ? .cpuAndGPU : nil
            )
            let manager = AsrManager(
                config: ASRConfig(
                    tdtConfig: TdtConfig(maxTokensPerChunk: maxTokensPerChunk),
                    melChunkContext: melChunkContext,
                    dualDecodeArbitration: dualDecodeArbitration
                )
            )
            try await manager.loadModels(loaded)

            self.models = loaded
            self.manager = manager
        } catch {
            throw ASREngineError.modelsUnavailable(error.localizedDescription)
        }
    }

    /// Test seam: подтверждает, что настройка принадлежит адаптеру, а не одному
    /// из вызывающих приложений. Не используйте её вместо `loadModels` в runtime.
    static func enforceOfflineMode() {
        ModelHub.offlineMode = true
    }

    /// Загрузить или пересобрать акустический подсказчик терминов.
    ///
    /// Вызывается и при прогреве, и каждый раз, когда человек поправил словарь:
    /// набор терминов пересобирается на живом адаптере, веса CTC-модели при
    /// этом остаются загруженными. Раньше здесь стоял `guard spotter == nil`,
    /// и из-за него правка словаря доходила до текстовых замен сразу, а до
    /// акустики — только после перезапуска приложения. Словарь вёл себя
    /// по-разному в двух своих половинах, и объяснить это человеку было нечем.
    ///
    /// Пустой список — осознанное «выключено»: подсказчик снимается, веса
    /// отпускаются, распознавание идёт как без него. Это тоже правка словаря:
    /// человек стёр все термины и вправе увидеть результат сразу.
    ///
    /// Сети здесь нет по той же схеме, что и у основной модели:
    /// `CtcModels.loadDirect(from:)` читает уже разложенные бандлы
    /// (MelSpectrogram.mlmodelc, AudioEncoder.mlmodelc, vocab.json) и падает,
    /// если их не хватает.
    public func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws {
        ModelHub.offlineMode = true

        guard !boost.isEmpty else {
            vocabulary = nil
            ctcModels = nil
            ctcTokenizer = nil
            ctcDirectory = nil
            return
        }

        // Веса и токенизатор переживают правку списка. Грузим их только когда
        // их ещё нет либо когда сменилась папка.
        let models: CtcModels
        let tokenizer: CtcTokenizer
        if let ctcModels, let ctcTokenizer, ctcDirectory == directory {
            models = ctcModels
            tokenizer = ctcTokenizer
        } else {
            do {
                models = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
                tokenizer = try await CtcTokenizer.load(from: directory)
            } catch {
                throw ASREngineError.modelsUnavailable(error.localizedDescription)
            }
            ctcModels = models
            ctcTokenizer = tokenizer
            ctcDirectory = directory
        }

        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)

        // Термин без CTC-токенов rescorer молча пропускает — токенизация
        // здесь обязательна, это и есть включение термина в подсказки.
        var terms: [CustomVocabularyTerm] = []
        for (index, term) in boost.terms.enumerated() {
            let tokenIds = tokenizer.encode(term.text)
            guard !tokenIds.isEmpty else {
                // Текст термина в ошибку не попадает намеренно: содержимое
                // словаря — данные человека, как и текст диктовки.
                throw VocabularyBoostError.termNotTokenizable(index: index + 1)
            }
            terms.append(
                CustomVocabularyTerm(
                    text: term.text,
                    aliases: term.aliases.isEmpty ? nil : term.aliases,
                    ctcTokenIds: tokenIds
                )
            )
        }

        let context = CustomVocabularyContext(terms: terms, minSimilarity: boost.minSimilarity)
        // Акустический rescue-проход выключен намеренно: он заменяет слова
        // по одной акустической улике, минуя порог похожести, и на нашем
        // корпусе именно он превращал «в центре» в Sentry и «комету» в
        // commit. Сама библиотека рекомендует выключать его для коротких
        // словарей (#702, #724); наш — десятки терминов, не сотни.
        let rescorer: VocabularyRescorer
        do {
            rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: context,
                config: VocabularyRescorer.Config(
                    spotterRescueMinSimilarity: 0.5,
                    spotterRescueMultiWordMinSimilarity: 0.5,
                    spotterRescueEnabled: false
                ),
                ctcModelDirectory: directory
            )
        } catch {
            throw ASREngineError.modelsUnavailable(error.localizedDescription)
        }

        // Подмена целиком и последним действием: распознавание, начатое до
        // этой строки, доработает на прежнем наборе, следующее возьмёт новый.
        vocabulary = VocabularyHelper(
            spotter: spotter,
            context: context,
            rescorer: rescorer,
            sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count),
            biasWeight: boost.biasWeight
        )
    }

    /// Сколько терминов сейчас в акустическом наборе. Нужно тесту, который
    /// сторожит пересборку набора без перезапуска.
    var boostedTermCount: Int { vocabulary?.context.terms.count ?? 0 }

    /// Начать живой предпросмотр. Требует загруженной основной модели: веса
    /// делятся между batch-распознаванием и предпросмотром, второй копии нет.
    ///
    /// **Язык предпросмотру передать нечем.** Потоковый менеджер библиотеки
    /// 0.15.5 не принимает подсказку языка вовсе — ни в конфигурации, ни в
    /// `startStreaming`. Поэтому предпросмотр всегда идёт на автоопределении,
    /// даже когда человек выбрал язык явно, и текст перед глазами может
    /// разойтись с итоговым. Чинится это только со стороны библиотеки;
    /// источником истины остаётся batch-распознавание, и оно язык уважает.
    public func startPreview(
        onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
    ) async throws {
        guard let models else { throw ASREngineError.modelsNotLoaded }
        guard previewManager == nil, !previewStarting else { return }

        // Заявка на запуск ставится **до** первого await.
        //
        // Актор не держит очередь: на каждом await внутрь пускается следующий
        // вызов. Пока запуск ждал загрузку весов и старт потока, `stopPreview`
        // успевал войти, увидеть пустой `previewManager` и не сделать ничего —
        // а запуск потом доводил дело до конца. Предпросмотр оставался
        // запущенным навсегда, следующая диктовка не получала его вовсе, и
        // человек видел перед собой текст прошлой сессии.
        previewStarting = true
        previewGeneration &+= 1
        let generation = previewGeneration

        let preview = SlidingWindowAsrManager()
        do {
            try await preview.loadModels(models)
            try await preview.startStreaming(source: .microphone)
        } catch {
            if previewGeneration == generation { previewStarting = false }
            throw error
        }

        // Пока грузились, могли попросить остановиться — или начать заново.
        // Тогда этот менеджер уже никому не нужен и обязан быть свёрнут здесь,
        // иначе он останется работать в тени.
        guard previewGeneration == generation else {
            await preview.cancel()
            return
        }
        previewStarting = false
        previewManager = preview

        previewTask = Task { [weak preview] in
            guard let preview else { return }
            var lastEmit = ContinuousClock.now - .seconds(1)
            for await _ in await preview.transcriptionUpdates {
                if Task.isCancelled { break }
                // Не чаще четырёх раз в секунду: мерцание хуже задержки.
                let now = ContinuousClock.now
                guard lastEmit.duration(to: now) >= .milliseconds(250) else { continue }
                lastEmit = now
                // Семантика поля text у update меняется между режимами
                // библиотеки; собственные confirmed/volatile — стабильный
                // источник. Читаем их после каждого события.
                let confirmed = await preview.confirmedTranscript
                let volatile = await preview.volatileTranscript
                onUpdate(confirmed, volatile)
            }
        }
    }

    /// Скормить предпросмотру живые отсчёты (16 кГц, моно, Float32).
    public func feedPreview(samples: [Float]) async {
        guard let previewManager, !samples.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        await previewManager.streamAudio(buffer)
    }

    /// Остановить предпросмотр и освободить его состояние. Веса модели общие
    /// и остаются загруженными для batch-распознавания.
    ///
    /// Останавливает и запуск, который идёт прямо сейчас: смена поколения
    /// заставляет его свернуть свой менеджер вместо того, чтобы поставить его
    /// на место уже остановленного.
    public func stopPreview() async {
        previewGeneration &+= 1
        previewStarting = false
        previewTask?.cancel()
        previewTask = nil
        if let previewManager {
            await previewManager.cancel()
        }
        previewManager = nil
    }

    /// Идёт ли предпросмотр прямо сейчас. Test seam для проверки того, что
    /// остановка посреди запуска действительно останавливает.
    var isPreviewRunning: Bool { previewManager != nil }

    public func transcribe(samples: [Float]) async throws -> DictationCore.ASRResult {
        try await transcribe(samples: samples, languageHint: nil)
    }

    /// Языки, которые движок принимает как подсказку (BCP-47 коды).
    ///
    /// Список — свойство движка, а не продукта, поэтому живёт на единственной
    /// границе импорта FluidAudio. UI строит из него выбор языка.
    public static var supportedLanguageHints: [String] {
        Language.allCases.map(\.rawValue)
    }

    public func transcribe(
        samples: [Float],
        languageHint: String?
    ) async throws -> DictationCore.ASRResult {
        // Подсказка проверяется до всего остального: неизвестный код — ошибка
        // вызывающего, и она обязана быть видимой, а не молча стать «auto».
        let language: Language?
        if let languageHint {
            guard let parsed = Language(rawValue: languageHint) else {
                throw ASREngineError.inferenceFailed(
                    "unsupported language hint: \(languageHint)"
                )
            }
            language = parsed
        } else {
            language = nil
        }

        guard let manager else {
            throw ASREngineError.modelsNotLoaded
        }
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty buffer")
        }

        let started = ContinuousClock.now
        // Длительность считаем сами: библиотека в этой версии возвращает ноль,
        // а от неё зависит показатель «во сколько раз быстрее реального времени».
        let audioDuration = Double(samples.count) / AudioFileReader.targetSampleRate
        let text: String
        let timings: [TokenTiming]?
        do {
            // Набор терминов берётся один раз на всю диктовку: правка словаря
            // в середине распознавания не имеет права подменить его между
            // акустическим проходом и правкой текста.
            let helper = vocabulary

            // Акустический проход подсказчика зависит только от звука, а
            // распознавание — только от него же. Общего у них нет ничего,
            // поэтому проход стартует здесь и идёт параллельно разбору, а не
            // после него: раньше эти две работы стояли в очередь друг за другом
            // и человек ждал их сумму. Замер выигрыша — в `docs/benchmarks.md`.
            async let spotted = Self.spotKeywords(samples: samples, helper: helper)

            // Каждая диктовка независима — начинаем с чистого состояния декодера.
            var state = try TdtDecoderState()
            // nil — автоопределение по звуку. Модель покрывает 25 европейских
            // языков; жёсткий выбор ломает смешанную речь, поэтому подсказка —
            // только явный выбор человека, когда акцент уводит автоопределение.
            let result = try await manager.transcribe(
                samples,
                decoderState: &state,
                language: language
            )
            decoderState = state
            // Подсказчик правит текст по акустическим уликам CTC-модели.
            // Тайминги остаются от исходных токенов: замена слова не двигает
            // его место в записи, а потребителей пословных таймингов, которым
            // важна побуквенная точность заменённого слова, в продукте нет.
            text = Self.rescore(
                text: result.text,
                timings: result.tokenTimings,
                spotted: try await spotted,
                helper: helper
            ) ?? result.text
            timings = result.tokenTimings
        } catch is CancellationError {
            throw ASREngineError.cancelled
        } catch {
            throw ASREngineError.inferenceFailed(error.localizedDescription)
        }
        let elapsed = started.duration(to: .now)

        return DictationCore.ASRResult(
            text: text,
            words: Self.words(from: timings),
            audioDuration: audioDuration,
            processingDuration: elapsed.seconds
        )
    }

    /// Поискать термины в звуке.
    ///
    /// Не метод актора намеренно: работает по переданному снимку набора и ни к
    /// какому изменяемому состоянию не обращается — только поэтому её можно
    /// вести одновременно с разбором, не боясь правки словаря посередине.
    /// Ошибка CTC-inference при настроенном подсказчике — настоящая ошибка
    /// распознавания: человек включил термины и вправе знать, что они не
    /// сработали, а запись сохранится для Retry.
    private static func spotKeywords(
        samples: [Float],
        helper: VocabularyHelper?
    ) async throws -> CtcKeywordSpotter.SpotKeywordsResult? {
        guard let helper else { return nil }
        return try await helper.spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: helper.context,
            minScore: nil
        )
    }

    /// Поправить текст по уже добытым акустическим уликам.
    ///
    /// Возвращает `nil`, когда подсказчик не настроен или менять нечего.
    private static func rescore(
        text: String,
        timings: [TokenTiming]?,
        spotted: CtcKeywordSpotter.SpotKeywordsResult?,
        helper: VocabularyHelper?
    ) -> String? {
        guard let helper, let spotted else { return nil }
        guard let timings, !timings.isEmpty, !text.isEmpty else { return nil }
        // Пустые log-probs — это не сбой, а «звука меньше одного кадра»:
        // таким записям подсказывать нечего.
        guard !spotted.logProbs.isEmpty else { return nil }

        let output = helper.rescorer.ctcTokenRescore(
            transcript: text,
            tokenTimings: timings,
            logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration,
            cbw: helper.biasWeight,
            marginSeconds: 0.5,
            minSimilarity: max(helper.sizeConfig.minSimilarity, helper.context.minSimilarity)
        )
        guard output.wasModified else { return nil }
        // Ресорер подменяет слово вместе с прилипшим к нему знаком: на длинных
        // записях из 450 знаков доезжало 347 (docs/benchmarks.md). Возвращаем
        // потерянное, не трогая ни одного слова.
        return PunctuationReattachment.restore(original: text, rescored: output.text)
    }

    public func unload() async {
        await stopPreview()
        await manager?.cleanup()
        manager = nil
        models = nil
        decoderState = nil
        vocabulary = nil
        ctcModels = nil
        ctcTokenizer = nil
        ctcDirectory = nil
    }

    /// Склеить пословные тайминги из токенов.
    ///
    /// Parakeet отдаёт результат по токенам, а не по словам: подслова начинаются
    /// без ведущего пробела, поэтому граница слова — это токен, который таким
    /// пробелом начинается.
    static func words(from timings: [TokenTiming]?) -> [DictationCore.ASRResult.Word] {
        guard let timings, !timings.isEmpty else { return [] }

        var words: [DictationCore.ASRResult.Word] = []
        var current: (text: String, start: TimeInterval, end: TimeInterval, confidence: Double)?

        for timing in timings {
            // Библиотека отдаёт токены с ведущим "▁" либо с обычным пробелом —
            // и то, и другое означает начало нового слова.
            let raw = timing.token
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ")
            let cleaned = raw
                .replacingOccurrences(of: "▁", with: "")
                .trimmingCharacters(in: .whitespaces)

            if cleaned.isEmpty { continue }

            if startsWord, let pending = current {
                words.append(
                    .init(
                        text: pending.text,
                        start: pending.start,
                        end: pending.end,
                        confidence: pending.confidence
                    )
                )
                current = nil
            }

            if var pending = current {
                pending.text += cleaned
                pending.end = timing.endTime
                pending.confidence = min(pending.confidence, Double(timing.confidence))
                current = pending
            } else {
                current = (cleaned, timing.startTime, timing.endTime, Double(timing.confidence))
            }
        }

        if let pending = current {
            words.append(
                .init(
                    text: pending.text,
                    start: pending.start,
                    end: pending.end,
                    confidence: pending.confidence
                )
            )
        }
        return words
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
