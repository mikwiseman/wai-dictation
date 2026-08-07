import XCTest
import DictationCore

/// Строка «stop → text» — форматирование без панели и без движка.
final class SpeedReadoutTests: XCTestCase {
    private func readout(_ dispatched: Duration?) -> SpeedReadout? {
        SpeedReadout.make(
            DictationSpeedReport(
                toRecognizedText: .milliseconds(100),
                toPasteDispatched: dispatched
            )
        )
    }

    func testПоказываетсяЗаголовочнаяОтметкаАНеПервая() {
        XCTAssertEqual(readout(.milliseconds(153))?.line, "stop → text: 153 ms")
    }

    /// Вставку никто не мерил — строки нет вовсе.
    ///
    /// Показать вместо неё первую отметку было бы подменой: «движок ответил»
    /// и «текст у человека» — разные обещания.
    func testБезИзмереннойВставкиСтрокиНет() {
        XCTAssertNil(readout(nil))
    }

    func testДлинныеЗадержкиПоказываютсяВСекундах() {
        XCTAssertEqual(readout(.milliseconds(1240))?.line, "stop → text: 1.2 s")
        XCTAssertEqual(readout(.milliseconds(3000))?.line, "stop → text: 3.0 s")
    }

    /// «0 ms» — не быстро, а неизмеримо, и читалось бы как заведомая неправда.
    func testНольМиллисекундНеПоказывается() {
        XCTAssertEqual(readout(.milliseconds(0))?.line, "stop → text: 1 ms")
        XCTAssertEqual(readout(.microseconds(200))?.line, "stop → text: 1 ms")
    }

    /// VoiceOver читает «ms» как «эмэс» — для него слова.
    func testЯрлыкДляVoiceOverЧитаетсяСловами() {
        let label = readout(.milliseconds(153))?.accessibilityLabel
        XCTAssertEqual(label, "Text ready 153 milliseconds after you released the key")
        XCTAssertFalse(label?.contains(" ms") ?? true)
    }

    func testГраницаМеждуМиллисекундамиИСекундами() {
        XCTAssertEqual(readout(.milliseconds(999))?.line, "stop → text: 999 ms")
        XCTAssertEqual(readout(.milliseconds(1000))?.line, "stop → text: 1.0 s")
    }
}

/// Состояние подготовки движка: честные секунды вместо выдуманного прогресса.
final class EnginePreparationStateTests: XCTestCase {
    /// Сигнала прогресса компиляции ANE не существует. Нарисованная полоска
    /// обещала бы срок, которого не знает никто.
    func testНиОднаФазаНеОбещаетПроцентов() {
        for phase in [
            EnginePreparationState.Phase.idle,
            .loadingRecognizer,
            .loadingVocabulary,
            .ready,
        ] {
            let state = EnginePreparationState.make(phase: phase, elapsed: 7)
            XCTAssertFalse(state.title.contains("%"), "\(phase)")
            XCTAssertFalse(state.detail?.contains("%") ?? false, "\(phase)")
            XCTAssertFalse(state.title.isEmpty, "\(phase)")
        }
    }

    func testСекундыПодготовкиВидныВЗаголовке() {
        XCTAssertEqual(
            EnginePreparationState.make(phase: .loadingRecognizer, elapsed: 14).title,
            "Preparing the recognizer… 14 s"
        )
        XCTAssertEqual(
            EnginePreparationState.make(phase: .loadingVocabulary, elapsed: 3).title,
            "Preparing the term booster… 3 s"
        )
    }

    func testГотовностьНеОбещаетОжидания() {
        let ready = EnginePreparationState.make(phase: .ready, elapsed: 0)
        XCTAssertEqual(ready.title, "Ready to dictate")
        XCTAssertNil(ready.detail)
    }

    /// Отказ движка сюда не входит: у него уже есть владелец —
    /// `ModelStatus.repairRequired`. Второй тип про то же разошёлся бы с первым.
    func testОтказаДвижкаЗдесьНет() {
        let phases: [EnginePreparationState.Phase] = [.idle, .loadingRecognizer, .loadingVocabulary, .ready]
        for phase in phases {
            let state = EnginePreparationState.make(phase: phase, elapsed: 1)
            XCTAssertFalse(state.title.lowercased().contains("fail"), "\(phase)")
            XCTAssertFalse(state.title.lowercased().contains("error"), "\(phase)")
        }
    }
}

/// Отсчёт подготовки движка доезжает до человека.
@MainActor
final class EnginePreparationWiringTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    /// В покое таймер не тикает: приложение не имеет права крутить что-то
    /// в фоне просто потому, что запущено.
    func testВПокоеОтсчётНеИдёт() {
        let state = harness.makeState()
        XCTAssertFalse(state.isCountingEnginePreparation)
        XCTAssertEqual(state.enginePreparation.phase, .idle)
    }

    /// Живые секунды доходят до строки, которую видит человек, — иначе
    /// ожидание читается как зависание.
    func testСекундыПодготовкиПопадаютВСтрокуСтатуса() {
        let status = ModelStatus.make(
            state: .ready(directory: URL(fileURLWithPath: "/tmp")),
            isPreparingEngine: true,
            preparation: .make(phase: .loadingRecognizer, elapsed: 9),
            place: .settings
        )
        XCTAssertEqual(status.detail, "Preparing the recognizer… 9 s")
    }

    /// Вторая модель — отдельная фаза: сливать их в одну строку значит
    /// показывать «ещё чуть-чуть», когда началась новая работа.
    func testВтораяМодельНазываетСебяОтдельно() {
        let status = ModelStatus.make(
            state: .ready(directory: URL(fileURLWithPath: "/tmp")),
            isPreparingEngine: true,
            preparation: .make(phase: .loadingVocabulary, elapsed: 2),
            place: .settings
        )
        XCTAssertEqual(status.detail, "Preparing the term booster… 2 s")
    }

    /// Подготовка кончилась — строки нет вовсе.
    func testПослеПодготовкиСтрокаИсчезает() {
        let status = ModelStatus.make(
            state: .ready(directory: URL(fileURLWithPath: "/tmp")),
            isPreparingEngine: false,
            preparation: .make(phase: .ready, elapsed: 0),
            place: .settings
        )
        XCTAssertNil(status.detail)
    }
}
