import LocalASR
import XCTest

/// Что человек видит про модель в каждом её состоянии.
///
/// Состояний шесть, экрана два, и раньше все шесть были расписаны в обоих
/// местах руками. Проверяется здесь именно видимое: заголовок, объяснение,
/// подпись индикатора и набор кнопок.
final class ModelStatusTests: XCTestCase {
    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))

    private func status(
        _ state: ModelState,
        preparing: Bool = false,
        place: ModelStatus.Place = .settings
    ) -> ModelStatus {
        ModelStatus.make(state: state, isPreparingEngine: preparing, place: place)
    }

    // MARK: - Состояния

    func testНеУстановленаПредлагаетСкачатьИНазываетРазмер() {
        let status = status(.notInstalled)

        XCTAssertEqual(status.title, "Model not installed")
        XCTAssertEqual(status.actions, [.install])
        // Обе модели одной кнопкой: 483 МБ распознавание + 103 МБ подсказчик.
        XCTAssertEqual(status.detail?.contains("586 MB"), true)
        XCTAssertNil(status.progress)
    }

    func testЗагрузкаПоказываетМегабайтыИДолю() {
        let status = status(.downloading(receivedBytes: 120_000_000, totalBytes: 483_000_000))

        XCTAssertEqual(status.title, "Downloading model…")
        XCTAssertEqual(status.progressLabel, "120 of 483 MB")
        XCTAssertEqual(status.progress ?? 0, 0.248, accuracy: 0.01)
        // Единственное действие — честно остановить загрузку и удалить partial.
        XCTAssertEqual(status.actions, [.cancel])
        XCTAssertEqual(status.announcement, "Downloading model, 120 of 483 MB")
    }

    func testПроверкаНазываетНомерФайла() {
        let status = status(.verifying(checked: 3, total: 12))

        XCTAssertEqual(status.title, "Verifying download…")
        XCTAssertEqual(status.progressLabel, "File 3 of 12")
        XCTAssertEqual(status.progress ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(status.actions, [])
    }

    func testГотоваяМодельВНастройкахДаётЕёУдалить() {
        let status = status(ready, place: .settings)

        XCTAssertEqual(status.title, "Model ready")
        XCTAssertEqual(status.tone, .success)
        XCTAssertEqual(status.actions, [.delete])
    }

    /// В онбординге кнопки удаления нет.
    ///
    /// Человек ставит приложение первый раз; предложить снести только что
    /// скачанные 483 МБ — единственное, чего ему сейчас точно не надо.
    func testГотоваяМодельВОнбордингеНеПредлагаетУдаление() {
        XCTAssertEqual(status(ready, place: .onboarding).actions, [])
    }

    func testПрогревДвижкаОбъясняетЗадержкуПервогоРаза() {
        let status = status(ready, preparing: true)

        XCTAssertEqual(status.title, "Model ready")
        XCTAssertEqual(status.detail?.contains("20–40 seconds"), true)
        XCTAssertEqual(status.announcement, "Model ready, preparing for first use")
    }

    func testОшибкаПредлагаетПовторить() {
        let status = status(.failed(.download("the server did not respond")))

        XCTAssertEqual(status.title, "Model installation failed")
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.actions, [.retry])
        XCTAssertEqual(status.detail, "Download failed: the server did not respond")
    }

    func testПовреждённаяМодельТребуетЯвногоВосстановления() {
        let status = status(.repairRequired("checksum mismatch"))

        XCTAssertEqual(status.title, "Model needs repair")
        XCTAssertEqual(status.actions, [.repair])
        XCTAssertEqual(status.title(for: .repair), "Redownload Model — 586 MB")
        // Добор после обновления называет только остаток, а не полный объём.
        XCTAssertEqual(
            ModelStatus.Action.repair.title(downloadMegabytes: 103),
            "Redownload Model — 103 MB"
        )
        XCTAssertEqual(status.detail?.contains("damaged"), true)
    }

    func testУдалениеПоказываетсяОтдельно() {
        let status = status(.deleting)

        XCTAssertEqual(status.title, "Deleting model…")
        XCTAssertEqual(status.actions, [])
        XCTAssertNil(status.progress)
    }

    // MARK: - Ошибки словами

    /// Нехватка места объяснялась дампом перечисления с сырыми байтами.
    ///
    /// Человек видел `notEnoughDiskSpace(requiredBytes: 594…, availableBytes: 1…)`
    /// и должен был сам догадаться, что на диске нет места.
    func testНехваткаМестаНазываетсяСловамиИВМегабайтах() {
        let text = ModelStatus.message(
            for: .notEnoughDiskSpace(requiredBytes: 594_000_000, availableBytes: 120_000_000)
        )

        XCTAssertEqual(
            text,
            "Not enough disk space: 594 MB needed, 120 MB free."
        )
        XCTAssertFalse(text.contains("requiredBytes"))
    }

    func testУНикакойОшибкиНетСырогоПеречисления() {
        let errors: [ModelStoreError] = [
            .manifest("битый json"),
            .download("нет сети"),
            .verification("не сошлась сумма"),
            .install("нет прав"),
            .repairRequired("нет marker"),
            .importSource("не та папка"),
            .notEnoughDiskSpace(requiredBytes: 1, availableBytes: 0),
            .cancelled,
        ]

        for error in errors {
            let text = ModelStatus.message(for: error)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.contains("("),
                "«\(text)» выглядит как дамп перечисления, а не как объяснение"
            )
        }
    }

    // MARK: - Объявления

    func testКаждоеСостояниеОбъявляетСебяГолосом() {
        let states: [ModelState] = [
            .notInstalled,
            .downloading(receivedBytes: 0, totalBytes: 483_000_000),
            .verifying(checked: 0, total: 12),
            ready,
            .repairRequired("повреждена"),
            .failed(.cancelled),
            .deleting,
        ]

        var announcements: Set<String> = []
        for state in states {
            let announcement = status(state).announcement
            XCTAssertFalse(announcement.isEmpty)
            announcements.insert(announcement)
        }
        XCTAssertEqual(announcements.count, states.count, "состояния не должны звучать одинаково")
    }

    // MARK: - Подсказки к кнопкам

    func testУКаждойКнопкиЕстьПодсказка() {
        for action in [ModelStatus.Action.install, .retry, .repair, .delete] {
            XCTAssertFalse(action.title(downloadMegabytes: 586).isEmpty)
            XCTAssertFalse(action.hint(downloadMegabytes: 586).isEmpty)
        }
        // Удаление — единственное необратимое действие на экране, и о его цене
        // надо сказать до нажатия.
        XCTAssertEqual(
            ModelStatus.Action.delete.hint(downloadMegabytes: 586).contains("stops working"),
            true
        )
    }
}
