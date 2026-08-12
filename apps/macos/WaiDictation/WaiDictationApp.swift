import AppKit
import DictationCore
import SwiftUI

@main
struct WaiDictationApp: App {
    @StateObject private var state = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Приложение живёт в строке меню: у диктовки нет своего окна, она
        // работает поверх того, где сейчас пользователь.
        MenuBarExtra {
            MenuContent(
                state: state,
                showOnboarding: { onboardingCompleted = false }
            )
        } label: {
            Image(
                systemName: MenuBarStatus.iconName(
                    state: state.dictationState,
                    isDictationReady: state.isDictationReady,
                    hasRecoveredWork: state.recoveredText != nil
                        || state.recoveredRecording != nil
                )
            )
            // Значок — единственное постоянное присутствие приложения на
            // экране. Без ярлыка VoiceOver читает имя системного символа.
            .accessibilityLabel(
                MenuBarStatus.accessibilityLabel(
                    state: state.dictationState,
                    isDictationReady: state.isDictationReady,
                    hasRecoveredWork: state.recoveredText != nil
                        || state.recoveredRecording != nil
                )
            )
            .task {
                // Первый запуск обязан сам показать настройку. Без этого
                // приложение молча уходит в строку меню: значка в доке нет,
                // окна нет, и человек, только что перетащивший его из
                // образа, не видит вообще ничего — ни разрешений, ни модели,
                // без которых диктовка не работает.
                guard !onboardingCompleted else { return }
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Содержимое здесь безусловное. Пока оно пряталось за
        // `if !onboardingCompleted`, macOS оставляла у себя саму сцену: после
        // настройки в меню «Window» жил пункт «Welcome», и он открывал окно
        // размером 0×0 — рамку без содержимого, из которой нечего закрыть и
        // непонятно, что это было. Теперь тот же пункт честно показывает
        // настройку заново, ровно как «Run setup again» в строке меню.
        Window("Welcome", id: "onboarding") {
            OnboardingView(state: state) { onboardingCompleted = true }
        }
        .windowResizability(.contentSize)
        // Без полосы заголовка: у мастера первого запуска нет ни документа,
        // ни имени, которое стоило бы показывать, — только содержимое.
        .windowStyle(.hiddenTitleBar)

        Window("Fix Last Dictation", id: "fix-dictation") {
            FixDictationView(state: state)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(state: state)
        }
    }
}
