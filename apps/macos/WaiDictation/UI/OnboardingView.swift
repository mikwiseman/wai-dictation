import DictationCore
import LocalASR
import SwiftUI

/// Первый запуск: от установки до первой продиктованной фразы.
///
/// Порядок шагов выбран так, чтобы загрузка модели шла фоном, пока человек
/// читает и выдаёт разрешения — иначе он просто смотрел бы на индикатор.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// «Уменьшить движение» в универсальном доступе. Переход между шагами —
    /// украшение, и человеку, который его отключил, оно доставаться не должно.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep = .welcome
    /// Что человек продиктовал на пробу.
    @State private var trial = ""
    /// Вручную напечатанный текст не считается пробой: ждём именно успешную
    /// вставку, случившуюся после входа на последний шаг.
    @State private var trialStartCount = 0
    @State private var showAccessibilityRepairConfirmation = false
    @FocusState private var trialFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Выравнивание задаётся явно. Без него шаг, у которого нет ни одного
            // тянущегося вширь элемента (например «Recognition model», когда
            // модель уже готова и индикатора загрузки нет), сжимался до ширины
            // своего текста и уезжал в центр окна — а соседние шаги при этом
            // стояли по левому краю. Один и тот же мастер выглядел собранным из
            // двух разных.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(32)

            Divider()

            VStack(spacing: 6) {
                HStack {
                    if step.hasPrevious {
                        Button("Back") { back() }
                            .accessibilityHint("Go back to step \(step.rawValue)")
                    }
                    Spacer()
                    Text(step.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(step.progressAccessibilityLabel)
                    Spacer()
                    nextButton
                }

                // Почему кнопка погашена. Без этой строки человек видит мёртвую
                // «Дальше» и не знает, чего от него ждут, — а для незрячего
                // установка на этом просто заканчивается.
                //
                // Строка есть всегда, даже пустая: иначе её появление сдвигало
                // подвал вместе с кнопками вверх, а область содержимого — вниз.
                // Шаг, где разрешение только что выдали, дёргался целиком.
                Text(blockReason ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(blockReason == nil)
            }
            .padding()
        }
        .frame(width: 560, height: 420)
        .confirmationDialog(
            "Repair Accessibility access?",
            isPresented: $showAccessibilityRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Wai Dictation's access and relaunch", role: .destructive) {
                state.repairAccessibility()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will remove only Wai Dictation's Accessibility entries. After the relaunch you will need to grant access again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .model: model
        case .tryIt: tryIt
        }
    }

    // MARK: - Шаги

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictation that never sends your speech anywhere")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Press a key, speak, release — the text appears where your cursor was. In any app.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                OnboardingPoint(
                    symbol: "airplane",
                    text: "Speech is recognized by a model on your disk. Works on a plane."
                )
                OnboardingPoint(
                    symbol: "arrow.down.circle",
                    text: "The app goes online only on your command: to download the model and, if you turn it on, to check for updates."
                )
                OnboardingPoint(
                    // Открытый замок читается как «незащищено» — ровно наоборот.
                    symbol: "eye.slash",
                    text: "No accounts, no analytics, no reports. The code is open — you can check."
                )
            }
            .font(.callout)

            Spacer()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two permissions")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Both are granted in System Settings. We'll show you exactly where.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                OnboardingPermission(
                    status: PermissionStatus(
                        title: "Microphone",
                        detail: "To hear your speech.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
                OnboardingPermission(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "To hear the hotkey and insert the finished text.",
                    ),
                    action: performAccessibilityAction
                )
            }

            if needsAccessibilityRepair {
                HStack {
                    Button("Show the app in Finder") {
                        state.revealApplicationForAccessibility()
                    }
                    Button("Open System Settings") {
                        state.openAccessibilitySettings()
                    }
                }
                .font(.caption)
            }

            Text("A separate “Input Monitoring” permission is not needed. The app doesn't store or transmit keystrokes — it only looks for your hotkey.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var needsAccessibilityRepair: Bool {
        switch state.accessibilityState {
        case .repairRequired, .failed:
            true
        default:
            false
        }
    }

    private func performAccessibilityAction() {
        switch state.accessibilityState {
        case .denied:
            state.requestAccessibility()
        case .waitingForSettings:
            state.openAccessibilitySettings()
        case .restartRequired:
            state.restartForAccessibility()
        case .repairRequired, .failed:
            showAccessibilityRepairConfirmation = true
        case .repairing, .granted:
            break
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recognition model")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            ModelStatusView(
                status: ModelStatus.make(
                    state: state.modelState,
                    isPreparingEngine: state.isPreparingEngine,
                    preparation: state.enginePreparation,
                    place: .onboarding,
                    downloadMegabytes: state.remainingDownloadMegabytes
                ),
                install: state.installModel,
                cancel: state.cancelModelInstall,
                delete: state.deleteModel
            )

            Spacer()
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Picker("Dictation key", selection: $state.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("The key you hold down while dictating")

            if let warning = state.hotkeyWarning {
                Label {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Key warning. \(warning)")
            }

            Text("Hold \(state.hotkey.title), say something, and release. The text will appear in the field below.")
                .foregroundStyle(.secondary)

            // Поле для пробы. Настоящее, с изменяемым текстом: раньше оно было
            // привязано к константе, и продиктованное в нём не появлялось
            // никогда — первая же попытка выглядела так, будто ничего не
            // работает. Курсор ставится сюда сам, иначе текст уйдёт в то окно,
            // которое было впереди до онбординга.
            TextEditor(text: $trial)
                .frame(height: 90)
                .focused($trialFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onAppear { trialFocused = true }
                .accessibilityLabel("Trial dictation field")

            if state.dictationState == .listening {
                Label("Listening…", systemImage: "waveform")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording")
            }

            if trialSucceeded {
                Label("Done — dictation works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Skip the try-out") { finishOnboarding() }
                    .buttonStyle(.link)
            }

            Spacer()
        }
    }

    // MARK: - Навигация

    private var nextButton: some View {
        Button(step.nextButtonTitle) {
            if step.isLast {
                finishOnboarding()
            } else {
                forward()
            }
        }
        .buttonStyle(.borderedProminent)
        // Кнопка по умолчанию: Return ведёт мастер вперёд. Раньше главное
        // действие всей установки было недоступно с клавиатуры — Return не
        // делал ничего, и пройти четыре шага без мыши было нельзя. На последнем
        // шаге фокус стоит в поле пробы, и Return достаётся полю, а не кнопке.
        .keyboardShortcut(.defaultAction)
        .disabled(blockReason != nil)
        .accessibilityHint(blockReason ?? "")
    }

    private var blockReason: String? {
        OnboardingGate.blockReason(
            step: step,
            microphoneGranted: state.microphoneGranted,
            accessibilityGranted: state.accessibilityGranted,
            modelState: state.modelState,
            engineReady: state.isEngineReady,
            trialSucceeded: trialSucceeded
        )
    }

    private var trialSucceeded: Bool {
        state.successfulDictationCount > trialStartCount
            && !trial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func forward() {
        guard let next = step.next else { return }
        if next == .tryIt { trialStartCount = state.successfulDictationCount }
        withAnimation(stepTransition) { step = next }
    }

    private func back() {
        guard let previous = step.previous else { return }
        withAnimation(stepTransition) { step = previous }
    }

    /// `nil` — переход без анимации, мгновенной сменой содержимого.
    private var stepTransition: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    private func finishOnboarding() {
        onFinish()
        // Окно закрывается здесь же. Иначе на экране оставалась бы пустая
        // рамка после завершения настройки.
        dismiss()
    }
}

/// Пункт списка ценностей на первом шаге.
///
/// Значок стоит в колонке фиксированной ширины. Иначе ширину колонки задаёт сам
/// глиф, а у `eye.slash` он шире, чем у `airplane`: текст третьего пункта
/// начинался на несколько точек правее двух первых, и левый край списка выходил
/// рваным.
private struct OnboardingPoint: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .frame(width: 20, alignment: .center)
        }
    }
}

private struct OnboardingPermission: View {
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: status.granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status.granted ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Название, пояснение и галочка — про одно и то же. По отдельности
            // VoiceOver читает их тремя элементами, и «выдано» повисает без
            // хозяина.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)

            Spacer()

            if let title = status.actionTitle {
                Button(title, action: action)
                    .accessibilityLabel(status.actionAccessibilityLabel ?? title)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
