import Foundation

/// Происхождение последней диктовки: чем текст был и чем стал.
///
/// Нужно двум вещам: «скопировать дословно» — чтобы сказанное было доступно даже
/// после того, как словарь и полишер над ним поработали, — и диагностике,
/// которая отделяет «словарь не сработал» от «сработал, а косметика сдвинула».
///
/// **Намеренно не `Codable`.** Это не забывчивость, а сама гарантия «никогда на
/// диск»: чтобы записать такую структуру в файл, придётся сначала осознанно
/// добавить конформанс, и рядом лежит тест, который на это падает.
///
/// `description` отдаёт только имена полей и счётчики символов — ни одна
/// случайная интерполяция в лог не вынесет продиктованный текст наружу.
public struct PipelineProvenance: Sendable, Equatable, CustomStringConvertible {
    /// Ровно то, что вернуло распознавание, до всех стадий.
    public let raw: String
    /// Состояние после словаря целиком и до любой косметики.
    public let afterDictionary: String
    /// То, что будет вставлено.
    public let finalText: String
    /// Защищённые спаны финального текста.
    ///
    /// Лежат здесь, потому что обучение на правках обязано их обходить, а
    /// другого честного источника у него нет: оно видит только вставленный текст.
    public let spans: [ProtectedSpan]

    public init(raw: String, afterDictionary: String, finalText: String, spans: [ProtectedSpan]) {
        self.raw = raw
        self.afterDictionary = afterDictionary
        self.finalText = finalText
        self.spans = spans
    }

    public var description: String {
        "PipelineProvenance(raw: \(raw.count) симв., afterDictionary: \(afterDictionary.count) симв., "
            + "final: \(finalText.count) симв., спанов: \(spans.count))"
    }
}
