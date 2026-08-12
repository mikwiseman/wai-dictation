import DictationCore
import Foundation

/// Что написано на панели диктовки.
///
/// Панель — единственный канал обратной связи во время диктовки: своего окна у
/// приложения нет. Поэтому её содержимое собирается отдельным типом и
/// проверяется таблицей состояний, а не разглядыванием экрана.
struct OverlayContent: Equatable {
    enum Tone: Equatable {
        case idle
        case recording
        case working
        case info
        case warning
        case failure
    }

    var title: String
    var subtitle: String?
    var tone: Tone
    /// Ярлык всей панели для VoiceOver.
    ///
    /// Панель нарочно не забирает фокус — иначе сломалась бы вставка, — то есть
    /// сама по себе она незрячему человеку не достаётся никак. Ярлык нужен для
    /// тех, кто ищет её курсором VoiceOver.
    var accessibilityLabel: String
    /// Что сказать вслух при переходе в это состояние. `nil` — говорить нечего.
    var announcement: String?
    /// Срочное объявление перебивает то, что VoiceOver читает сейчас.
    var isAnnouncementUrgent: Bool

    static func make(
        state: DictationState,
        notice: DictationNotice?,
        elapsed: TimeInterval
    ) -> OverlayContent {
        // Сообщение важнее состояния: оно и показывается вместо него.
        if let notice {
            return OverlayContent(
                title: notice.message,
                subtitle: nil,
                tone: tone(for: notice.kind),
                accessibilityLabel: notice.message,
                announcement: notice.message,
                // Сообщение приходит ровно тогда, когда что-то пошло не так.
                // Дожидаться конца чужой фразы значит сказать об этом слишком
                // поздно, чтобы это было полезно.
                isAnnouncementUrgent: notice.kind != .info
            )
        }

        switch state {
        case .idle:
            return OverlayContent(
                title: "Done",
                subtitle: nil,
                tone: .idle,
                accessibilityLabel: "Not dictating",
                // Панель в этот момент убирается. Объявлять «готово» в пустоту
                // незачем: человек и так слышал, что диктовка закончилась.
                announcement: nil,
                isAnnouncementUrgent: false
            )

        case .preparing:
            return OverlayContent(
                title: "Turning on the microphone…",
                subtitle: nil,
                tone: .working,
                accessibilityLabel: "Turning on the microphone",
                announcement: "Turning on the microphone",
                isAnnouncementUrgent: false
            )

        case .listening:
            let seconds = spokenSeconds(elapsed)
            return OverlayContent(
                title: "Listening",
                // Коротко нарочно: «отпусти — вставится» человек уже делает
                // руками, держа клавишу. Остаётся только выход — Esc. Полная
                // инструкция живёт в объявлении ниже: для незрячего оно —
                // единственный интерфейс.
                subtitle: "\(shortSeconds(elapsed)) · Esc to cancel",
                tone: .recording,
                accessibilityLabel: "Recording, \(seconds). Press the hotkey to insert. Press Escape to delete the recording.",
                // Главное объявление во всём приложении: без него незрячий
                // человек не знает, что микрофон включён.
                announcement: "Recording. Press the hotkey to insert. Press Escape to delete the recording.",
                isAnnouncementUrgent: true
            )

        case .transcribing:
            return OverlayContent(
                title: "Transcribing…",
                subtitle: shortSeconds(elapsed),
                tone: .working,
                accessibilityLabel: "Recording stopped, transcribing speech",
                announcement: "Recording stopped, transcribing speech",
                isAnnouncementUrgent: false
            )

        case .inserting:
            return OverlayContent(
                title: "Inserting",
                subtitle: nil,
                tone: .working,
                accessibilityLabel: "Inserting text",
                announcement: "Inserting text",
                isAnnouncementUrgent: false
            )
        }
    }

    private static func tone(for kind: DictationNotice.Kind) -> Tone {
        switch kind {
        case .info: return .info
        case .warning: return .warning
        case .failure: return .failure
        }
    }

    /// Счётчик на панели. Коротко — места там нет.
    private static func shortSeconds(_ elapsed: TimeInterval) -> String {
        String(format: "%.0f s", max(0, elapsed))
    }

    /// То же число словами.
    ///
    /// «5 с» VoiceOver читает как «5 эс». Для единственного признака того, что
    /// запись правда идёт, этого мало.
    static func spokenSeconds(_ elapsed: TimeInterval) -> String {
        let value = Int(max(0, elapsed).rounded())
        return "\(value) \(secondsWord(value))"
    }

    /// Форма слова «секунда» для числа.
    private static func secondsWord(_ value: Int) -> String {
        value == 1 ? "second" : "seconds"
    }
}
