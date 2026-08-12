import Foundation

// Здесь раньше жил `RecoveryStore`, писавший нераспознанный текст на диск.
// Теперь такой текст держится только в памяти процесса (Copy/Retry в меню),
// а на диск попадают исключительно WAV после технической ошибки — см. ниже.
// Каталог `Recovered/` старых сборок приложение убирает при запуске.

/// WAV, оставшийся после технической ошибки и доступный для повторного ASR.
public protocol RecordingRecoveryStoring: Sendable {
    func preserve(_ source: URL) async throws -> URL?
}

public struct AbandonedRecordingImportResult: Sendable, Equatable {
    public let recordings: [URL]
    /// Сколько записей спасено именно этим импортом.
    ///
    /// Отличает «сейчас что-то случилось» от «лежит с прошлой недели»: старый
    /// лефтовер — не событие этого запуска, и объявлять его заново не за что.
    public let newlyImportedCount: Int
    public let discardedCorruptCount: Int

    public init(recordings: [URL], newlyImportedCount: Int, discardedCorruptCount: Int) {
        self.recordings = recordings
        self.newlyImportedCount = newlyImportedCount
        self.discardedCorruptCount = discardedCorruptCount
    }
}

/// Production recovery для ошибочных и прерванных записей.
public actor RecordingRecoveryStore: RecordingRecoveryStoring {
    private let directory: URL
    private let maximumCount: Int
    private let maximumAge: TimeInterval
    private let maximumBytes: Int64
    private let fileManager: FileManager

    public init(
        directory: URL,
        maximumCount: Int = 10,
        maximumAge: TimeInterval = 7 * 24 * 3600,
        maximumBytes: Int64 = 1_073_741_824,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
    }

    public func preserve(_ source: URL) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination: URL
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            destination = source
        } else {
            destination = directory.appending(
                path: "recording-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8)).wav"
            )
            try fileManager.moveItem(at: source, to: destination)
        }
        try prune()
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }

    /// Перенести WAV, оставшиеся в Takes после kill/crash/power loss.
    public func importAbandoned(from takesDirectory: URL) throws -> AbandonedRecordingImportResult {
        guard fileManager.fileExists(atPath: takesDirectory.path) else {
            return AbandonedRecordingImportResult(
                recordings: try recordings(),
                newlyImportedCount: 0,
                discardedCorruptCount: 0
            )
        }
        let entries = try fileManager.contentsOfDirectory(
            at: takesDirectory,
            includingPropertiesForKeys: nil
        )
        var newlyImportedCount = 0
        var discardedCorruptCount = 0
        for entry in entries where entry.pathExtension.lowercased() == "wav" {
            do {
                let payloadBytes = try repairAbandonedWAV(at: entry)
                // Обрывок короче предела распознавания — случайное нажатие,
                // пережившее kill, а не потерянная речь. Главный путь диктовки
                // такие молча удаляет; импорт обязан вести себя так же, иначе
                // человек при запуске видит «запись после сбоя», повтор которой
                // навсегда даёт пустой результат.
                guard DictationDurationPolicy.isWorthTranscribing(
                    duration: TimeInterval(payloadBytes) / TimeInterval(Self.bytesPerSecond)
                ) else {
                    try fileManager.removeItem(at: entry)
                    continue
                }
                if try preserve(entry) != nil { newlyImportedCount += 1 }
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                // Точно непригодный фрагмент не должен блокировать остальные
                // записи после crash. Это только собственный WAVWriter-файл из
                // Takes; чужие файлы сюда не попадают. Удаление дойдёт до UI
                // счётчиком, поэтому оно не скрыто от человека.
                try fileManager.removeItem(at: entry)
                discardedCorruptCount += 1
            }
        }
        return AbandonedRecordingImportResult(
            recordings: try recordings(),
            newlyImportedCount: newlyImportedCount,
            discardedCorruptCount: discardedCorruptCount
        )
    }

    /// Скорость потока собственного WAVWriter: 16 кГц × 16 бит × моно.
    /// Формат прибит проверкой заголовка в `repairAbandonedWAV`.
    private static let bytesPerSecond: Int64 = 32_000

    /// WAVWriter сначала кладёт 44-байтный заголовок с нулевыми размерами и
    /// исправляет их в `close()`. После kill/crash PCM уже на диске, но без
    /// этой починки системный декодер считает запись пустой. Принимаем только
    /// точный формат собственного writer: чужой или обрезанный файл не должен
    /// маскироваться под пригодный Retry.
    ///
    /// Возвращает размер PCM-payload: по нему решается, есть ли в записи что
    /// распознавать.
    @discardableResult
    private func repairAbandonedWAV(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let totalBytes = fileSize.int64Value
        guard totalBytes >= 44 else { throw CocoaError(.fileReadCorruptFile) }
        let payloadBytes = totalBytes - 44
        guard payloadBytes.isMultiple(of: 2), payloadBytes <= Int64(UInt32.max) - 36 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let handle = try FileHandle(forUpdating: url)
        do {
            try handle.seek(toOffset: 0)
            guard let header = try handle.read(upToCount: 44), header.count == 44,
                  String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
                  String(decoding: header[8..<16], as: UTF8.self) == "WAVEfmt ",
                  readUInt32(header, at: 16) == 16,
                  readUInt16(header, at: 20) == 1,
                  readUInt16(header, at: 22) == 1,
                  readUInt32(header, at: 24) == 16_000,
                  readUInt32(header, at: 28) == 32_000,
                  readUInt16(header, at: 32) == 2,
                  readUInt16(header, at: 34) == 16,
                  String(decoding: header[36..<40], as: UTF8.self) == "data"
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: littleEndian(UInt32(36 + payloadBytes)))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: littleEndian(UInt32(payloadBytes)))
            try handle.synchronize()
            try handle.close()
        } catch {
            // Ошибка close должна быть видна, но повторное закрытие после более
            // ранней ошибки — только освобождение дескриптора.
            try? handle.close()
            throw error
        }
        return payloadBytes
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    public func recordings() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try entries().sorted { $0.date > $1.date }.map(\.url)
    }

    public func delete(_ url: URL) throws {
        let prefix = directory.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.removeItem(at: url)
    }

    private struct Entry {
        let url: URL
        let date: Date
        let bytes: Int64
    }

    private func entries() throws -> [Entry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        return try urls.filter { $0.pathExtension.lowercased() == "wav" }.map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values.contentModificationDate, let size = values.fileSize else {
                throw CocoaError(.fileReadUnknown)
            }
            return Entry(url: url, date: date, bytes: Int64(size))
        }
    }

    private func prune(now: Date = Date()) throws {
        var survivors: [Entry] = []
        for entry in try entries().sorted(by: { $0.date < $1.date }) {
            if now.timeIntervalSince(entry.date) > maximumAge {
                try fileManager.removeItem(at: entry.url)
            } else {
                survivors.append(entry)
            }
        }

        var totalBytes = survivors.reduce(Int64(0)) { $0 + $1.bytes }
        while survivors.count > maximumCount || totalBytes > maximumBytes {
            let oldest = survivors.removeFirst()
            try fileManager.removeItem(at: oldest.url)
            totalBytes -= oldest.bytes
        }
    }
}

/// Старые unit-тесты и чистые consumers могут явно выбрать удаление WAV.
public struct DiscardingRecordingRecovery: RecordingRecoveryStoring {
    public init() {}

    public func preserve(_ source: URL) throws -> URL? {
        try FileManager.default.removeItem(at: source)
        return nil
    }
}
