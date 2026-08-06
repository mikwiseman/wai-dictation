import AVFoundation
import DictationCore
import Foundation
import os

/// Запись с микрофона в файл.
///
/// Движок поднимается в момент нажатия клавиши и глушится сразу после записи:
/// от этого зависит обещание «индикатор записи не горит, пока мы не слушаем».
/// Плата за это — задержка холодного старта, поэтому запуск сделан максимально
/// коротким, а звук подтверждения играет только после первого пришедшего кадра.
public actor MicrophoneCapture: AudioCapturing {
    public typealias ConverterFactory = @Sendable (AVAudioFormat, AVAudioFormat) -> AVAudioConverter?
    private let logger = Logger(subsystem: "is.waiwai.dictation", category: "capture")

    /// Куда складывать записи.
    private let directory: URL
    private let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var writeFailure: (any Error)?

    /// Очередь кадров между звуковым потоком и записью на диск.
    private let sink = FrameSink()
    private var isStopping = false

    /// Время прихода первого кадра — по нему меряется задержка старта.
    private var firstBufferAt: ContinuousClock.Instant?
    private var startedAt: ContinuousClock.Instant?

    /// Ожидающие первого кадра — им отвечает `waitForFirstFrame()`.
    ///
    /// Каждый пробуждается ровно один раз: либо пришедшим кадром, либо концом
    /// записи. Второго источника пробуждения нет намеренно — забытое здесь
    /// продолжение подвесило бы старт диктовки.
    private var firstFrameWaiters: [CheckedContinuation<Bool, Never>] = []

    /// Запись сорвалась прямо во время речи.
    ///
    /// Молчать до остановки нельзя: закончившееся место на диске человек иначе
    /// обнаружит через пять минут говорения — и текста уже не будет.
    private let onFailure: @Sendable (AudioCaptureError) -> Void
    /// Слушатель живых отсчётов — для предпросмотра распознавания.
    ///
    /// Зовётся после конвертации в целевой формат, уже вне аудиопотока, в том
    /// же порядке, в каком отсчёты уходят в WAV. Файл остаётся источником
    /// истины: слушатель ничего не решает, он только смотрит.
    private let onSamples: @Sendable ([Float]) -> Void
    private let converterFactory: ConverterFactory

    public init(
        directory: URL,
        onFailure: @escaping @Sendable (AudioCaptureError) -> Void = { _ in },
        onSamples: @escaping @Sendable ([Float]) -> Void = { _ in },
        converterFactory: @escaping ConverterFactory = { AVAudioConverter(from: $0, to: $1) }
    ) {
        self.directory = directory
        self.onFailure = onFailure
        self.onSamples = onSamples
        self.converterFactory = converterFactory
    }

    /// Сколько прошло от запуска движка до первого реального кадра звука.
    ///
    /// Это и есть та величина, из-за которой срезается первое слово. Значение
    /// считалось с самого начала, но его никто не читал: наружу оно выходит
    /// через `AudioCapturing`, и только теперь у него появился потребитель.
    ///
    /// `stopRecording` эти отметки не сбрасывает — их обнуляет только новый
    /// `startRecording`, поэтому читать после остановки законно.
    public func startupLatency() async -> Duration? {
        guard let startedAt, let firstBufferAt else { return nil }
        return startedAt.duration(to: firstBufferAt)
    }

    /// Первый кадр уже пришёл — или его не будет.
    ///
    /// Ждать безопасно: продолжение регистрируется и отпускает актор, поэтому
    /// остановка и прерывание записи проходят и будят ожидающих.
    public func waitForFirstFrame() async -> Bool {
        if firstBufferAt != nil { return true }
        guard engine != nil else { return false }
        return await withCheckedContinuation { continuation in
            firstFrameWaiters.append(continuation)
        }
    }

    private func wakeFirstFrameWaiters(arrived: Bool) {
        guard !firstFrameWaiters.isEmpty else { return }
        let waiting = firstFrameWaiters
        firstFrameWaiters = []
        for waiter in waiting { waiter.resume(returning: arrived) }
    }

    public func startRecording() async throws -> URL {
        guard engine == nil else { throw AudioCaptureError.engineUnavailable("recording is already in progress") }

        // Ждущие от прошлой записи (если такие остались) больше не дождутся её
        // кадра: их запись кончилась.
        wakeFirstFrameWaiters(arrived: false)
        startedAt = .now
        firstBufferAt = nil
        writeFailure = nil

        let url = directory.appending(
            path: "take-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).wav",
            directoryHint: .notDirectory
        )
        let writer = WAVWriter(url: url, sampleRate: Int(sampleRate), channels: 1)
        do {
            try writer.open()
        } catch {
            throw AudioCaptureError.writeFailed(String(describing: error))
        }
        self.writer = writer

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            writer.discard()
            self.writer = nil
            throw AudioCaptureError.engineUnavailable("microphone unavailable")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            writer.discard()
            self.writer = nil
            throw AudioCaptureError.engineUnavailable("couldn't create the recording format")
        }

        // Ресемплинг нужен почти всегда: встроенный микрофон отдаёт 44,1 или 48 кГц,
        // а распознавание ждёт 16 кГц.
        do {
            self.converter = try Self.converter(
                from: inputFormat,
                to: targetFormat,
                factory: converterFactory
            )
        } catch {
            writer.discard()
            self.writer = nil
            throw error
        }

        let enqueue = await sink.start { [weak self] samples in
            await self?.consume(samples)
        }

        let converter = self.converter
        let failureHandler = onFailure
        let conversionFailure = FailureOnce()
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            // Колбэк приходит на потоке звукового движка — уносим данные в очередь
            // как обычный массив, а не как буфер, который нельзя передавать между
            // изоляциями. Кладём синхронно: очередь и есть гарантия порядка.
            do {
                let samples = try Self.extractSamples(from: buffer, using: converter, target: targetFormat)
                guard !samples.isEmpty else { return }
                enqueue(samples)
            } catch {
                conversionFailure.run {
                    failureHandler(
                        .unsupportedAudioFormat(
                            "audio conversion failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            await sink.cancel()
            writer.discard()
            self.writer = nil
            self.converter = nil
            throw AudioCaptureError.engineUnavailable(error.localizedDescription)
        }

        self.engine = engine
        return url
    }

    private func consume(_ samples: [Float]) {
        if firstBufferAt == nil {
            firstBufferAt = .now
            // Только теперь микрофон действительно слышит: до этой строки звук
            // подтверждения обманывал бы человека на десятую долю секунды, и
            // первое слово уходило бы в тишину.
            wakeFirstFrameWaiters(arrived: true)
        }
        onSamples(samples)
        guard let writer, writeFailure == nil else { return }
        do {
            try writer.append(samples)
        } catch {
            // Диск кончился или файл недоступен — запись дальше бессмысленна.
            // Останавливает диктовку владелец, но узнать об этом он должен
            // сейчас, а не когда человек договорит.
            writeFailure = error
            logger.error("Recording interrupted: \(String(describing: error), privacy: .public)")
            onFailure(.writeFailed(String(describing: error)))
        }
    }

    public func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        guard let engine, writer != nil, !isStopping else { throw AudioCaptureError.notRecording }
        isStopping = true
        defer { isStopping = false }
        // Кадра можно больше не ждать: запись кончается. Иначе старт сессии,
        // повисший на молчащем устройстве, не отпустил бы никогда.
        wakeFirstFrameWaiters(arrived: false)

        // Сначала глушим движок, потом снимаем отвод: кадр, уже вышедший из
        // железа, успевает дойти до очереди.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.converter = nil

        // Здесь дописывается хвост записи. Без ожидания файл закрылся бы раньше
        // последних кадров — из фразы пропадало бы последнее слово, а именно на
        // нём человек и отпускает клавишу.
        await sink.finish()

        guard let writer else { throw AudioCaptureError.notRecording }

        if let writeFailure {
            writer.discard()
            self.writer = nil
            throw AudioCaptureError.writeFailed(String(describing: writeFailure))
        }

        let duration = writer.duration
        let url: URL
        do {
            url = try writer.close()
        } catch {
            self.writer = nil
            throw AudioCaptureError.writeFailed(String(describing: error))
        }
        self.writer = nil
        return (url, duration)
    }

    public func abortRecording() async {
        wakeFirstFrameWaiters(arrived: false)
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        converter = nil
        await sink.cancel()
        writer?.discard()
        writer = nil
    }

    /// Привести пришедший кадр к моно 16 кГц.
    nonisolated static func extractSamples(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        target: AVAudioFormat
    ) throws -> [Float] {
        guard let converter else {
            guard let channel = buffer.floatChannelData?[0] else {
                throw AudioCaptureError.unsupportedAudioFormat("the microphone didn't provide Float32 PCM")
            }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioCaptureError.unsupportedAudioFormat("couldn't create a 16 kHz mono buffer")
        }

        // Коробки объясняют компилятору то, что верно по факту: замыкание
        // выполняется синхронно здесь же, а не в другом потоке.
        let supplied = UncheckedBox(false)
        let input = UncheckedBox(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied.value {
                status.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return input.value
        }

        if let error {
            throw AudioCaptureError.unsupportedAudioFormat(error.localizedDescription)
        }
        guard status != .error else {
            throw AudioCaptureError.unsupportedAudioFormat("the converter rejected an audio frame")
        }
        guard let channel = output.floatChannelData?[0] else {
            throw AudioCaptureError.unsupportedAudioFormat("the converter didn't return Float32 PCM")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Чистый seam для проверки критической развилки: `nil` допустим только
    /// когда преобразование действительно не требуется.
    nonisolated static func converter(
        from source: AVAudioFormat,
        to target: AVAudioFormat,
        factory: ConverterFactory
    ) throws -> AVAudioConverter? {
        let needsConversion = source.sampleRate != target.sampleRate
            || source.channelCount != target.channelCount
        guard needsConversion else { return nil }
        guard let converter = factory(source, target) else {
            throw AudioCaptureError.unsupportedAudioFormat(
                "couldn't convert \(Int(source.sampleRate)) Hz / \(source.channelCount) ch to 16 kHz mono"
            )
        }
        return converter
    }
}

/// Аудиопоток может прислать несколько кадров до асинхронной остановки.
/// Одна причина не должна создавать десятки параллельных interrupt-задач.
private final class FailureOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        body()
    }
}
