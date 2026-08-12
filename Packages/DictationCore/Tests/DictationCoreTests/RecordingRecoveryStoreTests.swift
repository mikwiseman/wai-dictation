import XCTest
@testable import DictationCore

final class RecordingRecoveryStoreTests: XCTestCase {
    private var root: URL!
    private var takes: URL!
    private var recovered: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "recording-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        takes = root.appending(path: "Takes", directoryHint: .isDirectory)
        recovered = root.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func take(_ name: String, bytes: Int = 8) throws -> URL {
        let url = takes.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    /// Заголовок, который WAVWriter успел записать до process kill: формат
    /// уже валиден, но размеры ещё нулевые, хотя PCM payload лежит на диске.
    private func abandonedWAV(_ name: String, sampleBytes: Int = 3200) throws -> URL {
        var data = Data()
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        u32(36) // process погиб до финального close
        data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16)
        u16(1)
        u16(1)
        u32(16_000)
        u32(32_000)
        u16(2)
        u16(16)
        data.append(contentsOf: "data".utf8)
        u32(0) // process погиб до финального close
        data.append(Data(repeating: 7, count: sampleBytes))
        let url = takes.appending(path: name)
        try data.write(to: url)
        return url
    }

    func testPreserveMovesWAVOutOfActiveTakes() async throws {
        let source = try take("failed.wav")
        let store = RecordingRecoveryStore(directory: recovered)

        let preserved = try await store.preserve(source)
        let destination = try XCTUnwrap(preserved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 8))
    }

    func testImportAbandonedKeepsCrashRecordingForRetry() async throws {
        _ = try abandonedWAV("crash.wav", sampleBytes: 32_000)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)
        let recordings = result.recordings

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(result.discardedCorruptCount, 0)
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
        let data = try Data(contentsOf: XCTUnwrap(recordings.first))
        let riffSize = data[4..<8].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        let payloadSize = data[40..<44].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(riffSize, 36 + 32_000)
        XCTAssertEqual(payloadSize, 32_000)
    }

    func testCorruptFragmentDoesNotBlockValidCrashRecording() async throws {
        let corrupt = try take("corrupt.wav", bytes: 10)
        _ = try abandonedWAV("valid.wav", sampleBytes: 32_000)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.discardedCorruptCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
    }

    /// Слишком короткий обрывок — не «запись после сбоя», а случайное нажатие,
    /// пережившее kill. Главный путь диктовки такие не распознаёт и молча
    /// удаляет; импорт обязан вести себя так же. Иначе при следующем запуске
    /// человек видит «запись ждёт распознавания», а повтор навсегда упирается
    /// в пустой результат — ошибка на ровном месте.
    func testImportDeletesTooShortFragmentSilently() async throws {
        _ = try abandonedWAV("blip.wav", sampleBytes: 3200) // 0.1 с — короче предела
        _ = try abandonedWAV("empty.wav", sampleBytes: 0) // header без единого кадра
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertEqual(
            result.discardedCorruptCount, 0,
            "Обрывок — не порча: пугать сообщением о повреждении не за что"
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: recovered.path)) ?? []
        XCTAssertTrue(saved.filter { $0.hasSuffix(".wav") }.isEmpty)
    }

    /// Ровно на пределе — уже распознаваемо, храним.
    func testImportKeepsFragmentAtMinimumDuration() async throws {
        let minimumBytes = Int(DictationDurationPolicy.minimum * 32_000)
        _ = try abandonedWAV("edge.wav", sampleBytes: minimumBytes)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.newlyImportedCount, 1)
    }

    /// Лефтовер прошлой недели — не событие этого запуска.
    ///
    /// Раньше приложение при каждом старте объявляло «найдена запись после
    /// сбоя», даже когда сбой был неделю назад и ничего нового не случилось:
    /// человек видел ошибку там, где её не было. Число новых импортов даёт
    /// приложению отличить «сейчас что-то спасли» от «лежит старое».
    func testLeftoverFromPreviousLaunchIsNotCountedAsNew() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        _ = try await store.preserve(try take("old.wav", bytes: 64_000))

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertEqual(result.discardedCorruptCount, 0)
    }

    func testLimitsCountAndBytesOldestFirst() async throws {
        let store = RecordingRecoveryStore(
            directory: recovered,
            maximumCount: 2,
            maximumBytes: 12
        )
        for index in 0..<3 {
            let source = try take("\(index).wav", bytes: 6)
            _ = try await store.preserve(source)
            try await Task.sleep(for: .milliseconds(10))
        }

        let recordings = try await store.recordings()

        XCTAssertEqual(recordings.count, 2)
        let total = try recordings.reduce(0) {
            $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(total, 12)
    }

    func testDeletesEntriesOlderThanSevenDays() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        let old = try take("old.wav")
        _ = try await store.preserve(old)
        let before = try await store.recordings()
        let saved = try XCTUnwrap(before.first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: saved.path
        )

        _ = try await store.preserve(try take("new.wav"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        let remaining = try await store.recordings()
        XCTAssertEqual(remaining.count, 1)
    }
}
