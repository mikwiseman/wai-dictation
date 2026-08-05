import Foundation

/// Выделение правки вставленного фрагмента из содержимого чужого поля.
///
/// Дано: каким поле было сразу после вставки, где в нём наш фрагмент и каким
/// поле стало позже. Общие префикс и суффикс двух состояний отрезаются; если
/// всё изменившееся лежит внутри нашего фрагмента — это правка диктовки.
/// Правки чужого текста и дописанное после вставки не касаются нас по
/// построению: их изменённая середина выходит за границы фрагмента.
public enum InsertedEditExtractor {
    public struct Edit: Equatable {
        /// Фрагмент, каким он был вставлен.
        public let original: String
        /// Фрагмент после правки человека.
        public let edited: String
    }

    public static func extract(
        baseline: String,
        current: String,
        inserted: String
    ) -> Edit? {
        guard baseline != current, !inserted.isEmpty else { return nil }
        // Фрагмент ищется с конца: вставка была последней операцией, и при
        // повторе текста в поле наш экземпляр — ближайший к хвосту.
        guard let insertedRange = baseline.range(of: inserted, options: .backwards) else {
            return nil
        }

        let baselineChars = Array(baseline)
        let currentChars = Array(current)

        var prefix = 0
        while prefix < baselineChars.count, prefix < currentChars.count,
              baselineChars[prefix] == currentChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < baselineChars.count - prefix, suffix < currentChars.count - prefix,
              baselineChars[baselineChars.count - 1 - suffix]
                  == currentChars[currentChars.count - 1 - suffix] {
            suffix += 1
        }

        // Изменённая середина baseline в индексах символов.
        let changedStart = prefix
        let changedEnd = baselineChars.count - suffix
        let insertedStart = baseline.distance(from: baseline.startIndex, to: insertedRange.lowerBound)
        let insertedEnd = baseline.distance(from: baseline.startIndex, to: insertedRange.upperBound)

        // Правка обязана целиком лежать внутри вставленного фрагмента.
        guard changedStart >= insertedStart, changedEnd <= insertedEnd else { return nil }
        if changedStart == changedEnd {
            // В baseline ничего не удалено — человек только ДОБАВИЛ текст.
            // Добавление на границе фрагмента — это дописывание своего, а не
            // правка нашего: правкой считается только вставка строго внутри.
            guard changedStart > insertedStart, changedStart < insertedEnd else { return nil }
        }

        // Фрагмент после правки: его длина изменилась на разницу длин полей.
        let delta = currentChars.count - baselineChars.count
        let editedStart = insertedStart
        let editedEnd = insertedEnd + delta
        guard editedStart >= 0, editedEnd <= currentChars.count, editedStart <= editedEnd else {
            return nil
        }

        let edited = String(currentChars[editedStart..<editedEnd])
        guard !edited.isEmpty else { return nil }
        return Edit(original: inserted, edited: edited)
    }
}
