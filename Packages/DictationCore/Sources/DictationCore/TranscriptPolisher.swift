import Foundation

/// Детерминированная доводка распознанного текста.
///
/// Никаких языковых моделей: только то, что можно проверить и предсказать.
/// Правки здесь не меняют смысл — они убирают следы того, что текст пришёл из
/// распознавания, а не был набран руками.
///
/// Осознанно НЕ делаем: не разворачиваем числительные («двадцать пять» → «25»)
/// — в русском это упирается в склонения и падежи и ломает больше, чем чинит.
public enum TranscriptPolisher {
    /// Привести распознанный текст в вид, пригодный для вставки.
    ///
    /// Защищённые спаны (`ProtectedSpan`) не трогаются ни одной операцией.
    /// Спаны пересчитываются перед каждым шагом, а не считаются один раз:
    /// предыдущий шаг мог сдвинуть офсеты, и «уплывший» диапазон — ровно тот
    /// класс ошибки, из-за которого такие системы и гниют. Детекция чистая и
    /// идемпотентная, так что пересчёт ничего не стоит и ничего не меняет.
    public static func polish(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = collapseWhitespace(in: result, protecting: spans(of: result))
        result = fixSpacingAroundPunctuation(in: result, protecting: spans(of: result))
        result = capitalizeFirstLetter(of: result, protecting: spans(of: result))
        return result
    }

    private static func spans(of text: String) -> [ProtectedSpan] {
        ProtectedSpanDetector.detect(in: text)
    }

    /// Схлопнуть повторяющиеся пробелы, сохранив переводы строк.
    static func collapseWhitespace(in text: String) -> String {
        collapseWhitespace(in: text, protecting: [])
    }

    /// То же, но пробелы внутри защищённого куска остаются как есть: в
    /// бэктиках лежит код, и выравнивание в нём значащее.
    static func collapseWhitespace(in text: String, protecting spans: [ProtectedSpan]) -> String {
        guard !spans.isEmpty else {
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                }
                .joined(separator: "\n")
        }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)
        var spanIndex = 0
        var index = 0

        while index < characters.count {
            while spanIndex < spans.count, spans[spanIndex].range.upperBound <= index {
                spanIndex += 1
            }
            if spanIndex < spans.count, spans[spanIndex].range.contains(index) {
                let span = spans[spanIndex]
                result.append(contentsOf: characters[span.range])
                index = span.range.upperBound
                continue
            }

            let character = characters[index]
            if character == " " || character == "\t" {
                // Пробел перед защищённым куском тоже схлопывается — он не его.
                if result.last != " ", result.last != "\n" { result.append(" ") }
                index += 1
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// Убрать пробел перед знаком препинания и поставить после него там,
    /// где его точно не хватает.
    ///
    /// Вставка пробела намеренно осторожная. Модель сама превращает
    /// «три и четырнадцать сотых» в «3.14», а точка встречается в версиях
    /// («2.0.1»), доменах («wai.computer») и сокращениях («т.д.»); двоеточие —
    /// в ссылках («https://») и времени («12:30»). Раньше пробел ставился после
    /// любой точки, и всё перечисленное разваливалось — проверено на настоящем
    /// выходе модели.
    ///
    /// Поэтому у точки и двоеточия условие осталось прежним: пробел ставится
    /// только перед заглавной буквой, то есть когда началось новое предложение.
    ///
    /// Гвардия «пробел только перед заглавной» остаётся и после появления
    /// спанов: она и модель спанов фильтруют по разным осям. Гвардия смотрит,
    /// что стоит ПОСЛЕ знака (этим и защищены `3.14`, `wai.computer`, `т.д.`,
    /// `https://`, `12:30` — там дальше строчная или цифра), спан смотрит, ЧЕМ
    /// является токен. Убрать гвардию, раз есть спаны, — соблазнительная
    /// ошибка: числа, домены и сокращения спанами не становятся и защиты
    /// лишатся. Спаны чинят единственный дефект гвардии — `TextPipeline.Output`.
    static func fixSpacingAroundPunctuation(in text: String) -> String {
        fixSpacingAroundPunctuation(in: text, protecting: [])
    }

    static func fixSpacingAroundPunctuation(
        in text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        let closing: Set<Character> = [",", ".", "!", "?", ";", ":", "…"]

        /// Знаки, после которых пробел нужен всегда, если дальше буква.
        ///
        /// «первое,второе» модель отдаёт постоянно, и заглавной там не бывает —
        /// с условием «только перед заглавной» перечисление оставалось
        /// слипшимся. У этих знаков нет ни одного написания, где буква стоит
        /// вплотную по делу: единственное такое место у запятой — десятичная
        /// дробь, а там дальше идёт цифра, и правило её не трогает.
        let alwaysSeparating: Set<Character> = [",", "!", "?", ";", "…"]

        var result = ""
        result.reserveCapacity(text.count)

        let characters = Array(text)
        var spanIndex = 0
        var index = 0
        while index < characters.count {
            // Защищённый кусок переносится дословно: именно здесь `Foo.Bar`
            // перестаёт превращаться в `Foo. Bar`.
            while spanIndex < spans.count, spans[spanIndex].range.upperBound <= index {
                spanIndex += 1
            }
            if spanIndex < spans.count, spans[spanIndex].range.contains(index) {
                let span = spans[spanIndex]
                result.append(contentsOf: characters[span.range])
                index = span.range.upperBound
                continue
            }

            let character = characters[index]

            if closing.contains(character) {
                // Пробел перед знаком препинания — артефакт распознавания.
                while result.last == " " { result.removeLast() }
                result.append(character)

                if let next = index + 1 < characters.count ? characters[index + 1] : nil,
                   next.isUppercase || (alwaysSeparating.contains(character) && next.isLetter) {
                    result.append(" ")
                }
                index += 1
                continue
            }

            result.append(character)
            index += 1
        }
        return result
    }

    /// Заглавная первая буква — распознавание нередко отдаёт строчную.
    static func capitalizeFirstLetter(of text: String) -> String {
        capitalizeFirstLetter(of: text, protecting: [])
    }

    /// Идентификатор в начале диктовки заглавной не получает: продиктованный
    /// первым словом `onTextInserted` — это имя, а не начало предложения, и
    /// `OnTextInserted` было бы просто другим именем.
    static func capitalizeFirstLetter(
        of text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        guard !spans.contains(where: { $0.range.contains(0) }) else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
