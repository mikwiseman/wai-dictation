import Foundation

/// Что показывать, пока движок готовится к первой диктовке.
///
/// Первый запуск после установки молчал 12–15 секунд: macOS компилирует модель
/// под Neural Engine, и всё это время человек не понимал, сломалось ли что-то.
///
/// **Процентов здесь нет и не будет.** Сигнала прогресса компиляции ANE не
/// существует — ни у системы, ни у библиотеки. Нарисованная полоска была бы
/// выдумкой, а выдуманный прогресс хуже честного молчания: он обещает срок,
/// которого никто не знает. Показываем прошедшие секунды и объясняем причину.
///
/// Отказ движка сюда не входит намеренно: у него уже есть владелец —
/// `ModelStatus.repairRequired`. Второй тип про то же самое был бы дублем,
/// который рано или поздно разойдётся с первым.
struct EnginePreparationState: Equatable {
    enum Phase: Equatable {
        case idle
        case loadingRecognizer
        case loadingVocabulary
        case ready
    }

    let phase: Phase
    let elapsed: TimeInterval
    let title: String
    let detail: String?

    static func make(phase: Phase, elapsed: TimeInterval) -> EnginePreparationState {
        let seconds = Int(elapsed.rounded())
        switch phase {
        case .idle:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Model not prepared",
                detail: nil
            )
        case .loadingRecognizer:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Preparing the recognizer… \(seconds) s",
                // Формулировка верна и на холодном, и на тёплом старте, поэтому
                // ветки не нужны и обещание нельзя нарушить.
                detail: "macOS is compiling the model for the Neural Engine. Up to about "
                    + "20 seconds the first time after install, a fraction of a second "
                    + "afterwards. There is no progress to show — the seconds are real."
            )
        case .loadingVocabulary:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Preparing the term booster… \(seconds) s",
                detail: "A second, smaller model. Same one-time compile."
            )
        case .ready:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Ready to dictate",
                detail: nil
            )
        }
    }
}
