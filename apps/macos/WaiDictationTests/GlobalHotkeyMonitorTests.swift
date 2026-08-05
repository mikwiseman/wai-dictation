import AppKit
import Carbon.HIToolbox
import XCTest

@MainActor
final class GlobalHotkeyMonitorTests: XCTestCase {
    private var source: FakeHotkeyEventSource!
    private var monitor: GlobalHotkeyMonitor!

    override func setUp() async throws {
        source = FakeHotkeyEventSource()
        monitor = GlobalHotkeyMonitor(source: source, hotkey: .rightCommand)
    }

    private var pressedRightCommand: HotkeyEvent {
        HotkeyEvent(
            keyCode: DictationHotkey.rightCommand.keyCode,
            rawFlags: NSEvent.ModifierFlags.command.rawValue | 0x0000_0010,
            at: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private var releasedRightCommand: HotkeyEvent {
        HotkeyEvent(
            keyCode: DictationHotkey.rightCommand.keyCode,
            rawFlags: 0,
            at: Date(timeIntervalSince1970: 1_000_001)
        )
    }

    // MARK: - Запуск

    /// Ctrl+C поверх выбранного модификатора: keyDown обязан дойти до машины
    /// и оборвать жест — иначе каждый шорткат превращается в фантомную
    /// диктовку, а два подряд включают запись без удержания фоном.
    func testЧужаяКлавишаВоВремяУдержанияОбрываетЗапись() {
        let source = FakeHotkeyEventSource()
        let monitor = GlobalHotkeyMonitor(source: source)
        monitor.setHotkey(.leftControl)
        var aborted = 0
        var released = 0
        monitor.onAbortShortcut = { aborted += 1 }
        monitor.onRelease = { released += 1 }
        monitor.start()

        source.sendFlags(HotkeyEvent(
            keyCode: DictationHotkey.leftControl.keyCode,
            rawFlags: NSEvent.ModifierFlags.control.rawValue | 0x0000_0001,
            at: Date()
        ))
        source.sendKeyDown(HotkeyEvent(keyCode: 8, rawFlags: 0, at: Date()))
        source.sendFlags(HotkeyEvent(
            keyCode: DictationHotkey.leftControl.keyCode,
            rawFlags: 0,
            at: Date().addingTimeInterval(0.1)
        ))

        XCTAssertEqual(aborted, 1, "Шорткат обязан оборвать жест ровно один раз")
        XCTAssertEqual(released, 0, "После обрыва отпускание не вставляет")
    }

    func testБезДоступаСлежениеНеНачинается() {
        source.isTrusted = false

        monitor.start()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(source.flagsMonitorCount, 0)
        XCTAssertEqual(source.keyMonitorCount, 0)
    }

    /// Повторный `start()` не должен ничего перерегистрировать.
    ///
    /// Проверка разрешений тикает раз в секунду и зовёт `start()` каждый раз.
    /// Перезапуск сбрасывал бы память о зажатой клавише: отпускание, случившееся
    /// после тика, терялось бы, и диктовка оставалась бы включённой.
    func testПовторныйЗапускНеПеререгистрирует() {
        monitor.start()
        monitor.start()
        monitor.start()

        XCTAssertEqual(source.flagsMonitorCount, 1)
        XCTAssertEqual(source.keyMonitorCount, 1)
    }

    func testПовторныйЗапускНеТеряетЗажатуюКлавишу() {
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        // Тик проверки разрешений посреди удержания.
        monitor.start()
        source.sendFlags(releasedRightCommand)

        XCTAssertEqual(releases, 1)
    }

    /// Клавишу отпустили, пока Mac спал.
    ///
    /// Событий спящей машины система не присылает: монитор так и остаётся с
    /// памятью о зажатой клавише, и первое нажатие после пробуждения не
    /// считается нажатием вовсе. Стереть эту память может только полная
    /// остановка слежения — на неё и опирается обработка пробуждения.
    func testОстановкаСтираетПамятьОЗажатойКлавише() {
        var presses = 0
        monitor.onPress = { presses += 1 }
        monitor.start()
        source.sendFlags(pressedRightCommand)
        XCTAssertEqual(presses, 1)

        // Уснули с зажатой клавишей, проснулись с отпущенной.
        monitor.stop()
        monitor.start()
        source.sendFlags(pressedRightCommand)

        XCTAssertEqual(presses, 2, "первое нажатие после пробуждения потерялось")
    }

    /// Система отдала один монитор и отказала во втором.
    ///
    /// Оставленная без пары подписка никем не снимается, а `start()` зовётся раз
    /// в секунду — за час набежала бы тысяча живых подписок, и каждая отменяла бы
    /// диктовку по одному нажатию Escape.
    func testОтказВоВторомМонитореСнимаетПервый() {
        source.grantsKeyMonitor = false

        monitor.start()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(source.flagsMonitorCount, 1)
        XCTAssertEqual(source.removedTokens, ["flags-1"])
        XCTAssertEqual(source.liveMonitorCount, 0)
    }

    func testПовторныеПопыткиПриОтказеНеКопятПодписки() {
        source.grantsKeyMonitor = false

        for _ in 0..<10 { monitor.start() }

        XCTAssertEqual(source.liveMonitorCount, 0)
    }

    func testОтказВПервомМонитореНеРегистрируетВторой() {
        source.grantsFlagsMonitor = false

        monitor.start()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(source.keyMonitorCount, 0)
    }

    // MARK: - Остановка

    func testОстановкаСнимаетОбаМонитора() {
        monitor.start()
        monitor.stop()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(Set(source.removedTokens), ["flags-1", "keys-1"])
        XCTAssertEqual(source.liveMonitorCount, 0)
    }

    func testПослеОстановкиМожноЗапуститьСнова() {
        monitor.start()
        monitor.stop()
        monitor.start()

        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(source.flagsMonitorCount, 2)
        XCTAssertEqual(source.keyMonitorCount, 2)
    }

    func testОстановкаПосредиУдержанияНеОставляетНезакрытыйЖест() {
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.start()
        source.sendFlags(pressedRightCommand)

        monitor.stop()
        monitor.start()
        // Событие отпускания после перезапуска относится к оборванному жесту.
        source.sendFlags(releasedRightCommand)

        XCTAssertEqual(releases, 0)
    }

    // MARK: - Доставка жестов

    func testНажатиеИОтпусканиеДоходятДоОбработчиков() {
        var log: [String] = []
        monitor.onPress = { log.append("press") }
        monitor.onRelease = { log.append("release") }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        source.sendFlags(releasedRightCommand)

        XCTAssertEqual(log, ["press", "release"])
    }

    func testБыстроеОтпусканиеЖдётВторогоНажатия() async throws {
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        source.sendFlags(
            HotkeyEvent(
                keyCode: DictationHotkey.rightCommand.keyCode,
                rawFlags: 0,
                at: Date(timeIntervalSince1970: 1_000_000.05)
            )
        )

        XCTAssertEqual(releases, 0)
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(releases, 1)
    }

    func testДвойноеНажатиеНеУспеваетОстановитьПервуюСессию() async throws {
        var releases = 0
        var doubleTaps = 0
        monitor.onRelease = { releases += 1 }
        monitor.onDoubleTap = { doubleTaps += 1 }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        source.sendFlags(
            HotkeyEvent(
                keyCode: DictationHotkey.rightCommand.keyCode,
                rawFlags: 0,
                at: Date(timeIntervalSince1970: 1_000_000.05)
            )
        )
        source.sendFlags(
            HotkeyEvent(
                keyCode: DictationHotkey.rightCommand.keyCode,
                rawFlags: NSEvent.ModifierFlags.command.rawValue | 0x0000_0010,
                at: Date(timeIntervalSince1970: 1_000_000.2)
            )
        )

        XCTAssertEqual(doubleTaps, 1)
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(releases, 0)
    }

    func testРежимБезУдержанияМеняетСмыслНажатия() {
        var log: [String] = []
        monitor.onPress = { log.append("press") }
        monitor.onSingleTapWhileHandsFree = { log.append("stop") }
        monitor.start()
        monitor.isHandsFreeActive = true

        source.sendFlags(pressedRightCommand)

        XCTAssertEqual(log, ["stop"])
    }

    /// Смена клавиши посреди удержания обязана закончить диктовку.
    func testСменаКлавишиПосредиУдержанияОтпускает() {
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.start()
        source.sendFlags(pressedRightCommand)

        monitor.setHotkey(.fn)

        XCTAssertEqual(releases, 1)
    }

    // MARK: - Escape

    func testEscapeДоходит() {
        var escapes = 0
        monitor.onEscape = { escapes += 1 }
        monitor.start()

        source.sendKeyDown(HotkeyEvent(keyCode: UInt16(kVK_Escape), rawFlags: 0, at: Date()))

        XCTAssertEqual(escapes, 1)
    }

    /// Все остальные клавиши обязаны пройти мимо.
    ///
    /// Приложение обещает, что не запоминает и не обрабатывает чужие нажатия.
    func testОстальныеКлавишиНеТрогаются() {
        var escapes = 0
        monitor.onEscape = { escapes += 1 }
        monitor.start()

        for code in [kVK_ANSI_A, kVK_Return, kVK_Space, kVK_Tab, kVK_Delete] {
            source.sendKeyDown(HotkeyEvent(keyCode: UInt16(code), rawFlags: 0, at: Date()))
        }

        XCTAssertEqual(escapes, 0)
    }
}
