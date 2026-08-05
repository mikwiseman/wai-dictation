import ApplicationServices
import DictationCore
import Foundation

/// Чтение поля, в которое только что вставили диктовку.
///
/// Это единственное, что приложение читает у чужих окон: значение ровно того
/// поля, куда оно само вставило текст, и ровно в окне обучения — чтобы выучить
/// правки человека. Ничего другого на экране не читается никогда.
///
/// Край системы, а не деталь: подставляется через `AppEnvironment`, как микрофон
/// и вставка. Обещание «выключено — значит поле не читается» иначе непроверяемо,
/// а именно непроверяемость и позволила ему полгода быть неверным: тумблер
/// существовал только в этом комментарии, а в настройках его не было.
@MainActor
public protocol FocusedFieldReading {
    /// Снимок сфокусированного поля. `nil` — поля нет или оно не читается.
    func captureFocusedField() -> FocusedFieldHandle?
}

/// Ручка поля: перечитывает значение, пока поле живо.
@MainActor
public final class FocusedFieldHandle {
    private let read: () -> String?

    public init(read: @escaping () -> String?) {
        self.read = read
    }

    public func value() -> String? { read() }
}

@MainActor
public struct SystemFocusedFieldReader: FocusedFieldReading {
    public init() {}

    public func captureFocusedField() -> FocusedFieldHandle? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        return FocusedFieldHandle {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &value
            )
            guard status == .success else { return nil }
            return value as? String
        }
    }
}

/// Наблюдатель правок: перечитывает поле дважды после вставки и превращает
/// правку вставленного фрагмента в сигнал обучения.
///
/// Это украшение поверх диктовки: любой сбой — поле исчезло, значение не
/// читается, фрагмент переписан целиком — просто завершает наблюдение.
/// Отсутствие обучения видно по словарю; ломать диктовку из-за него нельзя.
@MainActor
final class EditLearningWatcher {
    private let reader: any FocusedFieldReading
    private let checkDelays: [Duration]
    private var watch: Task<Void, Never>?

    init(
        reader: any FocusedFieldReading = SystemFocusedFieldReader(),
        checkDelays: [Duration] = [.seconds(8), .seconds(25)]
    ) {
        self.reader = reader
        self.checkDelays = checkDelays
    }

    /// Начать наблюдение за только что вставленным текстом.
    ///
    /// Новая вставка отменяет прежнее наблюдение: учить можно только то, что
    /// человек правит прямо сейчас.
    func beginWatching(
        inserted: String,
        onEdit: @escaping @MainActor (_ original: String, _ edited: String) -> Void
    ) {
        cancel()
        guard let field = reader.captureFocusedField() else { return }
        guard let baseline = field.value(), baseline.contains(inserted) else { return }

        watch = Task { @MainActor [checkDelays] in
            for delay in checkDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                guard let current = field.value() else { return }
                if let edit = InsertedEditExtractor.extract(
                    baseline: baseline,
                    current: current,
                    inserted: inserted
                ) {
                    onEdit(edit.original, edit.edited)
                    return
                }
            }
        }
    }

    func cancel() {
        watch?.cancel()
        watch = nil
    }
}
