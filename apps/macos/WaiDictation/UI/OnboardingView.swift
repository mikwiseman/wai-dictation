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
    /// Куда шёл последний переход: вперёд уезжает влево, назад — вправо.
    /// Симметрия путей — то, что делает мастер предсказуемым: шаг возвращается
    /// той же дорогой, которой ушёл.
    @State private var movingForward = true
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
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 20)
                // Каждый шаг — отдельная страница: вперёд она уезжает влево,
                // назад — вправо, теми же путями в обе стороны. При
                // «Уменьшить движение» — мгновенная смена без езды.
                .id(step)
                .transition(
                    reduceMotion
                        ? .identity
                        : .push(from: movingForward ? .trailing : .leading)
                )

            footer
        }
        .frame(width: 520, height: 560)
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

    // MARK: - Подвал

    /// Назад · точки прогресса · Дальше — и причина, если «Дальше» погашена.
    private var footer: some View {
        VStack(spacing: 8) {
            Divider()

            ZStack {
                // Точки прижаты к центру окна, а не к соседним кнопкам: без
                // ZStack исчезновение «Back» на первом шаге сдвигало бы их.
                OnboardingProgressDots(step: step)

                HStack {
                    if step.hasPrevious {
                        Button("Back") { back() }
                            .accessibilityHint("Go back to step \(step.rawValue)")
                    }
                    Spacer()
                    nextButton
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)

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
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Шаги

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            // Герб продукта. Обычный системный символ в цветном круге — как у
            // ассистентов настройки самой macOS; стекла здесь нет намеренно:
            // Liquid Glass — слой управления, а не украшение содержимого.
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 76, height: 76)
                heroGlyph
            }
            .accessibilityHidden(true)

            Text("Dictation that stays on your Mac")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("Press a key, speak, release — the text appears at your cursor. In any app.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 12) {
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

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingStepHeader(
                symbol: "lock.shield",
                title: "Two permissions",
                subtitle: "Both are granted in System Settings. We'll show you exactly where."
            )

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

    /// Микрофон на гербе дышит — едва заметно, как приглашение заговорить.
    /// «Уменьшить движение» и macOS 14 получают спокойный статичный символ.
    @ViewBuilder
    private var heroGlyph: some View {
        let glyph = Image(systemName: "mic.fill")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.white)
        if #available(macOS 15.0, *), !reduceMotion {
            glyph.symbolEffect(.breathe, options: .repeat(.continuous))
        } else {
            glyph
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
            OnboardingStepHeader(
                symbol: "arrow.down.circle",
                title: "Recognition model",
                subtitle: "One download — after it, recognition works without the network."
            )

            ModelStatusView(
                status: ModelStatus.make(
                    state: state.modelState,
                    isPreparingEngine: state.isPreparingEngine,
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
            OnboardingStepHeader(
                symbol: "mic",
                title: "Try it",
                subtitle: "Hold \(state.hotkey.title), say something, and release. The text will appear in the field below."
            )

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

            // Поле для пробы. Настоящее, с изменяемым текстом: раньше оно было
            // привязано к константе, и продиктованное в нём не появлялось
            // никогда — первая же попытка выглядела так, будто ничего не
            // работает. Курсор ставится сюда сам, иначе текст уйдёт в то окно,
            // которое было впереди до онбординга.
            TextEditor(text: $trial)
                .frame(height: 96)
                .focused($trialFocused)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .onAppear { trialFocused = true }
                .accessibilityLabel("Trial dictation field")

            // Цвет — точке, а не словам: красный текст читается как ошибка,
            // а здесь всё идёт как задумано.
            if state.dictationState == .listening {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Listening…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
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
        // Кнопка по умолчанию: Return ведёт мастер вперёд. Раньше главное
        // действие всей установки было недоступно с клавиатуры — Return не
        // делал ничего, и пройти четыре шага без мыши было нельзя. На последнем
        // шаге фокус стоит в поле пробы, и Return достаётся полю, а не кнопке.
        .keyboardShortcut(.defaultAction)
        .disabled(blockReason != nil)
        .accessibilityHint(blockReason ?? "")
        .prominentActionButtonStyle()
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
        movingForward = true
        withAnimation(stepTransition) { step = next }
    }

    private func back() {
        guard let previous = step.previous else { return }
        movingForward = false
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

/// Заголовок шага: символ, название, пояснение — один рисунок на все шаги.
private struct OnboardingStepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Точки прогресса. Текущий шаг — вытянутая капсула, как в ассистентах macOS.
///
/// Для VoiceOver это один элемент со словами «Step 2 of 4»: отдельные точки
/// на слух не значат ничего.
private struct OnboardingProgressDots: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { candidate in
                Capsule()
                    .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: candidate == step ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.progressAccessibilityLabel)
        .help(step.progressText)
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
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
