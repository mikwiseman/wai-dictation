import DictationCore
import XCTest

/// Поведение панели: когда она на экране, когда исчезает и что говорит вслух.
///
/// Само окно здесь не участвует — оно требует графического сеанса, которого в
/// проверке может не быть. Всё остальное проверяется полностью.
@MainActor
final class OverlayModelTests: XCTestCase {
    private var announcer: FakeAnnouncer!
    private var model: OverlayModel!
    private var visibility: [Bool] = []

    override func setUp() async throws {
        announcer = FakeAnnouncer()
        model = OverlayModel(announcer: announcer, noticeDuration: .milliseconds(120))
        visibility = []
        model.onVisibilityChange = { [weak self] visible in self?.visibility.append(visible) }
    }

    // MARK: - Показ и уборка

    func testЗаписьПоказываетПанельАУборкаЕёПрячет() {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isVisible)

        model.hide()

        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(visibility, [true, false])
    }

    func testПовторныйПоказНеДёргаетОкноЗря() {
        model.show(.preparing, elapsed: 0)
        model.show(.listening, elapsed: 0)
        model.show(.transcribing, elapsed: 1)

        XCTAssertEqual(visibility, [true], "окно поднимается один раз на сессию")
    }

    // MARK: - Счётчик

    func testСчётчикИдётТолькоВоВремяЗаписи() async throws {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isTicking)

        // Ядро выходит на связь один раз в начале записи и один раз в конце.
        // Если панель не считает сама, всю диктовку на ней стоит «0 с».
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(model.elapsed, 0.4)

        model.show(.transcribing, elapsed: model.elapsed)
        XCTAssertFalse(model.isTicking)
    }

    func testУборкаОстанавливаетСчётчик() {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isTicking)

        model.hide()

        XCTAssertFalse(model.isTicking)
    }

    // MARK: - Сообщения

    func testСообщениеСамоУходитЧерезПоложенноеВремя() async throws {
        model.showNotice(DictationNotice(kind: .warning, message: "Текст сохранён."))
        XCTAssertTrue(model.isVisible)

        try await Task.sleep(for: .milliseconds(220))

        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isVisible)
    }

    /// Уборка после сессии приходит сразу за сообщением.
    ///
    /// Если она уносит панель с собой, человек не успевает прочесть, что текст
    /// не вставился и где он теперь лежит.
    func testУборкаНеУноситСообщениеСЭкрана() {
        model.showNotice(DictationNotice(kind: .failure, message: "Не удалось вставить текст."))

        model.hide()

        XCTAssertTrue(model.isVisible)
        XCTAssertNotNil(model.notice)
    }

    /// Два одинаковых сообщения подряд.
    ///
    /// Отложенное скрытие первого узнавало «своё» сообщение по тексту и уносило
    /// с экрана второе — то показывалось втрое короче положенного.
    func testВтороеТакоеЖеСообщениеПолучаетСвоёВремя() async throws {
        // Своя панель с длинным сроком показа. У общей он 120 мс, и проверка
        // упиралась в тридцать миллисекунд запаса: на загруженной машине сон
        // перелетает, сообщение честно истекает, и падает тест, а не продукт.
        // Здесь важно не «сколько именно», а «второй показ начинает отсчёт
        // заново» — значит запас должен быть таким, чтобы разница была видна
        // при любом перелёте.
        let announcer = FakeAnnouncer()
        let model = OverlayModel(announcer: announcer, noticeDuration: .seconds(5))
        let notice = DictationNotice(kind: .warning, message: "Сейчас идёт диктовка. Дождитесь её окончания.")

        model.showNotice(notice)
        try await Task.sleep(for: .milliseconds(50))

        model.showNotice(notice)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(model.notice, "второе сообщение исчезло раньше своего срока")
        XCTAssertTrue(model.isVisible)
    }

    func testНачалоДиктовкиУбираетПрошлоеСообщение() {
        model.showNotice(DictationNotice(kind: .warning, message: "Текст сохранён."))

        model.show(.listening, elapsed: 0)

        XCTAssertNil(model.notice)
        XCTAssertEqual(model.content.title, "Listening")
    }

    /// Отложенное скрытие принадлежит своему показу.
    ///
    /// Иначе оно погасило бы панель уже начавшейся следующей диктовки.
    func testОтложенноеСкрытиеНеГаситСледующуюДиктовку() async throws {
        model.showNotice(DictationNotice(kind: .info, message: "Достигнут предел в час."))
        model.show(.listening, elapsed: 0)

        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(model.isVisible, "панель идущей диктовки погасил хвост прошлого сообщения")
    }

    // MARK: - Голос

    func testНачалоЗаписиГоворитсяВслух() {
        model.show(.listening, elapsed: 0)

        XCTAssertEqual(
            announcer.messages,
            ["Recording. Press the hotkey to insert. Press Escape to delete the recording."]
        )
        XCTAssertEqual(announcer.announcements.first?.urgent, true)
    }

    /// Счётчик тикает дважды в секунду.
    ///
    /// Без памяти о сказанном VoiceOver повторял бы «идёт запись» до конца
    /// диктовки и заглушил бы собой всё остальное.
    func testОдноИТоЖеНеПовторяетсяВслух() {
        model.show(.listening, elapsed: 0)
        model.show(.listening, elapsed: 1)
        model.show(.listening, elapsed: 2)

        XCTAssertEqual(
            announcer.messages,
            ["Recording. Press the hotkey to insert. Press Escape to delete the recording."]
        )
    }

    func testСледующаяДиктовкаОбъявляетсяЗаново() {
        model.show(.listening, elapsed: 0)
        model.hide()

        model.show(.listening, elapsed: 0)

        XCTAssertEqual(
            announcer.messages,
            [
                "Recording. Press the hotkey to insert. Press Escape to delete the recording.",
                "Recording. Press the hotkey to insert. Press Escape to delete the recording.",
            ]
        )
    }

    func testСообщениеГоворитсяВслухЦеликом() {
        let notice = DictationNotice(kind: .failure, message: "Не удалось записать звук.")

        model.showNotice(notice)

        XCTAssertEqual(announcer.messages, ["Не удалось записать звук."])
        XCTAssertEqual(announcer.announcements.first?.urgent, true)
    }

    func testВесьПутьДиктовкиСлышенЦеликом() {
        model.show(.preparing, elapsed: 0)
        model.show(.listening, elapsed: 0)
        model.show(.transcribing, elapsed: 3)
        model.show(.inserting, elapsed: 3)

        XCTAssertEqual(
            announcer.messages,
            [
                "Turning on the microphone",
                "Recording. Press the hotkey to insert. Press Escape to delete the recording.",
                "Recording stopped, transcribing speech",
                "Inserting text",
            ]
        )
    }

}
