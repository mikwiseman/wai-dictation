import Foundation

/// Сколько прошло от отпускания клавиши до каждой заметной точки.
///
/// Отметок три, а не одна, потому что «быстро» — это три разных обещания, и
/// путать их нечестно:
///
/// - `toRecognizedText` — движок вернул текст;
/// - `toPasteDispatched` — ⌘V отправлено, то есть текст уже в чужом окне.
///   **Это заголовочная метрика** и то, что показывает HUD;
/// - `toClipboardRestored` — прежнее содержимое буфера вернулось на место.
///
/// Запрещённой метрики здесь нет намеренно: «время до возврата
/// `TextInserter.insert`» скоростью не является — внутри тысяча миллисекунд
/// защиты буфера. Это ожидание, а не работа.
///
/// `nil` означает «не измерено», и никогда — «ноль». Край, который не умеет
/// отдать отметку, не имеет права выглядеть мгновенным.
public struct DictationSpeedReport: Sendable, Equatable {
    public let toRecognizedText: Duration
    public let toPasteDispatched: Duration?
    public let toClipboardRestored: Duration?
    /// Сколько микрофон поднимался до первого кадра. Не входит в отсчёт от
    /// отпускания — это разогрев перед фразой, а не после неё.
    public let microphoneStartup: Duration?

    public init(
        toRecognizedText: Duration,
        toPasteDispatched: Duration? = nil,
        toClipboardRestored: Duration? = nil,
        microphoneStartup: Duration? = nil
    ) {
        self.toRecognizedText = toRecognizedText
        self.toPasteDispatched = toPasteDispatched
        self.toClipboardRestored = toClipboardRestored
        self.microphoneStartup = microphoneStartup
    }
}

/// Когда вставка сделала то, что видно человеку.
///
/// Отметки снимает сам вставщик: снаружи их не взять, потому что `insert`
/// возвращается только через секунду защиты буфера.
public struct InsertionMarks: Sendable, Equatable {
    public let pasteDispatchedAt: ContinuousClock.Instant?
    public let clipboardRestoredAt: ContinuousClock.Instant?

    public init(
        pasteDispatchedAt: ContinuousClock.Instant? = nil,
        clipboardRestoredAt: ContinuousClock.Instant? = nil
    ) {
        self.pasteDispatchedAt = pasteDispatchedAt
        self.clipboardRestoredAt = clipboardRestoredAt
    }
}
