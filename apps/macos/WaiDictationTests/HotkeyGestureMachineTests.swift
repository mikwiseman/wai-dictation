import AppKit
import Carbon.HIToolbox
import XCTest

/// Биты модификаторов в том виде, в каком их присылает система.
///
/// Общий флаг говорит «клавиша такого вида зажата», бит стороны — какая именно.
private enum Bits {
    static let command = NSEvent.ModifierFlags.command.rawValue
    static let control = NSEvent.ModifierFlags.control.rawValue
    static let option = NSEvent.ModifierFlags.option.rawValue
    static let function = NSEvent.ModifierFlags.function.rawValue

    static let leftCommandSide: UInt = 0x0000_0008
    static let rightCommandSide: UInt = 0x0000_0010
    static let leftControlSide: UInt = 0x0000_0001
    static let rightControlSide: UInt = 0x0000_2000
    static let rightOptionSide: UInt = 0x0000_0040
}

private let start = Date(timeIntervalSince1970: 1_000_000)

private func event(
    _ hotkey: DictationHotkey,
    flags: UInt,
    after seconds: TimeInterval = 0
) -> HotkeyEvent {
    HotkeyEvent(keyCode: hotkey.keyCode, rawFlags: flags, at: start.addingTimeInterval(seconds))
}

final class HotkeyGestureMachineTests: XCTestCase {
    // MARK: - Шорткаты не диктовка

    /// Ctrl+C: модификатор нажат, затем буква. Это шорткат, а не диктовка —
    /// начатый жест обрывается тихо, без вставки и без сообщений.
    func testКлавишаВоВремяУдержанияОбрываетЖест() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        XCTAssertEqual(
            machine.handle(event(.leftControl, flags: Bits.control | Bits.leftControlSide)),
            .press
        )
        XCTAssertEqual(machine.handleForeignKeyDown(), .abortShortcut)
        // Отпускание модификатора после шортката не вставляет ничего.
        XCTAssertEqual(machine.handle(event(.leftControl, flags: 0, after: 0.1)), .none)
    }

    /// Ctrl+C, затем Ctrl+V в пределах окна двойного нажатия. Раньше второе
    /// нажатие включало запись без удержания — фоном и навсегда.
    func testДваШорткатаПодрядНеВключаютЗаписьБезУдержания() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        _ = machine.handle(event(.leftControl, flags: Bits.control | Bits.leftControlSide))
        XCTAssertEqual(machine.handleForeignKeyDown(), .abortShortcut)
        _ = machine.handle(event(.leftControl, flags: 0, after: 0.08))

        // Второй шорткат сразу следом: press, но НЕ doubleTap.
        XCTAssertEqual(
            machine.handle(
                event(.leftControl, flags: Bits.control | Bits.leftControlSide, after: 0.15)
            ),
            .press
        )
    }

    /// Аккорд из модификаторов (⌘ уже зажат, добавили Ctrl) — не нажатие:
    /// человек тянется к Cmd+Ctrl-шорткату, а не к диктовке.
    func testАккордМодификаторовНеНачинаетДиктовку() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        XCTAssertEqual(
            machine.handle(
                event(
                    .leftControl,
                    flags: Bits.command | Bits.leftCommandSide | Bits.control | Bits.leftControlSide
                )
            ),
            .none
        )
    }

    /// Второй модификатор, добавленный ВО ВРЕМЯ удержания, тоже обрывает жест.
    func testМодификаторВоВремяУдержанияОбрываетЖест() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        _ = machine.handle(event(.leftControl, flags: Bits.control | Bits.leftControlSide))
        // Пришло событие чужого модификатора: флаги теперь содержат ⌘ и Ctrl.
        let chord = HotkeyEvent(
            keyCode: 55,
            rawFlags: Bits.command | Bits.leftCommandSide | Bits.control | Bits.leftControlSide,
            at: start.addingTimeInterval(0.05)
        )
        XCTAssertEqual(machine.handle(chord), .abortShortcut)
        XCTAssertEqual(machine.handle(event(.leftControl, flags: 0, after: 0.2)), .none)
    }

    /// Обрыв во время записи без удержания невозможен: там модификатор давно
    /// отпущен, и шорткаты человека к жесту не относятся.
    func testКлавишиВоВремяЗаписиБезУдержанияНеОбрываютЕё() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)
        machine.isHandsFreeActive = true

        XCTAssertEqual(machine.handleForeignKeyDown(), .none)
    }

    // MARK: - Удержание

    func testУдержаниеДаётНажатиеИОтпускание() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)

        XCTAssertEqual(
            machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide)),
            .press
        )
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 1)), .release(after: 0))
    }

    func testПовторныеСобытияВоВремяУдержанияНичегоНеДобавляют() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        // Автоповтор и прочие лишние события: жест уже начат, второго начала нет.
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.1)), .none)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.2)), .none)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.3)), .release(after: 0.05))
    }

    func testЧужаяКлавишаНеТрогаетЖест() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        let alien = HotkeyEvent(
            keyCode: UInt16(kVK_Shift),
            rawFlags: NSEvent.ModifierFlags.shift.rawValue,
            at: start
        )

        XCTAssertEqual(machine.handle(alien), .none)
        XCTAssertFalse(machine.isHeld)
    }

    /// Флаг Fn поднимается не только самой клавишей 🌐.
    ///
    /// Система помечает им целый разряд клавиш — стрелки, F1–F12, Home и
    /// прочие, — и он приходит вместе с чужими событиями. Без отбора по коду
    /// клавиши диктовка начиналась бы от нажатия на стрелку.
    func testСобытиеЧужойКлавишиСФлагомFnНеНачинаетДиктовку() {
        var machine = HotkeyGestureMachine(hotkey: .fn)
        let alien = HotkeyEvent(
            keyCode: UInt16(kVK_Shift),
            rawFlags: Bits.function | NSEvent.ModifierFlags.shift.rawValue,
            at: start
        )

        XCTAssertEqual(machine.handle(alien), .none)
        XCTAssertFalse(machine.isHeld)

        // А сама 🌐 — начинает.
        XCTAssertEqual(machine.handle(event(.fn, flags: Bits.function, after: 0.1)), .press)
    }

    /// Отпускание правой клавиши при зажатой левой обязано дойти.
    ///
    /// Общий флаг `.command` поднят, пока держат ЛЮБОЙ Command. Разбор по нему
    /// не видит отпускания правого — и диктовка остаётся включённой навсегда:
    /// микрофон горит, запись идёт, остановить нечем.
    func testОтпусканиеПравогоCommandПриЗажатомЛевом() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)

        // Левый Command уже держат: его события отсеиваются по коду клавиши.
        XCTAssertEqual(
            machine.handle(
                HotkeyEvent(
                    keyCode: UInt16(kVK_Command),
                    rawFlags: Bits.command | Bits.leftCommandSide,
                    at: start
                )
            ),
            .none
        )

        XCTAssertEqual(
            machine.handle(
                event(
                    .rightCommand,
                    flags: Bits.command | Bits.leftCommandSide | Bits.rightCommandSide,
                    after: 0.1
                )
            ),
            .press
        )

        // Правый отпущен, левый всё ещё зажат — общий флаг остался поднятым.
        XCTAssertEqual(
            machine.handle(
                event(.rightCommand, flags: Bits.command | Bits.leftCommandSide, after: 0.5)
            ),
            .release(after: 0)
        )
    }

    func testОтпусканиеЛевогоControlПриЗажатомПравом() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        XCTAssertEqual(
            machine.handle(
                event(
                    .leftControl,
                    flags: Bits.control | Bits.rightControlSide | Bits.leftControlSide
                )
            ),
            .press
        )
        XCTAssertEqual(
            machine.handle(
                event(.leftControl, flags: Bits.control | Bits.rightControlSide, after: 0.4)
            ),
            .release(after: 0)
        )
    }

    func testПравыйOptionНеСрабатываетОтЛевого() {
        var machine = HotkeyGestureMachine(hotkey: .rightOption)

        // Общий флаг Option поднят, но бит правой стороны — нет: держат левый.
        XCTAssertEqual(machine.handle(event(.rightOption, flags: Bits.option)), .none)
        XCTAssertFalse(machine.isHeld)

        XCTAssertEqual(
            machine.handle(event(.rightOption, flags: Bits.option | Bits.rightOptionSide, after: 0.1)),
            .press
        )
    }

    func testFnРаспознаётсяПоСвоемуФлагу() {
        var machine = HotkeyGestureMachine(hotkey: .fn)

        XCTAssertEqual(machine.handle(event(.fn, flags: Bits.function)), .press)
        XCTAssertEqual(machine.handle(event(.fn, flags: 0, after: 0.6)), .release(after: 0))
    }

    // MARK: - Двойное нажатие

    func testВтороеНажатиеВОкнеЭтоДвойное() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand, doubleTapWindow: 0.35)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.05)), .release(after: 0.3))
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.2)), .doubleTap)
    }

    func testВтороеНажатиеЗаОкномЭтоОбычноеНажатие() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand, doubleTapWindow: 0.35)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.05)), .release(after: 0.3))
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.5)), .press)
    }

    func testТретьеНажатиеПослеДвойногоНачинаетСчётЗаново() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand, doubleTapWindow: 0.35)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.05)), .release(after: 0.3))
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.1)), .doubleTap)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.15)), .release(after: 0.3))
        // Три нажатия подряд не означают «двойное дважды».
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.2)), .press)
    }

    // MARK: - Режим без удержания

    func testВРежимеБезУдержанияНажатиеОстанавливает() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        machine.isHandsFreeActive = true
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .stopHandsFree)
        // Отпускание здесь ничего не значит: запись идёт до следующего нажатия.
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.1)), .none)
    }

    func testПослеРежимаБезУдержанияОтпусканиеСноваРаботает() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        machine.isHandsFreeActive = true
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .stopHandsFree)
        machine.isHandsFreeActive = false
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.1)), .release(after: 0.25))
    }

    // MARK: - Смена клавиши

    /// Клавишу сменили, пока её держали.
    ///
    /// События старой клавиши после этого не придут вовсе: монитор сравнивает
    /// код с новой. Без явного закрытия жеста отпускать диктовку становится
    /// нечем, и она остаётся включённой навсегда.
    func testСменаКлавишиПосредиУдержанияЗакрываетЖест() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)

        XCTAssertEqual(
            machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide)),
            .press
        )
        XCTAssertEqual(machine.setHotkey(.fn), .release(after: 0))
        XCTAssertFalse(machine.isHeld)
    }

    func testСменаКлавишиБезУдержанияНичегоНеЗакрывает() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        XCTAssertEqual(machine.setHotkey(.fn), .none)
    }

    func testСменаКлавишиВРежимеБезУдержанияНеОстанавливаетЗапись() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        machine.isHandsFreeActive = true
        _ = machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide))

        // В этом режиме запись останавливается нажатием, а не отпусканием.
        XCTAssertEqual(machine.setHotkey(.fn), .none)
    }

    func testПослеСменыРаботаетНоваяКлавишаИМолчитСтарая() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        _ = machine.setHotkey(.leftControl)

        XCTAssertEqual(
            machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide)),
            .none
        )
        XCTAssertEqual(
            machine.handle(
                event(.leftControl, flags: Bits.control | Bits.leftControlSide, after: 0.1)
            ),
            .press
        )
    }

    func testСбросОбрываетЖест() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        _ = machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide))

        machine.reset()

        XCTAssertFalse(machine.isHeld)
        // Отпускание уже оборванного жеста не выдаёт второй остановки.
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.1)), .none)
    }

    // MARK: - Раскладка клавиш

    func testУКаждойКлавишиСвойКодИСвойБит() {
        // Коды обязаны различаться: по ним отсеиваются чужие события.
        let codes = DictationHotkey.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count)

        XCTAssertEqual(DictationHotkey.rightCommand.sideMask, Bits.rightCommandSide)
        XCTAssertEqual(DictationHotkey.rightOption.sideMask, Bits.rightOptionSide)
        XCTAssertEqual(DictationHotkey.leftControl.sideMask, Bits.leftControlSide)
        XCTAssertEqual(DictationHotkey.fn.sideMask, Bits.function)

        // Бит стороны не должен совпадать с общим флагом: иначе различать
        // клавиши было бы нечем.
        XCTAssertNotEqual(DictationHotkey.rightCommand.sideMask, Bits.command)
        XCTAssertNotEqual(DictationHotkey.leftControl.sideMask, Bits.control)
        XCTAssertNotEqual(DictationHotkey.rightOption.sideMask, Bits.option)
    }
}
