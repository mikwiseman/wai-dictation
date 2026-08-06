import Foundation

/// Фонетический ключ русского слова.
///
/// Существует потому, что плоская таблица написаний не работает в принципе:
/// написание термина зависит от фразы, в которой он прозвучал. Одно слово
/// «деплой», сказанное одним голосом, модель записывает как «диплой», «депла»,
/// «деплай», «диплей» — и на следующей фразе будет пятое написание. Ключ
/// сворачивает ровно те различия, которые русская фонетика и так не различает,
/// и оставляет все остальные.
///
/// Что сворачивается:
///
/// - **безударные гласные**: «о» звучит как «а», «е»/«э»/«и»/«ы» сливаются,
///   «ю» как «у». Отсюда «диплой» = «деплой», «бэкэнд» = «бэкенд»,
///   «камит» = «комит», «мордж» = «мёрдж»;
/// - **парные по звонкости согласные — только там, где русский их и правда не
///   различает**: в конце слова и перед другим шумным. Отсюда «ребейс» =
///   «ребейз» и «фронтент» = «фронтенд»;
/// - **удвоение**: «коммит» = «комит», «Риллис» = «релис».
///
/// Что НЕ сворачивается, и это главное:
///
/// - **последняя буква, если она гласная.** В ней живёт падежное окончание, и
///   свернуть её значит объявить «центре» и «центри» одним словом — то есть
///   превратить «в центре города» в «в Sentry города»;
/// - **звонкость в начале слова и между гласными.** Русский там ничего не
///   оглушает, а сворачивание превращает «тёплой» в «деплой», «бетон» и
///   «бидон» в «питон», «протёкшей» в «production». Замер на одном и том же
///   наборе: со сворачиванием где попало под замену попадает 161 настоящее
///   русское слово, с позиционным — 70, а выигрыш ровно тот же;
/// - **мягкий и твёрдый знак.** «Камедь» ≠ «комет», «ревю» ≠ «ревью».
///
/// Радиус поражения меряется перебором, а не корпусом: для каждой записи
/// строятся все написания с тем же ключом, и системный проверяльщик орфографии
/// отбирает из них настоящие русские слова. У поставляемого набора их остаётся
/// 31, и все до одного — сами термины, обжившиеся в русском («релиз», «билд»,
/// «пиар», «ревью», «продакшн»). Обычной речи среди них нет.
enum PhoneticKey {
    /// Гласные и то, во что они сворачиваются.
    ///
    /// «я» оставлена собой: её редукция зависит от мягкости соседа, а без
    /// ударения угадать это нельзя.
    private static let vowels: [Character: Character] = [
        "а": "а", "о": "а", "ё": "а",
        "е": "е", "и": "е", "э": "е", "ы": "е",
        "у": "у", "ю": "у",
        "я": "я",
    ]

    /// Парные по звонкости — к глухому.
    private static let paired: [Character: Character] = [
        "б": "п", "п": "п",
        "в": "ф", "ф": "ф",
        "г": "к", "к": "к",
        "д": "т", "т": "т",
        "ж": "ш", "ш": "ш",
        "з": "с", "с": "с",
    ]

    /// Шумные: перед ними и происходит ассимиляция по звонкости.
    private static let obstruents: Set<Character> = [
        "б", "п", "в", "ф", "г", "к", "д", "т", "ж", "ш", "з", "с", "х", "ц", "ч", "щ",
    ]

    static func of(_ word: String) -> String {
        let lowered = word.lowercased()
        var squeezed: [Character] = []
        for character in lowered where squeezed.last != character {
            squeezed.append(character)
        }

        var key = ""
        key.reserveCapacity(squeezed.count)
        for (offset, character) in squeezed.enumerated() {
            let isLast = offset == squeezed.count - 1

            if let folded = vowels[character] {
                key.append(isLast ? character : folded)
                continue
            }

            if let devoiced = paired[character] {
                let neutralised = isLast || obstruents.contains(squeezed[offset + 1])
                if neutralised {
                    key.append(devoiced)
                    continue
                }
            }

            key.append(character)
        }
        return key
    }
}

/// Второй проход словаря: термин, записанный не так, как в словаре.
///
/// Работает только по кириллическим словам и только по тем, до которых точное
/// совпадение не дотянулось: латиница к этому моменту уже вставлена и под
/// разбор не попадает.
enum PhoneticMatching {
    /// Короче пяти букв фонетический ключ не берём.
    ///
    /// У коротких слов на один ключ приходится слишком много обычной речи:
    /// «апи» с точностью до безударных гласных совпадает с «эпи», «опа», «упа».
    /// Пять — не круглое число, а граница, ниже которой в замере начинали
    /// попадаться обычные слова.
    static let minimumLetters = 5

    /// Сколько слов подряд может занимать один термин.
    ///
    /// Модель то склеивает термин в одно слово, то разрывает на два: «даун
    /// тайм» и «даунтайм», «джава скрипт» и «джаваскрипт», «энд поинт» и
    /// «эндпоинт». Окно закрывает обе записи одной проверкой.
    private static let maximumWindow = 3

    private struct Index {
        /// Ключ записи → как писать.
        var exact: [String: String] = [:]
        /// То же, но только для записей, которые склоняются.
        var inflected: [String: String] = [:]
    }

    static func apply(_ replacements: [DictionaryReplacement], to text: String) -> String {
        apply(replacements, to: text, protecting: [])
    }

    /// Фонетический добор, обходящий защищённые спаны.
    ///
    /// Две отдельные защиты, и обе нужны. Первая — слово внутри спана вообще не
    /// попадает в список кандидатов. Вторая — окно из трёх слов не имеет права
    /// перешагнуть спан: иначе «сентри» слева и «сентри» справа от пути
    /// склеились бы в один термин через защищённый кусок.
    ///
    /// Пустое множество спанов проходит ровно тот же код, что и раньше: фильтр
    /// становится тождественным, разрывов нет, ограничение окна не меняется.
    static func apply(
        _ replacements: [DictionaryReplacement],
        to text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        let index = makeIndex(replacements)
        guard !index.exact.isEmpty, !text.isEmpty else { return text }

        let protectedRanges = indexRanges(of: spans, in: text)
        let words = wordRanges(in: text).filter { word in
            !protectedRanges.contains { $0.overlaps(word) }
        }
        guard !words.isEmpty else { return text }

        // Перед каким словом окно обязано оборваться: между ним и предыдущим
        // лежит защищённый кусок.
        var breaksBefore = Set<Int>()
        if !protectedRanges.isEmpty {
            for position in 1..<words.count {
                let gap = words[position - 1].upperBound..<words[position].lowerBound
                if protectedRanges.contains(where: { $0.overlaps(gap) }) {
                    breaksBefore.insert(position)
                }
            }
        }

        var result = ""
        var cursor = text.startIndex
        var start = 0

        while start < words.count {
            var matched = false
            var size = min(maximumWindow, words.count - start)
            // Укоротить окно до ближайшего разрыва.
            for offset in 1..<max(size, 1) where breaksBefore.contains(start + offset) {
                size = offset
                break
            }

            while size >= 1 {
                let window = Array(words[start..<(start + size)])
                if let written = lookup(window, in: text, index: index) {
                    result.append(contentsOf: text[cursor..<window[0].lowerBound])
                    result.append(written)
                    cursor = window[size - 1].upperBound
                    start += size
                    matched = true
                    break
                }
                size -= 1
            }

            if !matched { start += 1 }
        }

        result.append(contentsOf: text[cursor...])
        return result
    }

    /// Символьные офсеты спанов → диапазоны строки, к которой они посчитаны.
    private static func indexRanges(
        of spans: [ProtectedSpan],
        in text: String
    ) -> [Range<String.Index>] {
        guard !spans.isEmpty else { return [] }
        let count = text.count
        return spans.compactMap { span in
            guard span.range.lowerBound >= 0, span.range.upperBound <= count else { return nil }
            let lower = text.index(text.startIndex, offsetBy: span.range.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: span.range.upperBound)
            return lower..<upper
        }
    }

    // MARK: - Что искать

    private static func makeIndex(_ replacements: [DictionaryReplacement]) -> Index {
        var index = Index()
        var ambiguous: Set<String> = []
        var ambiguousInflected: Set<String> = []

        for replacement in replacements {
            let spoken = replacement.spoken.trimmingCharacters(in: .whitespaces)
            // Пустая правая часть — способ вычеркнуть слово-паразит. Точному
            // совпадению это по силам, фонетическому добору — нет: удаление не
            // видно в тексте, и промах здесь человек не заметит вовсе.
            guard !replacement.written.isEmpty else { continue }

            let letters = compacted(spoken)
            guard letters.count >= minimumLetters, isCyrillic(letters) else { continue }

            let key = PhoneticKey.of(letters)
            if let existing = index.exact[key], existing != replacement.written {
                ambiguous.insert(key)
            }
            index.exact[key] = replacement.written

            guard replacement.inflects else { continue }
            if let existing = index.inflected[key], existing != replacement.written {
                ambiguousInflected.insert(key)
            }
            index.inflected[key] = replacement.written
        }

        // Один ключ на два разных термина — это не выбор, а угадывание.
        for key in ambiguous { index.exact.removeValue(forKey: key) }
        for key in ambiguousInflected { index.inflected.removeValue(forKey: key) }
        return index
    }

    // MARK: - Разбор текста

    /// Слова текста. Цифра рядом с буквами делает слово другим: «апи2» — не «апи».
    private static let wordExpression = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])\\p{L}+(?:-\\p{L}+)*(?![\\p{L}\\p{N}])"
    )

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        guard let expression = wordExpression else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: whole).compactMap {
            Range($0.range, in: text)
        }
    }

    /// Чем писать эти слова, если они на самом деле термин.
    private static func lookup(
        _ window: [Range<String.Index>],
        in text: String,
        index: Index
    ) -> String? {
        // Слова окна должны идти подряд через пробелы: «энд, поинт» — это два
        // разных места фразы, а не разорванный термин.
        for pair in zip(window, window.dropFirst()) {
            let gap = text[pair.0.upperBound..<pair.1.lowerBound]
            guard !gap.isEmpty, gap.allSatisfy({ $0 == " " }) else { return nil }
        }

        let parts = window.map { compacted(String(text[$0])) }
        guard parts.allSatisfy({ isCyrillic($0) && !$0.isEmpty }) else { return nil }

        let head = parts.dropLast().joined()
        guard let tail = parts.last else { return nil }

        let whole = head + tail
        if whole.count >= minimumLetters, let written = index.exact[PhoneticKey.of(whole)] {
            return written
        }

        for stem in stems(of: tail) {
            let candidate = head + stem
            guard candidate.count >= minimumLetters else { continue }
            if let written = index.inflected[PhoneticKey.of(candidate)] {
                return written
            }
        }
        return nil
    }

    /// Основы слова после отсечения падежного хвоста.
    ///
    /// Список хвостов тот же закрытый, что и у точного совпадения, и «-й»
    /// возвращается на место по той же причине: «деплою» — это «депло» + «ю»,
    /// а сам термин кончается на «й».
    private static func stems(of word: String) -> [String] {
        var found: [String] = []
        for ending in inflectionEndings where word.hasSuffix(ending) {
            let stem = String(word.dropLast(ending.count))
            guard stem.count >= 3 else { continue }
            found.append(stem)
            found.append(stem + "й")
        }
        return found
    }

    private static let inflectionEndings = [
        "ами", "ями", "ой", "ей", "ом", "ем", "ов", "ев", "ам", "ям", "ах", "ях",
        "а", "е", "и", "ы", "у", "ю", "я",
    ]

    // MARK: - Мелочи

    /// Слово без пробелов и дефисов: они у термина необязательны.
    private static func compacted(_ text: String) -> String {
        text.filter { $0 != " " && $0 != "-" }.lowercased()
    }

    /// Латинские замены фонетическому разбору не подлежат: правила русские.
    private static func isCyrillic(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
}
