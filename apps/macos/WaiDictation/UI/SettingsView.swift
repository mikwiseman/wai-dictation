import DictationCore
import LocalASR
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettings(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings(state: state)
                .tabItem { Label("Model", systemImage: "waveform") }
            DictionarySettings(state: state)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            // Обновления — единственное, что приложение делает в сети без
            // прямой команды, и раньше этот выключатель лежал пятой секцией
            // «General»: в окне высотой 400 точек он оказывался ниже сгиба, и
            // человек, пришедший в настройки именно за ним, видел страницу без
            // него. Отдельная вкладка ставит его туда, где его ищут.
            UpdateSettings(updater: state.updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Основное

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @State private var showAccessibilityRepairConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $state.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                .accessibilityHint("The key you hold down while dictating")

                Text("Hold the key and speak. Double-press to dictate without holding — recording then stops on the next press.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = state.hotkeyWarning {
                    // Fn — единственная клавиша в списке, у которой есть своё
                    // системное назначение и которой может не быть на внешней
                    // клавиатуре. Молчать об этом значит оставить человека
                    // выяснять самому, почему диктовка «иногда не работает».
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
            }

            Section {
                // Автозапуск был написан и работал, но включить его было
                // негде: утилита с горячей клавишей, не пережившая
                // перезагрузку, неотличима от сломанной — клавиша просто
                // молчит, и объяснить это некому.
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                    .accessibilityHint("Starts Wai Dictation automatically when you log in")
                Text("A dictation key only works while the app is running. Without this, the key stops working after every restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sounds when recording starts and stops", isOn: $state.soundsEnabled)
                    .accessibilityHint("A short tone when recording starts and when it stops")

                // Предпросмотр в коде описан как украшение, которое можно
                // выключить, — а выключателя не было.
                Toggle("Show recognized words while you speak", isOn: $state.showLivePreview)
                    .accessibilityHint("Shows the text being recognized inside the dictation panel")
                Text("The dictation panel shows the text as it is recognized. Turn this off if you'd rather not see it on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show how long it took", isOn: $state.showSpeedReadout)
                    .accessibilityHint("Shows the time from releasing the key to the text appearing")
                Text("After each dictation the panel briefly shows the time from releasing the key to the text landing in your app. Measured, not estimated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Единственное место, где приложение читает содержимое чужого
                // окна. Выключено по умолчанию, и подпись говорит прямо что
                // именно читается — иначе выбор не осознанный.
                Toggle("Learn from your edits", isOn: $state.learnFromEdits)
                    .accessibilityHint("Reads back the field it pasted into, to learn words you fix by hand")
                Text("After pasting, Wai Dictation re-reads that one text field twice — at 8 and 25 seconds — to see whether you corrected a word, and adds the pair to your dictionary. It reads only the field it pasted into, only in that window, and nothing leaves your Mac. Off by default: this is the one thing the app reads inside another app's window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Recognition language", selection: $state.recognitionLanguage) {
                    Text("Automatic — recommended").tag(String?.none)
                    ForEach(RecognitionLanguages.options) { option in
                        Text(option.name).tag(String?.some(option.code))
                    }
                }
                .accessibilityHint("Language the engine listens for; Automatic detects it from your voice")
                Text("Automatic detects the language from your voice, including mixed phrases. Pick a specific language only when detection keeps guessing wrong — it narrows recognition to that language alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text insertion") {
                Text("Wai Dictation uses the clipboard briefly to paste, then restores the previous item byte-for-byte. Passwords, file promises, and items over 16 MB are never touched — when pasting is not safe, your text stays available from the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionRow(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "Needed to hear the hotkey and insert text.",
                    ),
                    action: performAccessibilityAction
                )
                if needsAccessibilityRepair {
                    HStack {
                        Button("Show in Finder") {
                            state.revealApplicationForAccessibility()
                        }
                        Button("Open System Settings") {
                            state.openAccessibilitySettings()
                        }
                    }
                }
                PermissionRow(
                    status: PermissionStatus(
                        title: "Microphone",
                        detail: "Needed to record your speech.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
            }
        }
        .formStyle(.grouped)
        // Разрешения выдаются в системных настройках, и вернувшийся сюда
        // человек должен увидеть свежее состояние, а не то, что было до ухода.
        .task { state.refreshPermissions() }
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
}

// MARK: - Обновления

private struct UpdateSettings: View {
    // Sparkle сообщает о своих изменениях сам, через AppState они бы не дошли.
    @ObservedObject var updater: SparkleUpdater

    var body: some View {
        Form {
            Section {
                // Переключатель гаснет вместе с механизмом обновлений. Иначе
                // получалось молчаливое враньё: рядом написано «обновления не
                // работают», человек щёлкает переключатель, текст под ним
                // обещает ежесуточную проверку — а настройка уходит в
                // незапущенный механизм и не делает ничего.
                Toggle("Check for updates automatically", isOn: $updater.automaticChecksEnabled)
                    .accessibilityHint("The only switch that changes the app's network behavior")
                    .disabled(updater.startupFailure != nil)
                Text("Off by default. When on, the app downloads a small version list from GitHub once a day. Apart from the model download and the update itself, there are no other network requests: only your IP address and the app version are sent — no details about your computer, and nothing you dictated.")
                    .font(.caption)
                    .foregroundStyle(updater.startupFailure == nil ? .secondary : .tertiary)

                HStack {
                    Button("Check now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                }
            }

            if let failure = updater.startupFailure {
                Section {
                    // Молчать нельзя: иначе человек будет считать, что
                    // обновления приходят, а они не приходят.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Updates are not working", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Updates are not working. \(failure)")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)

            Spacer()
            if let title = status.actionTitle {
                Button(title, action: action)
                    .accessibilityLabel(status.actionAccessibilityLabel ?? title)
            } else {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    // Галочка уже прочитана как значение строки: второй раз
                    // «выдан» без хозяина только мешает.
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Модель

private struct ModelSettings: View {
    @ObservedObject var state: AppState
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                ModelStatusView(
                    status: ModelStatus.make(
                        state: state.modelState,
                        isPreparingEngine: state.isPreparingEngine,
                        place: .settings,
                        downloadMegabytes: state.remainingDownloadMegabytes
                    ),
                    install: state.installModel,
                    cancel: state.cancelModelInstall,
                    // Удаление стоит рядом с обычными кнопками и раньше
                    // срабатывало с первого щелчка: промах стоил половины
                    // гигабайта и новой загрузки. Отменить это нечем, значит
                    // спрашиваем.
                    delete: { showDeleteConfirmation = true }
                )
            }

            Section {
                Text("Parakeet TDT 0.6B v3 — a local beta for Russian and English. English terms inside Russian speech are recognized by the acoustic vocabulary helper; the replacement dictionary fixes what it misses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshModelState() }
        .confirmationDialog(
            "Delete the recognition model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete model", role: .destructive) { state.deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dictation stops working until you download the model again — that's another \(state.remainingDownloadMegabytes == 0 ? 586 : state.remainingDownloadMegabytes) MB over the network.")
        }
    }
}

// MARK: - Словарь

private struct DictionarySettings: View {
    @ObservedObject var state: AppState
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Replacements apply to the recognized text. Useful for names the model hears differently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let problem = state.dictionaryProblem {
                    // Словарь заблокирован на запись. Сказать об этом обязаны
                    // здесь: человек стоит ровно на той странице, где собирается
                    // его править, и должен узнать до того, как начнёт.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Dictionary can't be edited", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                        Text(problem.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Dictionary can't be edited. \(problem.message)")
                }

                if state.isDictionaryEditable, state.availableStarterCount > 0 {
                    HStack {
                        Text("Dictating in Russian with English terms? The model writes them in Cyrillic: “pull request” becomes “пул реквест”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add \(state.availableStarterCount)") {
                            state.addStarterDictionary()
                        }
                        // Без имени это просто «добавить сорок два».
                        .accessibilityLabel("Add \(state.availableStarterCount) ready-made replacements for English terms")
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()

            // Пустой словарь — обычное дело для нового человека, и раньше он
            // видел на этом месте просто провал в пол-окна без единого слова.
            if state.replacements.isEmpty {
                VStack(spacing: 4) {
                    Text("No replacements yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Add a pair below: what the model hears on the left, what should be written on the right.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                List {
                    ForEach(state.replacements) { replacement in
                        HStack {
                            Text(replacement.spoken)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(replacement.written)
                            if replacement.noAcousticBoost {
                                Spacer(minLength: 8)
                                // Признак виден в списке, потому что иначе он
                                // необъясним: человек отметил термин, ничего не
                                // изменилось на вид, и признак забывается.
                                Text("text only")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        // Строка читается целиком: «сентри», стрелка и «Sentry»
                        // по отдельности не значат ничего.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            replacement.noAcousticBoost
                                ? "Heard as “\(replacement.spoken)”, written as “\(replacement.written)”, text only — not used to help recognition"
                                : "Heard as “\(replacement.spoken)”, written as “\(replacement.written)”"
                        )
                    }
                    .onDelete(perform: state.removeReplacements)
                }
                .disabled(!state.isDictionaryEditable)
                .accessibilityLabel("Replacement list")
            }

            Divider()

            HStack {
                // Подпись у полей только в виде подсказки внутри рамки: пустое
                // поле VoiceOver прочитает, а заполненное — уже нет, и человек
                // потеряет, в каком из двух полей он стоит.
                TextField("Heard as", text: $spoken)
                    .accessibilityLabel("Heard as")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Write as", text: $written)
                    .accessibilityLabel("Write as")
                Button("Add") {
                    state.addReplacement(spoken: spoken, written: written)
                    spoken = ""
                    written = ""
                }
                .disabled(spoken.isEmpty || written.isEmpty || !state.isDictionaryEditable)
                .accessibilityLabel("Add replacement")
                .accessibilityHint(
                    state.isDictionaryEditable
                        ? "Fill in both fields"
                        : "The dictionary can't be edited until the previous data has been read"
                )
            }
            .padding()
        }
    }
}

// MARK: - О программе

private struct AboutView: View {
    /// Версия и номер сборки. Первое, что спрашивают в любом отчёте об ошибке,
    /// и единственного места, где это можно было прочитать, в приложении не
    /// было вовсе: в Dock значка нет, «About» из главного меню недостижим.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(marketing) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wai Dictation")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Dictation that runs entirely on your Mac.")
                .foregroundStyle(.secondary)
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("What goes over the network")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("The model download you start yourself, and the update check if you turned it on. Nothing else: your speech, text, and keystrokes are never sent anywhere and never stored anywhere except your computer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Recognition models")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Parakeet TDT 0.6B v3 © NVIDIA, licensed under CC BY 4.0. Converted to Core ML and quantized with a 6-bit palette by the FluidInference project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Parakeet TDT-CTC 110M © NVIDIA, licensed under CC BY 4.0 — the acoustic vocabulary helper. Converted to Core ML by the FluidInference project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Libraries: FluidAudio (Apache 2.0), Sparkle (MIT).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
