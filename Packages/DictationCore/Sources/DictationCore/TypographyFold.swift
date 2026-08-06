import Foundation

/// Свёртка типографики к тому написанию, которое человек набрал бы руками.
///
/// Зачем стадия нужна уже сейчас, до всякой языковой модели:
///
/// 1. Приложения со «умной» подстановкой (Notion, Pages, Почта) переписывают в
///    поле прямые кавычки в парные, а дефис в тире. `InsertedEditExtractor`
///    сравнивает вставленное с перечитанным, и после такой подстановки
///    сравнение перестаёт сходиться — обучение на правках молча умирает.
/// 2. Невидимые символы приезжают через словарь: `written` человек вставляет
///    копипастом, а неразрывный пробел, BOM и мягкий перенос в настройках
///    не видно вообще.
/// 3. Похожие символы ломают саму модель спанов: `U+2212` MINUS перед буквой
///    делает `−x` не-флагом.
///
/// Таблица закрыта и мала намеренно. Всё, что несёт смысл, остаётся: ёлочки —
/// правильная русская типографика, тире отличается от дефиса по делу,
/// многоточием владеет `TranscriptPolisher`.
enum TypographyFold {
    /// Ровно двенадцать символов. Пустая строка — «удалить».
    static let table: [Character: String] = [
        // Невидимые пробелы → обычный пробел.
        "\u{00A0}": " ",   // NO-BREAK SPACE
        "\u{202F}": " ",   // NARROW NO-BREAK SPACE
        "\u{2009}": " ",   // THIN SPACE
        // Невидимые вовсе → удалить.
        "\u{200B}": "",    // ZERO WIDTH SPACE
        "\u{FEFF}": "",    // ZERO WIDTH NO-BREAK SPACE / BOM
        "\u{00AD}": "",    // SOFT HYPHEN
        // Парные кавычки → прямые.
        "\u{2018}": "'",   // LEFT SINGLE QUOTATION MARK
        "\u{2019}": "'",   // RIGHT SINGLE QUOTATION MARK
        "\u{201C}": "\"",  // LEFT DOUBLE QUOTATION MARK
        "\u{201D}": "\"",  // RIGHT DOUBLE QUOTATION MARK
        // Похожие на дефис и тире → канонические.
        "\u{2212}": "-",   // MINUS SIGN
        "\u{2015}": "—",   // HORIZONTAL BAR → EM DASH
    ]

    static func fold(_ text: String) -> String {
        fold(text, protecting: [])
    }

    /// Свернуть всё, кроме защищённых кусков.
    ///
    /// Внутри бэктиков лежит код: там кавычка значащая, и подмена её сломала бы.
    static func fold(_ text: String, protecting spans: [ProtectedSpan]) -> String {
        guard !text.isEmpty else { return text }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)

        var spanIndex = 0
        var index = 0
        while index < characters.count {
            // Спаны отсортированы и не пересекаются — хватает одного курсора.
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
            if let replacement = table[character] {
                result.append(replacement)
            } else {
                result.append(character)
            }
            index += 1
        }

        return result
    }
}
