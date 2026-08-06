import Foundation

/// Пользовательская замена: как распознаётся → как должно быть написано.
///
/// Ради этого словарь и нужен: модель не знает названий, которыми пользователь
/// живёт каждый день, и стабильно пишет «сентри» вместо «Sentry».
public struct DictionaryReplacement: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Что услышала модель.
    public var spoken: String
    /// Что должно оказаться в тексте.
    public var written: String
    /// Ждать ли у записи падежные окончания.
    ///
    /// Свойство записи, а не вывод из её букв. «Деплой» — слово, у него есть
    /// «деплоя» и «деплою». «Комет» — не слово, а огрех распознавания: у него
    /// нет падежей, зато есть «комета», которую склоняемая основа «комет-»
    /// съедала вместе с термином. Замер этого стоил: настоящих русских слов в
    /// радиусе поражения набора было 89, из них четыре семьи — обычная речь.
    public var inflects: Bool
    /// Держать ли термин подальше от акустического подсказчика.
    ///
    /// Свойство записи, а не список в чужом файле. Есть термины, чьё
    /// кириллическое звучание — обычное русское слово: «deploy» ловит «тёплой»,
    /// «Sentry» — «в центре», «commit» — «комету». Похожесть библиотеки видит
    /// сквозь алфавиты (`sim("центре", Sentry) = 0.83`), а англоязычная
    /// CTC-модель всегда оценит латинский термин выше кириллического слова на
    /// той же записи. Хуже того, «центре» в честной русской фразе и «центре» на
    /// месте Sentry — один и тот же текст, и никакой порог их не разделит.
    /// Такие термины остаются словарю замен, чьи правила обычную речь не
    /// трогают (docs/benchmarks.md).
    ///
    /// Раньше это был захардкоженный список из трёх слов в `VocabularyBoost`.
    /// Собственные термины человека в него не попадали никогда, а добавить свой
    /// он не мог вовсе.
    public var noAcousticBoost: Bool

    public init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        inflects: Bool = true,
        noAcousticBoost: Bool = false
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.inflects = inflects
        self.noAcousticBoost = noAcousticBoost
    }

    /// Свой разбор нужен из-за `inflects` и `noAcousticBoost`: в словарях,
    /// записанных до их появления, ключей нет. Отсутствие `inflects` — это
    /// «склоняется», как и было; отсутствие `noAcousticBoost` — «бустится»,
    /// потому что раньше решал список, а не запись.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spoken = try container.decode(String.self, forKey: .spoken)
        written = try container.decode(String.self, forKey: .written)
        inflects = try container.decodeIfPresent(Bool.self, forKey: .inflects) ?? true
        noAcousticBoost = try container.decodeIfPresent(Bool.self, forKey: .noAcousticBoost) ?? false
    }
}

/// Применение словаря к распознанному тексту.
public enum DictionaryReplacements {
    /// Заменить все вхождения по границам слов.
    ///
    /// Границы обязательны: без них замена «код» → «code» превратила бы
    /// «кодировка» в «codeировка». Регистр входа игнорируется, потому что
    /// распознавание не гарантирует его стабильность.
    ///
    /// Проходов два, и порядок важен. Сначала точное совпадение с падежами —
    /// оно отвечает за всё, что записано в словаре буквально. Потом
    /// фонетический добор: он ловит те написания термина, которых в словаре
    /// нет и быть не может, потому что модель пишет одно и то же слово
    /// по-разному в разных фразах. Замер обоих проходов — в docs/benchmarks.md.
    /// Проходы расщеплены (`applyExact` + `applyPhonetic`), потому что между
    /// ними встаёт детекция защищённых спанов: точная замена — явная воля
    /// человека и идёт до того, как спаны вообще существуют, а фонетический
    /// добор — догадка и обязан спаны обходить. Порядок и есть правило
    /// приоритета; отдельных правил прецеденса писать не нужно.
    public static func apply(
        _ replacements: [DictionaryReplacement],
        to text: String,
        phoneticMatching: Bool = true
    ) -> String {
        let exact = applyExact(replacements, to: text)
        guard phoneticMatching else { return exact }
        return applyPhonetic(replacements, to: exact, protecting: [])
    }

    /// Первый проход: точное совпадение с падежами.
    ///
    /// Дословный подъём прежнего тела — накопитель мутирующий и общий, поэтому
    /// замены могут наслаиваться (позднее правило переписывает то, что породило
    /// раннее). Это поведение зафиксировано тестами и менять его нельзя.
    static func applyExact(
        _ replacements: [DictionaryReplacement],
        to text: String
    ) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }

        var result = text
        // Длинные варианты первыми: иначе «pull» подменится внутри «pull request».
        for replacement in replacements.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            let spoken = replacement.spoken.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { continue }
            result = replaceWholeWords(
                of: spoken,
                with: replacement.written,
                inflected: replacement.inflects,
                in: result
            )
        }
        return result
    }

    /// Второй проход: фонетический добор вне защищённых спанов.
    ///
    /// Пустое множество спанов уходит буквально на прежний путь, а не «на новый
    /// путь с пустым фильтром». Матчер жадный, его поведение эмерджентное, и
    /// идентичность должна держаться на построении, а не на рассуждении.
    static func applyPhonetic(
        _ replacements: [DictionaryReplacement],
        to text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }
        guard !spans.isEmpty else { return PhoneticMatching.apply(replacements, to: text) }
        return PhoneticMatching.apply(replacements, to: text, protecting: spans)
    }

    static func replaceWholeWords(
        of needle: String,
        with replacement: String,
        inflected: Bool,
        in text: String
    ) -> String {
        let expression = pattern(for: needle, inflected: inflected)
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Падежные окончания, которые русский добавляет к заимствованному слову.
    ///
    /// Список закрытый и короткий намеренно: это не «похожие слова», а ровно те
    /// хвосты, из-за которых точное совпадение не срабатывает никогда.
    private static let endings = [
        "ами", "ями", "ой", "ей", "ом", "ем", "ов", "ев", "ам", "ям", "ах", "ях",
        "а", "е", "и", "ы", "у", "ю", "я",
    ]

    /// Выражение для поиска замены в тексте.
    ///
    /// Русское слово склоняется, а латинский термин — нет. Человек говорит
    /// «перед релизом», «на питоне», «без даунтайма» и ждёт «перед release»,
    /// «на Python», «без downtime» — замена по точному совпадению здесь не
    /// срабатывает ни разу. Поэтому у кириллических замен допускается падежное
    /// окончание в конце.
    ///
    /// Латинских замен это не касается: английские термины в русской речи не
    /// склоняются, а лишний хвост там означал бы другое слово.
    static func pattern(for needle: String, inflected: Bool = true) -> String {
        let leading = "(?<![\\p{L}\\p{N}])"
        let trailing = "(?![\\p{L}\\p{N}])"

        let words = needle.split(separator: " ").map(String.init)
        guard let last = words.last, inflected, isInflectable(needle) else {
            return leading + NSRegularExpression.escapedPattern(for: needle) + trailing
        }

        // У слов на «-й» окончание заменяет саму «й»: деплой → деплоя, деплою.
        // Поэтому её отрезаем, а в список хвостов добавляем обратно — иначе
        // само слово перестало бы совпадать с собой.
        let hasShortI = last.hasSuffix("й")
        let stem = hasShortI ? String(last.dropLast()) : last
        let tails = (hasShortI ? ["й"] + Self.endings : Self.endings)
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        let head = words.dropLast()
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        let prefix = head.isEmpty ? "" : head + "\\s+"

        return leading + prefix + NSRegularExpression.escapedPattern(for: stem)
            + "(?:" + tails + ")?" + trailing
    }

    /// Стоит ли ждать падежного окончания.
    ///
    /// Только для кириллицы и только от четырёх букв: у коротких слов хвост
    /// слишком часто оказывается началом другого слова.
    ///
    /// Слова на гласную («фигма» → «фигме») сюда не попадают, и это осознанно.
    /// Чтобы их поймать, пришлось бы отрезать конечную гласную — а тогда
    /// «центри» превратится в основу «центр», и «в центре города» станет
    /// «в Sentry города». Ровно этот случай мы бережём отдельным тестом. Цена —
    /// такая замена ловится только в той форме, в какой записана; в
    /// поставляемом наборе на гласную кончаются шесть записей: «ревью»,
    /// «код ревью», «кот ревью», «сентри», «центри», «линти».
    private static func isInflectable(_ needle: String) -> Bool {
        guard let last = needle.split(separator: " ").last, last.count >= 4 else { return false }
        return needle.allSatisfy { character in
            // Дефис — часть термина: модель пишет «тайп-скрипт» одним словом,
            // и склоняется у него всё равно только хвост.
            character == " " || character == "-"
                || character.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
        }
    }
}
