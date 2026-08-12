import AppKit
import LocalASR
import DictationCore
import XCTest

/// Значок в строке меню — единственное постоянное присутствие приложения.
///
/// Картинка без описания для незрячего человека не существует вовсе: VoiceOver
/// прочитает имя системного символа или промолчит.
final class MenuBarStatusTests: XCTestCase {
    /// Работа обозначается бейджем-многоточием на микрофоне: он появляется,
    /// когда распознавание пошло, и исчезает вместе с покоем. Цветной точки в
    /// строке меню не бывает — MenuBarExtra принудительно обесцвечивает
    /// значок, а во время записи системную оранжевую точку у Control Center
    /// показывает сама macOS.
    func testЗначокРазличаетЗаписьРаботуИПокой() {
        XCTAssertEqual(MenuBarStatus.iconName(state: .listening, isDictationReady: true), "mic.fill")
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .transcribing, isDictationReady: true),
            "microphone.badge.ellipsis"
        )
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .inserting, isDictationReady: true),
            "microphone.badge.ellipsis"
        )
        XCTAssertEqual(MenuBarStatus.iconName(state: .idle, isDictationReady: true), "mic")
    }

    /// Ненастроенное приложение обязано отличаться значком.
    ///
    /// Иначе человек будет держать клавишу и не понимать, почему ничего не
    /// происходит.
    func testБезНастройкиЗначокПеречёркнут() {
        XCTAssertEqual(MenuBarStatus.iconName(state: .idle, isDictationReady: false), "mic.slash")
    }

    func testУЗначкаЕстьОписаниеВЛюбомСостоянии() {
        let states: [DictationState] = [.idle, .preparing, .listening, .transcribing, .inserting]

        for state in states {
            for ready in [true, false] {
                let label = MenuBarStatus.accessibilityLabel(state: state, isDictationReady: ready)
                XCTAssertFalse(label.isEmpty)
                // В строке меню значков много: «идёт запись» без хозяина
                // ничего не говорит.
                XCTAssertTrue(label.hasPrefix("Wai Dictation"), "«\(label)» не называет приложение")
            }
        }
    }

    func testОписаниеЗначкаНазываетТоЧтоПроисходит() {
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .listening, isDictationReady: true),
            "Wai Dictation: recording"
        )
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .idle, isDictationReady: false),
            "Wai Dictation: setup needed"
        )
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .idle, isDictationReady: true),
            "Wai Dictation: ready to dictate"
        )
    }

    func testПерваяСтрокаМенюГоворитЧтоДелать() {
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Right Command"),
            "Hold Right Command and speak"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: false, isHandsFreeActive: false, hotkeyTitle: "Right Command"),
            "Setup needed"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .listening, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Fn (🌐)"),
            "Listening"
        )
    }
}

/// Меню в строке меню: что оно предлагает про модель.
///
/// Раньше меню знало про модель один булев и предлагало «Скачать» даже посреди
/// загрузки: нажатие уходило в никуда, а строка состояния говорила «Нужна
/// настройка», ни словом не упоминая идущую загрузку. Теперь меню берёт те же
/// шесть состояний, что и оба экрана.
@MainActor
final class MenuModelOfferTests: XCTestCase {
    private func status(for state: ModelState) -> ModelStatus {
        ModelStatus.make(state: state, isPreparingEngine: false, place: .settings)
    }

    func testПосредиЗагрузкиНеПредлагаетСкачать() {
        let model = status(for: .downloading(receivedBytes: 200_000_000, totalBytes: 483_105_645))

        XCTAssertFalse(
            model.actions.contains(.install),
            "Пока идёт загрузка, предлагать начать её заново нечестно: нажатие ничего не сделает"
        )
        XCTAssertNotNil(model.progressLabel, "Человек должен видеть, что загрузка идёт")
    }

    func testПосредиПроверкиТожеНеПредлагает() {
        let model = status(for: .verifying(checked: 8, total: 21))

        XCTAssertFalse(model.actions.contains(.install))
        XCTAssertNotNil(model.progressLabel)
    }

    func testПослеОшибкиПредлагаетПовторить() {
        let model = status(for: .failed(.download("сеть недоступна")))

        XCTAssertTrue(model.actions.contains(.retry), "Из ошибки должен быть выход")
    }

    func testКогдаМоделиНетПредлагаетСкачать() {
        let model = status(for: .notInstalled)

        XCTAssertTrue(model.actions.contains(.install))
    }

    /// Меню обязано называть настоящий остаток, а не полную установку.
    ///
    /// После обновления со сборки без подсказчика докачать надо ~103 МБ, а меню
    /// брало объём по умолчанию и обещало 586 — ошибка в пять раз. По этой
    /// цифре решают, жать ли на дорогой или медленной сети.
    func testОстатокЗагрузкиНеПодменяетсяПолнымОбъёмом() {
        let model = ModelStatus.make(
            state: .notInstalled,
            isPreparingEngine: false,
            place: .settings,
            downloadMegabytes: 103
        )

        let title = model.title(for: .install)
        XCTAssertTrue(title.contains("103 MB"), "сказано: \(title)")
        XCTAssertFalse(title.contains("586"), "полный объём вместо остатка: \(title)")
    }
}

/// Режим без удержания в строке меню.
@MainActor
final class MenuHandsFreeLineTests: XCTestCase {
    func testВРежимеБезУдержанияСказаноКакЗакончить() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: true,
            hotkeyTitle: "Right Command"
        )

        XCTAssertTrue(
            line.contains("Right Command"),
            "Клавишу отпустили, а запись идёт — человек обязан узнать, чем её закончить: \(line)"
        )
    }

    func testВОбычномРежимеЛишнегоНеГоворит() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Right Command"
        )

        XCTAssertEqual(line, "Listening", "Клавиша зажата — объяснять нечего")
    }
}

/// Несделанная работа в первой строке меню.
///
/// Панель диктовки — тост на четыре секунды. Человек, который отвернулся,
/// раньше терял и объяснение, и знание, что распознанный текст ещё жив. Меню
/// держит это столько, сколько нужно.
@MainActor
final class MenuRecoveryLineTests: XCTestCase {
    private func line(text: Bool = false, recording: Bool = false) -> String {
        MenuBarStatus.statusLine(
            state: .idle,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Right Command",
            hasRecoveredText: text,
            hasRecoveredRecording: recording
        )
    }

    func testНевставленныйТекстНазываетсяВПервойСтроке() {
        // Без «saved below»: заголовков-секций в меню больше нет, кнопки под
        // строкой называют себя сами — «Insert Last Dictation», «Copy…».
        XCTAssertEqual(line(text: true), "Last dictation wasn't inserted")
    }

    func testСохранённаяЗаписьТожеНазывается() {
        XCTAssertEqual(line(recording: true), "A recording is waiting to be transcribed")
    }

    /// Текст ближе к результату, чем запись: его осталось только вставить.
    func testТекстВажнееЗаписи() {
        XCTAssertEqual(line(text: true, recording: true), line(text: true))
    }

    func testБезНесделаннойРаботыСтрокаПрежняя() {
        XCTAssertEqual(line(), "Hold Right Command and speak")
    }

    /// Пока диктовка идёт, первая строка про неё и есть: спасённый текст
    /// подождёт до покоя, а перебивать им живую запись нельзя.
    func testВоВремяДиктовкиСтрокаПроДиктовку() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Right Command",
            hasRecoveredText: true
        )

        XCTAssertEqual(line, "Listening")
    }
}

/// Бейдж несделанной работы на значке в строке меню.
@MainActor
final class MenuBarBadgeTests: XCTestCase {
    func testВПокоеСоСпасённымТекстомЗначокНоситБейдж() {
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .idle, isDictationReady: true, hasRecoveredWork: true),
            "waveform.badge.exclamationmark",
            "Человек, не открывающий меню, иначе не узнает о спасённом тексте"
        )
    }

    func testВоВремяДиктовкиБейджНеПеребиваетЖивоеСостояние() {
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .listening, isDictationReady: true, hasRecoveredWork: true),
            "mic.fill",
            "Идущая запись важнее прошлой беды"
        )
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .transcribing, isDictationReady: true, hasRecoveredWork: true),
            "microphone.badge.ellipsis"
        )
    }

    func testСимволБейджаСуществуетВСистеме() {
        // Несуществующее имя SF Symbol даёт ПУСТОЙ значок в строке меню — хуже
        // отсутствия бейджа. Тест прибивает имя к реальности системы.
        let name = MenuBarStatus.iconName(state: .idle, isDictationReady: true, hasRecoveredWork: true)
        XCTAssertNotNil(
            NSImage(systemSymbolName: name, accessibilityDescription: nil),
            "Символ «\(name)» не существует в этой версии macOS"
        )
    }

    func testВсеИменаЗначковСуществуют() {
        for state in [DictationState.idle, .preparing, .listening, .transcribing, .inserting] {
            for ready in [true, false] {
                for recovered in [true, false] {
                    let name = MenuBarStatus.iconName(
                        state: state, isDictationReady: ready, hasRecoveredWork: recovered
                    )
                    XCTAssertNotNil(
                        NSImage(systemSymbolName: name, accessibilityDescription: nil),
                        "Символ «\(name)» не существует"
                    )
                }
            }
        }
    }

    func testБейджЗвучитДляVoiceOver() {
        let label = MenuBarStatus.accessibilityLabel(
            state: .idle, isDictationReady: true, hasRecoveredWork: true
        )
        XCTAssertTrue(label.contains("needs attention"), "Картинка без слов для незрячего не существует: \(label)")
    }
}
