import Foundation

/// Обучение словаря по правке последней диктовки.
///
/// Поверхность правки — собственное окно приложения: мы не читаем чужие
/// приложения и не следим за клавиатурой, поэтому единственный честный сигнал —
/// текст, который человек поправил у нас сам. Пословный diff превращает правку
/// в кандидатов на замену.
///
/// Фильтр консервативен намеренно. Учится только пара, у которой правая сторона
/// несёт **сигнал термина**: смену письменности («поуст герз» → «Postgres») или
/// бренд-регистр («github» → «GitHub»). Всё остальное — скорее правка речи
/// («быстро» → «быстрее», «the file» → «a file»), и выучить её значило бы молча
/// подменять слова человека в следующих диктовках.
public enum CorrectionLearning {
    /// Сколько замен может выйти из одной правки.
    ///
    /// Правка диктовки — это несколько терминов. Когда пар больше, перед нами
    /// не правка, а другой текст: вставленный перевод, переписанный абзац. Из
    /// такого нельзя учить ничего — не потому, что часть пар плоха, а потому,
    /// что установить разом десятки молчаливых правил будущих диктовок
    /// необратимо, а сказать «учить нечего» и попросить поправить термины
    /// меньшими порциями — нет. Замер: правка-подмена на 200 слов давала
    /// 200 замен разом.
    static let maximumProposalsPerCorrection = 5

    /// Предложить замены по правке. Ничего не сохраняет — только предлагает.
    ///
    /// `protecting` — защищённые спаны исходного текста. Из них предложения не
    /// строятся никогда: путь, флаг или содержимое бэктиков человек правит как
    /// код, а не как термин, и превращать такую правку в молчаливое правило
    /// будущих диктовок нельзя. Пустой список — прежнее поведение.
    public static func propose(
        original: String,
        edited: String,
        existing: [DictionaryReplacement] = [],
        protecting spans: [ProtectedSpan] = []
    ) -> [DictionaryReplacement] {
        let originalWords = words(from: original)
        let editedWords = words(from: edited)
        guard !originalWords.isEmpty, !editedWords.isEmpty else { return [] }

        let known = Set(existing.map { $0.spoken.lowercased() })
        let protectedWords = Set(
            spans.flatMap { words(from: $0.text) }.map { $0.lowercased() }
        )
        var seen = Set<String>()
        var proposals: [DictionaryReplacement] = []

        for pair in substitutions(from: originalWords, to: editedWords) {
            let spoken = pair.original.joined(separator: " ")
            let written = pair.edited.joined(separator: " ")
            guard spoken.lowercased() != written.lowercased() || spoken != written else {
                continue
            }
            guard looksLikeTerm(spoken: spoken, written: written) else { continue }
            guard !known.contains(spoken.lowercased()) else { continue }
            // Хоть одно слово из защищённого куска — предложение отбрасывается
            // целиком: правка внутри кода не делает термин.
            guard !pair.original.contains(where: { protectedWords.contains($0.lowercased()) }) else {
                continue
            }
            // Одна и та же пара может встретиться в тексте дважды («открой
            // сентри и закрой сентри»). Второй экземпляр в словаре ничего не
            // добавляет, а удалять его человеку пришлось бы отдельной строкой.
            guard seen.insert("\(spoken.lowercased())\u{0}\(written)").inserted else { continue }
            // Термины из правки латиницей не склоняются — как и в стартовом
            // наборе: склоняемая основа выдумывала бы совпадения.
            proposals.append(DictionaryReplacement(spoken: spoken, written: written, inflects: false))
        }
        guard proposals.count <= maximumProposalsPerCorrection else { return [] }
        return proposals
    }

    // MARK: - Diff

    private struct Substitution {
        let original: [String]
        let edited: [String]
    }

    /// Пары «заменённый кусок → чем заменили» по LCS-выравниванию слов.
    ///
    /// Вставки и удаления замен не порождают: замена — это когда с обеих
    /// сторон что-то есть. Куски длиннее трёх слов отбрасываются: это уже
    /// переписанное предложение, а не правка термина.
    private static func substitutions(
        from original: [String],
        to edited: [String]
    ) -> [Substitution] {
        let table = lcsTable(original.map { $0.lowercased() }, edited.map { $0.lowercased() })
        var result: [Substitution] = []
        var i = original.count
        var j = edited.count
        var pendingOriginal: [String] = []
        var pendingEdited: [String] = []

        func flush() {
            defer {
                pendingOriginal = []
                pendingEdited = []
            }
            guard !pendingOriginal.isEmpty, !pendingEdited.isEmpty else { return }
            guard pendingOriginal.count <= 3, pendingEdited.count <= 3 else { return }
            result.append(
                Substitution(
                    original: pendingOriginal.reversed(),
                    edited: pendingEdited.reversed()
                )
            )
        }

        while i > 0 || j > 0 {
            if i > 0, j > 0, original[i - 1].lowercased() == edited[j - 1].lowercased(),
               original[i - 1] == edited[j - 1] {
                flush()
                i -= 1
                j -= 1
            } else if i > 0, j > 0,
                      original[i - 1].lowercased() == edited[j - 1].lowercased() {
                // Слово то же, но регистр другой — это тоже правка.
                pendingOriginal.append(original[i - 1])
                pendingEdited.append(edited[j - 1])
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                pendingEdited.append(edited[j - 1])
                j -= 1
            } else {
                pendingOriginal.append(original[i - 1])
                i -= 1
            }
        }
        flush()
        return result.reversed()
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...max(1, a.count) where !a.isEmpty {
            for j in 1...max(1, b.count) where !b.isEmpty {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table
    }

    // MARK: - Фильтры

    private static func words(from text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
    }

    /// Похоже ли исправление на термин, ради которого заводят словарь.
    ///
    /// Проверять одну лишь латиницу справа нельзя: в тексте, который целиком
    /// на латинице, этот признак не значит ничего, и обычная правка речи
    /// проходила бы за термин. Замер: «please send me the file» → «…a file»
    /// давал замену «the» → «a», после которой каждая следующая диктовка
    /// молча превращала «The report is on the desk» в «A report is on a desk».
    ///
    /// Поэтому сигналом считается не наличие латиницы, а её появление там, где
    /// её не было, либо регистр, которого у обычного слова не бывает:
    ///
    /// 1. **Смена письменности** — слева латиницы нет, справа есть. Ровно то,
    ///    как выглядит термин, услышанный кириллицей: «поуст герз» → «Postgres».
    /// 2. **Бренд-регистр** — заглавная не в начале слова: «GitHub», «macOS»,
    ///    «API». Заглавная только первой буквой сигналом не считается: она
    ///    неотличима от начала предложения, и на ней ловились пары вроде
    ///    «The» → «the» вместе со своей противоположностью «the» → «The».
    ///
    /// Одной латинской буквы для термина мало: «мир» → «a» формально сменяет
    /// письменность, а как замена по всему тексту стоит слишком дорого.
    private static func looksLikeTerm(spoken: String, written: String) -> Bool {
        guard written.filter({ $0.isLetter && $0.isASCII }).count >= 2 else { return false }

        let spokenHasLatin = spoken.contains { $0.isLetter && $0.isASCII }
        let writtenHasLatin = written.contains { $0.isLetter && $0.isASCII }
        if !spokenHasLatin, writtenHasLatin { return true }

        return words(from: written).contains { word in
            word.dropFirst().contains { $0.isUppercase && $0.isASCII }
        }
    }
}
