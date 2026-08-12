import AppKit
import DictationCore
import SwiftUI

/// Меню в строке меню — весь интерфейс приложения в покое.
///
/// Лежит отдельно от точки входа намеренно: `WaiDictationApp.swift` не
/// компилируется в тестовую цель (там `@main`), а всё, что человек здесь видит,
/// проверяться должно.
struct MenuContent: View {
    @ObservedObject var state: AppState
    let showOnboarding: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(
            MenuBarStatus.statusLine(
                state: state.dictationState,
                isDictationReady: state.isDictationReady,
                isHandsFreeActive: state.isHandsFreeActive,
                hotkeyTitle: state.hotkey.title,
                hasRecoveredText: state.recoveredText != nil,
                hasRecoveredRecording: state.recoveredRecording != nil
            )
        )

        if state.dictationState == .preparing || state.dictationState == .listening {
            Divider()
            Button("Stop and Insert") { state.finishCurrentDictation() }
            Button("Cancel Dictation", role: .destructive) {
                state.cancelCurrentDictation()
            }
        }

        if !state.isDictationReady {
            Divider()
            setupHints
            Button("Run Setup Again…") {
                showOnboarding()
                openWindow(id: "onboarding")
            }
        }

        // Спасённое — без заголовков-секций: первая строка меню уже назвала
        // беду, а пункты называют себя сами. Заголовок поверх трёх кнопок
        // перегружал меню и читался как ещё одна ошибка.
        if state.recoveredText != nil {
            Divider()
            Button("Insert Last Dictation") { state.retryRecoveredText() }
            Button("Copy Last Dictation") { state.copyRecoveredText() }
            Button("Delete Saved Text", role: .destructive) {
                state.deleteRecoveredText()
            }
        }

        if state.recoveredRecording != nil {
            Divider()
            Button("Transcribe Saved Recording") { state.retryRecoveredRecording() }
                .disabled(!state.modelState.isReady || state.dictationState != .idle)
            Button("Delete Saved Recording", role: .destructive) {
                state.deleteRecoveredRecording()
            }
        }

        // Правка последней диктовки. Пункт появляется только после успешной
        // вставки: до неё окно всё равно показало бы «править нечего».
        //
        // Без этого пункта окно «Fix Last Dictation» не открывалось ниоткуда:
        // сцена в приложении была, а входа в неё не было — в строке меню его
        // нет, а главное меню у LSUIElement-приложения показывается, только
        // когда открыто хоть одно окно. Целая функция была недостижима.
        if state.lastDictation != nil {
            Divider()
            Button("Fix Last Dictation…") {
                openWindow(id: "fix-dictation")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Button("Quit Wai Dictation") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var setupHints: some View {
        if !state.accessibilityGranted {
            switch state.accessibilityState {
            case .denied:
                Button("Grant Accessibility Access") { state.requestAccessibility() }
            case .waitingForSettings:
                Button("Open Accessibility Settings") { state.openAccessibilitySettings() }
            case .restartRequired:
                Button("Relaunch to Apply Access") { state.restartForAccessibility() }
            case .repairRequired, .failed:
                Text("Accessibility access needs repair")
            case .repairing:
                Text("Repairing Accessibility access…")
            case .granted:
                EmptyView()
            }
        }
        if !state.microphoneGranted {
            Button("Allow Microphone") { state.requestMicrophone() }
        }
        // Через тот же тип, что и оба экрана. Раньше меню знало про модель один
        // булев «готова или нет» и предлагало «Скачать» даже посреди загрузки —
        // нажатие уходило в никуда, а первая строка меню при этом говорила
        // «Нужна настройка», ни словом не упоминая, что загрузка идёт.
        // Объём передаётся, а не берётся по умолчанию. Без него кнопка в меню
        // всегда обещала 586 МБ — полную установку, — даже когда докачать надо
        // один подсказчик на ~103 МБ. По этой цифре решают, жать ли на дорогой
        // или медленной сети, и ошибаться в ней в пять раз нельзя.
        let model = ModelStatus.make(
            state: state.modelState,
            isPreparingEngine: state.isPreparingEngine,
            place: .settings,
            downloadMegabytes: state.remainingDownloadMegabytes
        )
        if state.modelState.isReady, !state.isEngineReady {
            Text("Preparing the model for dictation…")
        } else if !state.modelState.isReady {
            Text(model.progressLabel.map { "\(model.title) — \($0)" } ?? model.title)

            ForEach(model.actions.filter { $0 != .delete }, id: \.self) { action in
                Button(model.title(for: action)) {
                    switch action {
                    case .install, .retry, .repair: state.installModel()
                    case .cancel: state.cancelModelInstall()
                    case .delete: break
                    }
                }
            }
        }
    }
}
