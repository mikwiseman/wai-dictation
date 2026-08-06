import DictationCore
import Foundation

/// Строка «stop → text: N ms» в панели.
///
/// Чистый тип, как `OverlayContent` и `ModelStatus`: форматирование числа —
/// это правило, а не вёрстка, и проверяется без панели и без модели.
///
/// Показывается **вторая** отметка — «⌘V отправлено». Она честнее остальных:
/// первая (движок вернул текст) не значит, что текст уже у человека, а третья
/// включает секунду защиты буфера, то есть ожидание, а не работу.
struct SpeedReadout: Equatable {
    let line: String
    /// Для VoiceOver — словами: «ms» синтезатор читает как «эмэс».
    let accessibilityLabel: String

    /// `nil`, если вставку никто не измерял. Лучше не показать ничего, чем
    /// показать число, посчитанное не от того.
    static func make(_ report: DictationSpeedReport) -> SpeedReadout? {
        guard let dispatched = report.toPasteDispatched else { return nil }

        let milliseconds = dispatched.components.seconds * 1000
            + dispatched.components.attoseconds / 1_000_000_000_000_000
        // Пол в одну миллисекунду: «0 ms» — не быстро, а неизмеримо, и читалось
        // бы как заведомая неправда.
        let clamped = max(1, milliseconds)

        if clamped < 1000 {
            return SpeedReadout(
                line: "stop → text: \(clamped) ms",
                accessibilityLabel: "Text ready \(clamped) milliseconds after you released the key"
            )
        }
        let seconds = Double(clamped) / 1000
        let text = String(format: "%.1f", seconds)
        return SpeedReadout(
            line: "stop → text: \(text) s",
            accessibilityLabel: "Text ready \(text) seconds after you released the key"
        )
    }
}
