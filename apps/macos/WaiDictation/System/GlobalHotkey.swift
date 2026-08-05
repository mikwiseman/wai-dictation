import AppKit
import Carbon.HIToolbox
import Foundation

/// Клавиша, по которой начинается диктовка.
///
/// Все варианты — модификаторы: их можно удерживать, и они не отнимают у
/// приложений обычные сочетания.
public enum DictationHotkey: String, CaseIterable, Sendable, Codable {
    case fn
    case rightCommand
    case rightOption
    case leftControl

    public var title: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Right Command"
        case .rightOption: return "Right Option"
        case .leftControl: return "Left Control"
        }
    }

    /// Код конкретной физической клавиши.
    ///
    /// Нужен, чтобы отличить правый Command от левого: флаг у них один и тот же.
    var keyCode: UInt16 {
        switch self {
        case .fn: return UInt16(kVK_Function)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightOption: return UInt16(kVK_RightOption)
        case .leftControl: return UInt16(kVK_Control)
        }
    }

    /// Бит именно этой физической клавиши в маске модификаторов события.
    ///
    /// Общий флаг (`.command`) поднят, пока зажата **любая** клавиша этого вида.
    /// По нему отпускание правого Command неотличимо от «правый отпустили, а
    /// левый всё ещё держат» — маска в обоих случаях одинаковая, и отпускание
    /// теряется. Это не теория: диктовка в таком случае остаётся включённой
    /// навсегда, потому что остановить её больше нечем.
    ///
    /// Событие несёт вдобавок биты стороны клавиатуры, они и различают клавиши.
    /// Значения — `NX_DEVICE…KEYMASK` из `IOKit/hidsystem/IOLLEvent.h`.
    var sideMask: UInt {
        switch self {
        // У Fn стороны нет: клавиша ровно одна, и флаг у неё тоже один.
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        case .rightCommand: return 0x0000_0010
        case .rightOption: return 0x0000_0040
        case .leftControl: return 0x0000_0001
        }
    }

    /// Зажата ли эта клавиша при таком состоянии модификаторов.
    func isPressed(in rawFlags: UInt) -> Bool {
        rawFlags & sideMask != 0
    }

    /// Все общие флаги модификаторов, по которым строятся шорткаты.
    private static let chordMask: UInt =
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.shift.rawValue
        | NSEvent.ModifierFlags.function.rawValue

    /// Общий флаг вида этого модификатора («какой-то Command зажат»).
    private var kindMask: UInt {
        switch self {
        case .rightCommand: return NSEvent.ModifierFlags.command.rawValue
        case .rightOption: return NSEvent.ModifierFlags.option.rawValue
        case .leftControl: return NSEvent.ModifierFlags.control.rawValue
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    /// Нажат ли модификатор ОДИН, без спутников.
    ///
    /// «Cmd уже зажат, добавили Ctrl» — это путь к шорткату Cmd+Ctrl+…, а не
    /// к диктовке. Считать такой аккорд нажатием значило запускать запись
    /// фоном на каждом сложном шорткате.
    func isExclusivelyPressed(in rawFlags: UInt) -> Bool {
        guard isPressed(in: rawFlags) else { return false }
        return rawFlags & Self.chordMask & ~kindMask == 0
    }
}

// MARK: - Событие

/// Событие модификаторов без `NSEvent`.
///
/// Жест — это таблица «что было + что пришло → что делаем», и проверять её надо
/// таблицей. Собрать `NSEvent` в тесте нельзя, поэтому разбор жеста работает с
/// этой тройкой, а `NSEvent` превращается в неё на самом краю.
public struct HotkeyEvent: Sendable, Equatable {
    public let keyCode: UInt16
    /// Полная маска модификаторов из события — вместе с битами стороны клавиатуры.
    public let rawFlags: UInt
    public let at: Date

    public init(keyCode: UInt16, rawFlags: UInt, at: Date) {
        self.keyCode = keyCode
        self.rawFlags = rawFlags
        self.at = at
    }
}

// MARK: - Разбор жеста

/// Машина жестов горячей клавиши.
///
/// Помнит ровно две вещи: зажата ли клавиша и когда было прошлое нажатие.
/// Всё остальное решается на месте.
struct HotkeyGestureMachine {
    enum Action: Sendable, Equatable {
        case none
        /// Клавишу нажали — начинаем диктовку.
        case press
        /// Отпустили — заканчиваем. Короткий tap ждёт остаток окна
        /// двойного нажатия; долгое удержание заканчивается сразу.
        case release(after: TimeInterval)
        /// Второе нажатие подряд — режим без удержания.
        case doubleTap
        /// Нажатие во время записи без удержания — просьба остановить.
        case stopHandsFree
        /// Во время удержания нажали другую клавишу: это шорткат, а не
        /// диктовка. Начатую запись надо оборвать тихо — без вставки, без
        /// сообщений и без участия в двойном нажатии.
        case abortShortcut
    }

    private(set) var hotkey: DictationHotkey

    /// Идёт ли запись без удержания.
    ///
    /// Машина должна это знать, чтобы отличить «начать новую диктовку» от
    /// «остановить текущую»: жест в обоих случаях один и тот же — нажатие.
    var isHandsFreeActive = false

    /// Промежуток, в пределах которого второе нажатие считается двойным.
    let doubleTapWindow: TimeInterval

    private(set) var isHeld = false
    private var lastTapAt: Date?
    private var pressedAt: Date?
    /// Текущее удержание оказалось шорткатом: отпускание ничего не значит.
    private var abortedByShortcut = false

    init(hotkey: DictationHotkey, doubleTapWindow: TimeInterval = 0.35) {
        self.hotkey = hotkey
        self.doubleTapWindow = doubleTapWindow
    }

    /// Сменить клавишу.
    ///
    /// Возвращает действие, потому что смена посреди удержания обязана закрыть
    /// начатый жест: события старой клавиши после этого не придут вовсе, и
    /// отпускать диктовку будет нечем — она останется включённой навсегда.
    mutating func setHotkey(_ new: DictationHotkey) -> Action {
        let wasHeld = isHeld
        hotkey = new
        isHeld = false
        lastTapAt = nil
        pressedAt = nil
        // В режиме без удержания отпускание и так ничего не значит: запись идёт
        // до следующего нажатия, и оно придёт уже с новой клавиши.
        return wasHeld && !isHandsFreeActive ? .release(after: 0) : .none
    }

    /// Слежение остановлено — начатый жест оборван.
    mutating func reset() {
        isHeld = false
        lastTapAt = nil
        pressedAt = nil
        abortedByShortcut = false
    }

    /// Во время удержания нажали обычную клавишу — это шорткат.
    mutating func handleForeignKeyDown() -> Action {
        guard isHeld, !abortedByShortcut, !isHandsFreeActive else { return .none }
        return abortCurrentHold()
    }

    private mutating func abortCurrentHold() -> Action {
        abortedByShortcut = true
        lastTapAt = nil
        return .abortShortcut
    }

    mutating func handle(_ event: HotkeyEvent) -> Action {
        guard event.keyCode == hotkey.keyCode else {
            // Чужой модификатор. Если во время удержания флаги превратились в
            // аккорд (⌘ добавился к зажатому Ctrl) — человек тянется к
            // шорткату, и жест обрывается так же, как от обычной клавиши.
            if isHeld, !abortedByShortcut, !isHandsFreeActive,
               hotkey.isPressed(in: event.rawFlags),
               !hotkey.isExclusivelyPressed(in: event.rawFlags) {
                return abortCurrentHold()
            }
            return .none
        }

        let pressed = hotkey.isPressed(in: event.rawFlags)

        if pressed, !isHeld {
            // Аккорд с самого начала (Cmd уже зажат) — нажатием не считается.
            guard hotkey.isExclusivelyPressed(in: event.rawFlags) else { return .none }
            isHeld = true
            abortedByShortcut = false
            pressedAt = event.at

            if isHandsFreeActive {
                lastTapAt = nil
                return .stopHandsFree
            }

            if let lastTapAt, event.at.timeIntervalSince(lastTapAt) < doubleTapWindow {
                self.lastTapAt = nil
                return .doubleTap
            }

            lastTapAt = event.at
            return .press
        }

        if !pressed, isHeld {
            isHeld = false
            if abortedByShortcut {
                // Шорткат уже оборвал жест: отпускание не вставляет и не
                // открывает окно двойного нажатия.
                abortedByShortcut = false
                pressedAt = nil
                lastTapAt = nil
                return .none
            }
            let heldFor = pressedAt.map { event.at.timeIntervalSince($0) } ?? doubleTapWindow
            pressedAt = nil
            // В режиме без удержания отпускание ничего не значит: запись идёт
            // до следующего нажатия.
            guard !isHandsFreeActive else { return .none }
            let remaining = max(0, doubleTapWindow - heldFor)
            // NSEvent не обещает десятичную точность Date. Миллисекунды для
            // жеста более чем достаточны и не дают погрешности плавающей точки
            // удлинять или укорачивать окно между одинаковыми жестами.
            return .release(after: (remaining * 1_000).rounded() / 1_000)
        }

        return .none
    }
}

// MARK: - Источник событий

/// Откуда монитор берёт события клавиатуры.
///
/// За протоколом — потому что настоящий источник требует выданного человеком
/// доступа и живой клавиатуры: в тесте не будет ни того, ни другого, и без
/// подмены проверить нельзя ни одну строку регистрации.
@MainActor
public protocol HotkeyEventSource: AnyObject {
    /// Выдан ли универсальный доступ. Без него система не отдаёт события вовсе.
    var isTrusted: Bool { get }
    /// Подписаться на изменения модификаторов. `nil` — система отказала.
    func addFlagsMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any?
    /// Подписаться на обычные нажатия — ради Escape.
    func addKeyDownMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any?
    func removeMonitor(_ token: Any)
}

/// Настоящий источник: системный монитор событий.
///
/// Требует только «Универсальный доступ» — то же разрешение, что и вставка
/// текста. Отдельное «Мониторинг ввода» не запрашивается.
///
/// Монитор видит нажатия, но ничего не запоминает и не передаёт: событие
/// сравнивается с выбранной клавишей и Escape, всё остальное отбрасывается.
@MainActor
public final class SystemHotkeyEventSource: HotkeyEventSource {
    /// Global monitors do not receive events while this app is active. The
    /// onboarding test field is inside Wai Dictation, so each logical
    /// subscription owns both a global and a local monitor.
    private final class MonitorPair {
        let global: Any
        let local: Any

        init(global: Any, local: Any) {
            self.global = global
            self.local = local
        }
    }

    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func addFlagsMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        // Обработчик вызывается на главном потоке, поэтому входим в него
        // напрямую. Обёртка в отдельную задачу не гарантировала бы порядок:
        // нажатие и отпускание могли прийти в обратной последовательности, и
        // диктовка осталась бы включённой.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            MainActor.assumeIsolated { handler(HotkeyEvent(event)) }
        }
        guard let global else { return nil }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handler(HotkeyEvent(event))
            return event
        }
        guard let local else {
            NSEvent.removeMonitor(global)
            return nil
        }
        return MonitorPair(global: global, local: local)
    }

    public func addKeyDownMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated { handler(HotkeyEvent(event)) }
        }
        guard let global else { return nil }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handler(HotkeyEvent(event))
            // Ничего не перехватываем: Escape и остальные клавиши продолжают
            // обычный путь активного приложения.
            return event
        }
        guard let local else {
            NSEvent.removeMonitor(global)
            return nil
        }
        return MonitorPair(global: global, local: local)
    }

    public func removeMonitor(_ token: Any) {
        if let pair = token as? MonitorPair {
            NSEvent.removeMonitor(pair.global)
            NSEvent.removeMonitor(pair.local)
        } else {
            NSEvent.removeMonitor(token)
        }
    }
}

extension HotkeyEvent {
    init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue, at: Date())
    }
}

// MARK: - Монитор

/// Слежение за горячей клавишей во всех приложениях.
@MainActor
public protocol HotkeyMonitoring: AnyObject {
    var onPress: (() -> Void)? { get set }
    var onRelease: (() -> Void)? { get set }
    var onDoubleTap: (() -> Void)? { get set }
    /// Одиночное нажатие, когда идёт запись без удержания, — просьба остановить.
    var onSingleTapWhileHandsFree: (() -> Void)? { get set }
    /// Удержание оказалось шорткатом — оборвать запись тихо.
    var onAbortShortcut: (() -> Void)? { get set }
    var onEscape: (() -> Void)? { get set }

    /// Идёт ли сейчас запись без удержания.
    var isHandsFreeActive: Bool { get set }
    var isRunning: Bool { get }

    func setHotkey(_ hotkey: DictationHotkey)
    func start()
    func stop()
}

@MainActor
public final class GlobalHotkeyMonitor: HotkeyMonitoring {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public var onDoubleTap: (() -> Void)?
    public var onSingleTapWhileHandsFree: (() -> Void)?
    public var onAbortShortcut: (() -> Void)?
    public var onEscape: (() -> Void)?

    public var isHandsFreeActive: Bool {
        get { machine.isHandsFreeActive }
        set { machine.isHandsFreeActive = newValue }
    }

    public var hotkey: DictationHotkey { machine.hotkey }
    public private(set) var isRunning = false

    private let source: any HotkeyEventSource
    private var machine: HotkeyGestureMachine
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var pendingRelease: Task<Void, Never>?

    public init(
        source: any HotkeyEventSource = SystemHotkeyEventSource(),
        hotkey: DictationHotkey = .rightCommand
    ) {
        self.source = source
        machine = HotkeyGestureMachine(hotkey: hotkey)
    }

    public func setHotkey(_ hotkey: DictationHotkey) {
        deliver(machine.setHotkey(hotkey))
    }

    /// Запустить слежение.
    ///
    /// Вызывается повторно при каждой проверке разрешений: система выдаёт
    /// монитору события только после того, как пользователь дал доступ, и
    /// зарегистрироваться нужно уже после этого. Без повторного запуска клавиша
    /// молчала бы до перезапуска приложения.
    ///
    /// Но если слежение уже идёт, перезапускать его нельзя. Проверка разрешений
    /// тикает по таймеру, а перезапуск сбрасывал бы память о зажатой клавише —
    /// и отпускание, случившееся после тика, терялось бы. Диктовка при этом
    /// оставалась бы включённой: микрофон горит, запись идёт, остановить нечем.
    ///
    /// Стирать эту память полагается только `stop()` — им и пользуется
    /// пробуждение компьютера, где клавишу отпустили без нашего ведома.
    public func start() {
        guard !isRunning else { return }
        guard source.isTrusted else { return }

        guard let flags = source.addFlagsMonitor({ [weak self] event in
            self?.handleFlagsChanged(event)
        }) else { return }

        guard let keys = source.addKeyDownMonitor({ [weak self] event in
            self?.handleKeyDown(event)
        }) else {
            // Полурабочего слежения быть не должно. Оставленный без пары
            // монитор никем не снимается, а `start()` зовётся на каждой проверке
            // разрешений — живые подписки копились бы, и каждая отменяла бы
            // диктовку по одному Escape.
            source.removeMonitor(flags)
            return
        }

        flagsMonitor = flags
        keyMonitor = keys
        isRunning = true
    }

    public func stop() {
        pendingRelease?.cancel()
        pendingRelease = nil
        if let flagsMonitor { source.removeMonitor(flagsMonitor) }
        if let keyMonitor { source.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        isRunning = false
        machine.reset()
    }

    private func handleFlagsChanged(_ event: HotkeyEvent) {
        deliver(machine.handle(event))
    }

    private func handleKeyDown(_ event: HotkeyEvent) {
        // Escape отменяет диктовку. Решает это `AppState`: пока диктовки нет,
        // Escape — обычная клавиша, и трогать её нельзя.
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }
        // Любая другая клавиша во время удержания модификатора — шорткат
        // (Ctrl+C), а не диктовка: начатый жест обрывается тихо.
        deliver(machine.handleForeignKeyDown())
    }

    private func deliver(_ action: HotkeyGestureMachine.Action) {
        switch action {
        case .none: break
        case .press: onPress?()
        case let .release(delay):
            pendingRelease?.cancel()
            pendingRelease = nil
            guard delay > 0 else {
                onRelease?()
                return
            }
            pendingRelease = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.pendingRelease = nil
                self?.onRelease?()
            }
        case .doubleTap:
            // Первый быстрый tap уже запустил сессию, но его отпускание
            // ждало второго нажатия. Теперь это та же сессия без удержания:
            // отложенная остановка больше не принадлежит ей.
            pendingRelease?.cancel()
            pendingRelease = nil
            onDoubleTap?()
        case .stopHandsFree: onSingleTapWhileHandsFree?()
        case .abortShortcut: onAbortShortcut?()
        }
    }
}
