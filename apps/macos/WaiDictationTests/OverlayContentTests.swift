import DictationCore
import XCTest

/// Панель диктовки — единственный канал обратной связи во время диктовки.
///
/// У приложения нет своего окна: если панель промолчала, человек не узнал
/// ничего. Проверяется то, что на ней написано, и то, что о ней говорят вслух.
final class OverlayContentTests: XCTestCase {
    private func content(
        _ state: DictationState,
        notice: DictationNotice? = nil,
        elapsed: TimeInterval = 0
    ) -> OverlayContent {
        OverlayContent.make(state: state, notice: notice, elapsed: elapsed)
    }

    // MARK: - Состояния

    func testКаждоеСостояниеПодписаноПоСвоему() {
        XCTAssertEqual(content(.idle).title, "Done")
        XCTAssertEqual(content(.preparing).title, "Turning on the microphone…")
        XCTAssertEqual(content(.listening).title, "Listening")
        XCTAssertEqual(content(.transcribing).title, "Transcribing…")
        XCTAssertEqual(content(.inserting).title, "Inserting")
    }

    func testЗаписьОтличаетсяЦветомОтОстального() {
        XCTAssertEqual(content(.listening).tone, .recording)
        XCTAssertEqual(content(.preparing).tone, .working)
        XCTAssertEqual(content(.transcribing).tone, .working)
        XCTAssertEqual(content(.inserting).tone, .working)
        XCTAssertEqual(content(.idle).tone, .idle)
    }

    // MARK: - Счётчик секунд

    /// Секунды — единственный признак, что запись правда идёт.
    ///
    /// Подпись короткая нарочно: «отпусти — вставится» человек уже делает
    /// руками, держа клавишу, — учить этому на каждой диктовке незачем.
    /// Остаётся выход: Esc. Полная инструкция живёт в объявлении VoiceOver —
    /// для незрячего это единственный интерфейс.
    func testСчётчикПоказываетсяТолькоТамГдеОнЗначит() {
        XCTAssertEqual(
            content(.listening, elapsed: 7).subtitle,
            "7 s · Esc to cancel"
        )
        XCTAssertEqual(content(.transcribing, elapsed: 12.4).subtitle, "12 s")
        XCTAssertNil(content(.preparing, elapsed: 3).subtitle)
        XCTAssertNil(content(.inserting, elapsed: 3).subtitle)
        XCTAssertNil(content(.idle, elapsed: 3).subtitle)
    }

    func testСчётчикНеУходитВМинус() {
        XCTAssertEqual(
            content(.listening, elapsed: -2).subtitle,
            "0 s · Esc to cancel"
        )
    }

    /// «5 с» VoiceOver читает как «5 эс».
    func testСекундыЧитаютсяСловамиИСклоняются() {
        XCTAssertEqual(OverlayContent.spokenSeconds(1), "1 second")
        XCTAssertEqual(OverlayContent.spokenSeconds(2), "2 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(4), "4 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(5), "5 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(11), "11 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(12), "12 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(21), "21 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(22), "22 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(25), "25 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(111), "111 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(0), "0 seconds")
    }

    func testЯрлыкЗаписиНазываетСекундыСловами() {
        XCTAssertEqual(
            content(.listening, elapsed: 3).accessibilityLabel,
            "Recording, 3 seconds. Press the hotkey to insert. Press Escape to delete the recording."
        )
        XCTAssertEqual(
            content(.listening, elapsed: 1).accessibilityLabel,
            "Recording, 1 second. Press the hotkey to insert. Press Escape to delete the recording."
        )
    }

    // MARK: - Объявления

    /// Главное объявление во всём приложении.
    ///
    /// Панель нарочно не забирает фокус, значка в доке нет, окна нет: без этой
    /// фразы незрячий человек не знает, что микрофон включён.
    func testНачалоЗаписиОбъявляетсяСрочно() {
        let content = content(.listening)

        XCTAssertEqual(content.announcement, "Recording. Press the hotkey to insert. Press Escape to delete the recording.")
        XCTAssertTrue(content.isAnnouncementUrgent)
    }

    func testРаботаПослеЗаписиТожеОбъявляется() {
        XCTAssertEqual(content(.transcribing).announcement, "Recording stopped, transcribing speech")
        XCTAssertEqual(content(.inserting).announcement, "Inserting text")
        XCTAssertEqual(content(.preparing).announcement, "Turning on the microphone")
    }

    /// Панель в покое убирается с экрана — объявлять там нечего.
    func testПокойНичегоНеОбъявляет() {
        XCTAssertNil(content(.idle).announcement)
    }

    // MARK: - Сообщения

    func testСообщениеЗаменяетСобойСостояние() {
        let notice = DictationNotice(kind: .warning, message: "Text not inserted: secure input is active.")
        let content = content(.listening, notice: notice, elapsed: 9)

        XCTAssertEqual(content.title, notice.message)
        // Счётчик рядом с сообщением сбивает: запись уже не идёт.
        XCTAssertNil(content.subtitle)
        XCTAssertEqual(content.tone, .warning)
        XCTAssertEqual(content.announcement, notice.message)
    }

    func testВидСообщенияВиденИСлышен() {
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .info, message: "и")).tone, .info)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .warning, message: "п")).tone, .warning)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .failure, message: "о")).tone, .failure)
    }

    /// Сбой перебивает то, что VoiceOver читает сейчас, а простое уведомление — нет.
    func testСрочностьЗависитОтВидаСообщения() {
        XCTAssertFalse(content(.idle, notice: DictationNotice(kind: .info, message: "и")).isAnnouncementUrgent)
        XCTAssertTrue(content(.idle, notice: DictationNotice(kind: .warning, message: "п")).isAnnouncementUrgent)
        XCTAssertTrue(content(.idle, notice: DictationNotice(kind: .failure, message: "о")).isAnnouncementUrgent)
    }

    // MARK: - Ярлыки

    func testУПанелиВсегдаЕстьЯрлык() {
        let states: [DictationState] = [.idle, .preparing, .listening, .transcribing, .inserting]
        for state in states {
            XCTAssertFalse(
                content(state).accessibilityLabel.isEmpty,
                "состояние \(state) не достаётся VoiceOver вовсе"
            )
        }
    }
}
