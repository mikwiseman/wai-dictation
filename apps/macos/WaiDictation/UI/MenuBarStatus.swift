import DictationCore

/// Значок в строке меню и то, что о нём говорят.
///
/// Значок — единственное постоянное присутствие приложения на экране. Картинка
/// без описания для незрячего человека не существует вовсе: VoiceOver прочитает
/// имя системного символа вроде «mic.slash» или промолчит.
enum MenuBarStatus {
    static func iconName(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredWork: Bool = false
    ) -> String {
        switch state {
        case .listening: return "mic.fill"
        case .transcribing, .inserting:
            // Работа обозначается бейджем-многоточием: он появляется, когда
            // распознавание пошло, и исчезает вместе с покоем. Цветную точку в
            // строке меню сделать нельзя — MenuBarExtra принудительно
            // обесцвечивает значок до template, — а во время записи оранжевую
            // точку у Control Center показывает сама macOS. Анимировать тоже
            // нельзя: SwiftUI-анимация в NSStatusItem на Tahoe сломана, смена
            // статичных значков — единственный надёжный язык состояния.
            if #available(macOS 15, *) {
                return "microphone.badge.ellipsis"
            }
            // На macOS 14 символа с бейджем ещё нет.
            return "waveform"
        case .preparing, .idle:
            // Спасённый текст или запись видны только внутри меню — а меню
            // открывают, когда что-то заподозрили. Восклицательный бейдж на
            // волне — единственный способ сказать «есть несделанная работа»
            // человеку, который в меню не заглядывает. Имя символа закреплено
            // тестом на существование: несуществующее имя даёт пустой значок,
            // что хуже отсутствия бейджа.
            if hasRecoveredWork, state == .idle {
                return "waveform.badge.exclamationmark"
            }
            return isDictationReady ? "mic" : "mic.slash"
        }
    }

    /// Ярлык значка. Начинается с имени приложения: в строке меню значков много,
    /// и «идёт запись» без хозяина ничего не говорит.
    static func accessibilityLabel(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredWork: Bool = false
    ) -> String {
        switch state {
        case .listening: return "Wai Dictation: recording"
        case .transcribing: return "Wai Dictation: transcribing speech"
        case .inserting: return "Wai Dictation: inserting text"
        case .preparing: return "Wai Dictation: turning on the microphone"
        case .idle:
            // Бейдж на значке обязан звучать и для VoiceOver: картинка без
            // слов для незрячего не существует.
            if hasRecoveredWork {
                return "Wai Dictation: last dictation needs attention — open the menu"
            }
            return isDictationReady
                ? "Wai Dictation: ready to dictate"
                : "Wai Dictation: setup needed"
        }
    }

    /// Первая строка меню — она же объяснение, что делать.
    ///
    /// Про несделанную работу она говорит раньше, чем про клавишу. Панель
    /// диктовки — тост: она живёт четыре секунды и уходит, и это правильно,
    /// потому что закрыть её нечем — фокуса она не берёт и кнопки закрытия у
    /// неё нет, а несгораемое окошко поверх чужой работы было бы хуже беды,
    /// которую оно объясняет. Значит, объяснение обязано где-то осесть
    /// насовсем, и это место — меню: пункты «Insert Last Dictation» и
    /// «Copy Last Dictation» тут же под строкой.
    /// Раньше сообщение «текст не вставлен» просто исчезало, и человек, который
    /// отвернулся, терял и причину, и знание, что текст ещё жив.
    static func statusLine(
        state: DictationState,
        isDictationReady: Bool,
        isHandsFreeActive: Bool,
        hotkeyTitle: String,
        hasRecoveredText: Bool = false,
        hasRecoveredRecording: Bool = false
    ) -> String {
        switch state {
        case .idle:
            // Текст важнее записи: он уже распознан, и до готового результата
            // человеку остался один пункт меню. Куда идти, объясняют сами
            // пункты под строкой — «Insert Last Dictation», «Copy…».
            if hasRecoveredText {
                return "Last dictation wasn't inserted"
            }
            if hasRecoveredRecording {
                return "A recording is waiting to be transcribed"
            }
            return isDictationReady
                ? "Hold \(hotkeyTitle) and speak"
                : "Setup needed"
        case .preparing: return "Turning on the microphone…"
        case .listening:
            // В режиме без удержания клавишу отпускают, а запись продолжается.
            // Не сказать об этом — значит оставить человека с включённым
            // микрофоном и уверенностью, что он уже выключен.
            return isHandsFreeActive
                ? "Listening — press \(hotkeyTitle) to finish"
                : "Listening"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting text"
        }
    }
}
