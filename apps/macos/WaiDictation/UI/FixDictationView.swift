import SwiftUI

/// Окно «поправь последнюю диктовку» — собственная поверхность обучения.
///
/// Мы не читаем чужие приложения и не следим за клавиатурой, поэтому
/// единственный честный сигнал для словаря — правка, сделанная здесь.
/// Пословный diff превращает её в замены; фильтр консервативен: учатся
/// термины, а не правки речи.
struct FixDictationView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var edited = ""
    @State private var loadedFor: AppState.LastDictation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix your last dictation")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Correct the text below — fixed terms become dictionary replacements and apply to future dictations. Ordinary wording changes are not learned.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.lastDictation == nil {
                Spacer()
                Text("Nothing to fix yet — dictate something first.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                TextEditor(text: $edited)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 120)
                    .accessibilityLabel("Dictated text to correct")
            }

            HStack {
                Spacer()
                // Escape закрывает окно: без этого единственным выходом была
                // мышь, а окно с текстовым полем притягивает клавиатуру.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Learn Corrections") {
                    let learned = state.learnCorrections(editedText: edited)
                    if learned == 0 {
                        // Ничего не выучено — говорим прямо, а не молчим.
                        state.notifyNothingLearned()
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.lastDictation == nil || edited == state.lastDictation?.insertedText)
                .prominentActionButtonStyle()
            }
        }
        .padding(20)
        .frame(width: 440, height: 300)
        .onAppear(perform: reload)
        .onChange(of: state.lastDictation) { reload() }
    }

    private func reload() {
        guard loadedFor != state.lastDictation else { return }
        loadedFor = state.lastDictation
        edited = state.lastDictation?.insertedText ?? ""
    }
}
