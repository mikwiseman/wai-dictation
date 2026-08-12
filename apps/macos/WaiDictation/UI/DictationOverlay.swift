import AppKit
import DictationCore
import SwiftUI

/// Небольшая панель, показывающая, что происходит с диктовкой.
///
/// Панель не забирает фокус: пользователь диктует в другое приложение, и увод
/// фокуса сломал бы вставку. Плата за это — панель не достаётся VoiceOver сама
/// собой, поэтому каждое изменение состояния ещё и объявляется вслух. Это не
/// украшение: своего окна у приложения нет, и другого способа узнать, что
/// микрофон включён, у незрячего человека тоже нет.
@MainActor
public final class DictationOverlay: OverlayPresenting {
    private var panel: NSPanel?
    private let model: OverlayModel
    /// Подписка на изменение размера панели. Панель растёт за содержимым, а
    /// содержимое меняется прямо во время диктовки.
    ///
    /// Помечена `nonisolated(unsafe)`, потому что подписку снимает `deinit`, а
    /// он у изолированного класса — вне изоляции. Трогают её только с главного
    /// потока: панель целиком живёт на нём.
    nonisolated(unsafe) private var resizeObserver: (any NSObjectProtocol)?

    public init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4)
    ) {
        model = OverlayModel(announcer: announcer, noticeDuration: noticeDuration)
        model.onVisibilityChange = { [weak self] visible in
            if visible {
                self?.showPanel()
            } else {
                self?.hidePanel()
            }
        }
    }

    deinit {
        // Подписка, оставленная в центре уведомлений, переживает владельца.
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    nonisolated public func present(_ state: DictationState, elapsed: TimeInterval) async {
        await MainActor.run { model.show(state, elapsed: elapsed) }
    }

    nonisolated public func dismiss() async {
        await MainActor.run { model.hide() }
    }

    nonisolated public func presentNotice(_ notice: DictationNotice) async {
        await MainActor.run { model.showNotice(notice) }
    }

    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            // Текст диктовки не должен утекать в записи экрана через HUD.
            panel.sharingType = .none
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let hosting = NSHostingView(rootView: OverlayView(model: model))
            // Панель растёт за содержимым: сообщение в две строки не имеет
            // права обрезаться до «автоматич…» — обрезанный тост хуже молчания.
            hosting.sizingOptions = .preferredContentSize
            panel.contentView = hosting
            // Окно при смене размера держит левый верхний угол на месте. Ширина
            // же меняется прямо во время диктовки: с первым распознанным словом
            // появляется предпросмотр, и панель становится с 280 точек на 360.
            // Без пересчёта она уезжала на 80 точек вправо от центра экрана —
            // ровно в тот момент, когда человек на неё смотрит. Считаем по
            // факту изменения размера, а не по догадке о нём: сам размер
            // задаёт SwiftUI, и заранее он здесь неизвестен.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            }
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    /// Показать панель на том экране, где сейчас работает пользователь.
    ///
    /// Позиция пересчитывается на каждый показ: за время между диктовками
    /// монитор могли отключить или мышь могла уехать на другой.
    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 24
            )
        )
    }
}

/// Состояние панели: что на ней написано, видна ли она и что уже сказано вслух.
///
/// Живёт отдельно от `NSPanel` намеренно. Окно требует графического сеанса, а
/// правила показа — счётчик секунд, автоскрытие сообщения, объявления для
/// VoiceOver — проверяются без него.
/// Край предпросмотра: украшение поверх диктовки, поэтому отдельный протокол,
/// а не расширение ядра. Подставной оверлей в тестах записывает вызовы.
@MainActor
protocol PreviewPresenting: AnyObject {
    func updatePreview(confirmed: String, volatile: String)
    func updateInputLevel(_ level: Float)
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var notice: DictationNotice?
    /// Живой предпросмотр: устоявшийся текст и хвост, который ещё меняется.
    /// Появляется с первым словом, а не с включением микрофона: пустая рамка
    /// ожидания — это сценическое волнение, а не помощь.
    @Published private(set) var previewConfirmed: String = ""
    @Published private(set) var previewVolatile: String = ""
    /// Пик уровня микрофона (0…1) — точка записи пульсирует вместе с голосом.
    @Published private(set) var inputLevel: Float = 0

    var hasPreview: Bool { !previewConfirmed.isEmpty || !previewVolatile.isEmpty }

    /// Должна ли панель быть на экране. Показывает её владелец.
    private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?

    /// Идёт ли отсчёт секунд.
    var isTicking: Bool { timer != nil }

    var content: OverlayContent {
        OverlayContent.make(state: state, notice: notice, elapsed: elapsed)
    }

    private let announcer: any AccessibilityAnnouncing
    private let noticeDuration: Duration
    /// Помечен `nonisolated(unsafe)`, потому что таймер снимает `deinit`, а он у
    /// изолированного класса — вне изоляции. Трогают его только с главного
    /// потока: панель целиком живёт на нём.
    nonisolated(unsafe) private var timer: Timer?
    private var startedAt: Date?
    private var autoHide: Task<Void, Never>?
    /// Что уже сказано вслух. Счётчик секунд тикает дважды в секунду, и без
    /// этой памяти VoiceOver повторял бы «идёт запись» до конца диктовки.
    private var lastAnnouncement: String?

    init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4)
    ) {
        self.announcer = announcer
        self.noticeDuration = noticeDuration
    }

    deinit {
        // Таймер, оставленный в цикле выполнения, продолжает будить процесс и
        // после смерти владельца.
        timer?.invalidate()
        autoHide?.cancel()
    }

    /// Показать состояние диктовки.
    func show(_ state: DictationState, elapsed: TimeInterval) {
        cancelAutoHide()
        self.state = state
        notice = nil
        if state == .listening {
            // Новая запись — прежний предпросмотр не имеет права мигнуть.
            previewConfirmed = ""
            previewVolatile = ""
            inputLevel = 0
        }
        setElapsed(elapsed, ticking: state == .listening)
        setVisible(true)
        announceContent()
    }

    /// Обновить предпросмотр. VoiceOver намеренно молчит: читать поток
    /// меняющихся слов поверх собственной речи человека — абсурд.
    func updatePreview(confirmed: String, volatile: String) {
        previewConfirmed = confirmed
        previewVolatile = volatile
    }

    /// Ярлык панели для VoiceOver.
    var accessibilityLabel: String { content.accessibilityLabel }

    func updateInputLevel(_ level: Float) {
        inputLevel = min(1, max(0, level))
    }

    /// Показать сообщение и убрать его через положенное время.
    func showNotice(_ notice: DictationNotice) {
        cancelAutoHide()
        setElapsed(elapsed, ticking: false)
        self.notice = notice
        setVisible(true)
        announceContent()

        let duration = noticeDuration
        autoHide = Task { [weak self] in
            try? await Task.sleep(for: duration)
            // Отложенное скрытие принадлежит своему показу. Проверка отмены
            // обязательна: `try?` глотает её вместе с ошибкой, и без неё
            // отменённая задача досыпает не до конца, а просыпается сразу — и
            // уносит с экрана уже следующее сообщение.
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
            self.setVisible(false)
        }
    }

    /// Убрать панель.
    ///
    /// Сообщение остаётся на экране: человек должен успеть его прочесть, а
    /// уборка после сессии приходит сразу за ним.
    func hide() {
        setElapsed(elapsed, ticking: false)
        guard notice == nil else { return }
        cancelAutoHide()
        setVisible(false)
        // Следующая диктовка обязана объявиться заново, даже если состояние
        // совпадает с прошлым.
        lastAnnouncement = nil
    }

    /// Показать прошедшее время.
    ///
    /// Пока идёт запись, счётчик ведёт сама панель. Иначе он показывал бы «0 с»
    /// всю диктовку: ядро сообщает о начале записи один раз и следующий раз
    /// выходит на связь уже после её конца — то есть ровно тогда, когда счётчик
    /// уже не нужен. Секунды здесь единственный признак, что запись правда идёт.
    private func setElapsed(_ value: TimeInterval, ticking: Bool) {
        elapsed = value

        guard ticking else {
            timer?.invalidate()
            timer = nil
            startedAt = nil
            return
        }

        guard timer == nil else { return }
        startedAt = Date().addingTimeInterval(-value)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Отложенное скрытие прошлого показа больше не действует.
    private func cancelAutoHide() {
        autoHide?.cancel()
        autoHide = nil
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChange?(visible)
    }

    private func announceContent() {
        let content = self.content
        guard let announcement = content.announcement, announcement != lastAnnouncement else { return }
        lastAnnouncement = announcement
        announcer.announce(announcement, urgent: content.isAnnouncementUrgent)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    /// «Уменьшить движение»: пульс точки — украшение, и человек, который
    /// отключил движение в универсальном доступе, не обязан на него смотреть.
    /// Цвет точки при этом остаётся: он несёт смысл, а не движение.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let content = model.content
        let pulse = model.state == .listening && !reduceMotion

        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color(for: content.tone))
                .frame(width: 10, height: 10)
                // Точка дышит вместе с голосом: видно, что микрофон слышит.
                .scaleEffect(pulse ? 1 + CGFloat(model.inputLevel) * 0.6 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.inputLevel)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        // Счётчик перерисовывается дважды в секунду: без
                        // моноширинных цифр строка дрожит на каждой смене.
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.hasPreview {
                    // Хвост гипотезы важнее начала: показываем конец, максимум
                    // две строки, без прокрутки и без по-словной анимации.
                    (Text(model.previewConfirmed)
                        + Text(model.previewConfirmed.isEmpty || model.previewVolatile.isEmpty ? "" : " ")
                        + Text(model.previewVolatile).foregroundStyle(.secondary))
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Во время распознавания текст остаётся, но приглушён:
                        // пустота читалась бы как «мои слова пропали».
                        .opacity(model.state == .transcribing ? 0.5 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: model.hasPreview ? 360 : 280, alignment: .leading)
        // Материал, а не Liquid Glass — решение, а не долг. Стекло преломляет
        // только собственную иерархию вью: панель парит над чужими окнами, и
        // преломлять ей нечего (рендер «за окном» на Tahoe к тому же кэшируется
        // и не обновляется). HIG о том же: стекло — слой управления, HUD с
        // текстом — содержимое, ему положен материал. Материал сам честно
        // отвечает на «Уменьшить прозрачность».
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        // Панель читается одним элементом: цветная точка и счётчик по
        // отдельности не значат ничего.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }

    private func color(for tone: OverlayContent.Tone) -> Color {
        switch tone {
        case .idle: return .secondary
        case .recording: return .red
        case .working: return .blue
        case .info: return .blue
        case .warning: return .orange
        case .failure: return .red
        }
    }
}


extension DictationOverlay: PreviewPresenting {
    func updatePreview(confirmed: String, volatile: String) {
        model.updatePreview(confirmed: confirmed, volatile: volatile)
    }

    func updateInputLevel(_ level: Float) {
        model.updateInputLevel(level)
    }
}
