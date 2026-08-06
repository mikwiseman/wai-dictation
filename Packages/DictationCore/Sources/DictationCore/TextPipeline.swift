import Foundation

/// Команда, сказанная в конце диктовки.
///
/// «Отправь» в конце фразы — это не текст, а действие: пользователь ждёт, что
/// сообщение уйдёт, а не что слово окажется в поле ввода.
public enum TrailingCommand: String, Sendable, Equatable, CaseIterable {
    case pressReturn
    case newLine

    /// Варианты произношения на русском и английском.
    var phrases: [String] {
        switch self {
        case .pressReturn:
            return ["отправь", "отправить", "энтер", "send it", "press enter"]
        case .newLine:
            return ["новая строка", "с новой строки", "new line"]
        }
    }
}

/// Разбор завершающей команды.
public enum TrailingCommandParser {
    public struct Result: Sendable, Equatable {
        public let text: String
        public let command: TrailingCommand?
    }

    /// Отделить команду от текста.
    ///
    /// Разбирается только самый хвост фразы: слово «отправь» в середине
    /// предложения — обычное слово, а не команда.
    public static func parse(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(text: trimmed, command: nil) }

        // Хвост сравниваем без финальной пунктуации: «…отправь.» — та же команда.
        let strippedTail = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))

        for command in TrailingCommand.allCases {
            for phrase in command.phrases where strippedTail.hasSuffix(phrase) {
                // Команда должна быть отдельным словом, а не хвостом другого.
                let cutoff = strippedTail.index(strippedTail.endIndex, offsetBy: -phrase.count)
                if cutoff > strippedTail.startIndex {
                    let preceding = strippedTail[strippedTail.index(before: cutoff)]
                    guard preceding == " " else { continue }
                }

                let withoutCommand = stripSuffix(phrase, from: trimmed)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))

                // Команда, сказанная в одиночку, — это просто слово.
                //
                // Текста для вставки не осталось, а нажимать Return в чужом окне
                // по одной догадке нельзя: отправленное сообщение не отзывается.
                // Раньше такая диктовка проваливалась в никуда — пустой текст
                // отменял и вставку, и само нажатие.
                guard !withoutCommand.isEmpty else { return Result(text: trimmed, command: nil) }

                return Result(text: withoutCommand, command: command)
            }
        }
        return Result(text: trimmed, command: nil)
    }

    private static func stripSuffix(_ phrase: String, from text: String) -> String {
        // Ищем в самой строке, а не в её копии, приведённой к нижнему регистру.
        // У приведения своя длина: турецкая «İ» превращается в два символа, и
        // позиции, найденные в копии, режут оригинал не там — вплоть до падения
        // на выходе за границы строки.
        guard let range = text.range(of: phrase, options: [.backwards, .caseInsensitive]) else {
            return text
        }
        return String(text[text.startIndex..<range.lowerBound])
    }
}

/// Полный путь от распознанного текста до того, что увидит пользователь.
///
/// **Таблица стадий.** Порядок зафиксирован и проверяется golden-тестами на
/// каждой границе (`TextPipelineContractTests`):
///
/// | # | Стадия | Что делает |
/// |---|---|---|
/// | 1 | парсер команд | отделяет завершающую команду — до всех замен, иначе словарь её заденет |
/// | 2 | словарь: точный проход | буквальные записи словаря, с падежами |
/// | 3 | детекция спанов | первый расчёт защищённых кусков |
/// | 4 | словарь: фонетический добор | догадки — только вне спанов |
/// | 5 | *(чистка языковой моделью)* | **зарезервировано**, в этой волне стадии нет |
/// | 6 | *(сниппеты)* | **зарезервировано**, в этой волне стадии нет |
/// | 7 | typography-fold | 12 символов, вне спанов |
/// | 8 | полишер | пробелы, пунктуация, первая буква — вне спанов |
/// | 9 | материализация `.newLine` | строго последней: полишер обрезает `\n` |
///
/// Стадии 5 и 6 зарезервированы **комментарием, а не кодом**: заглушка, которая
/// ничего не делает, — церемония, а не контракт. Когда они появятся, они встают
/// между 4 и 7, и гейт спанов подхватит их сам.
///
/// Ключ ко всей модели защиты: **точная замена идёт до того, как спаны вообще
/// существуют**. Это и есть правило «явная воля человека выше защиты спана» —
/// отдельного правила прецеденса писать не нужно, порядок и есть правило.
public struct TextPipeline: Sendable {
    public struct Output: Sendable, Equatable {
        /// Текст, готовый к вставке.
        public let text: String
        /// Что нажать после вставки, если пользователь об этом попросил.
        ///
        /// Перевод строки сюда не попадает: он уже в тексте. Нажатием его не
        /// сделать — Return в чужом окне отправляет сообщение, а не переносит
        /// строку.
        public let command: TrailingCommand?
    }

    /// Результат прогона вместе с происхождением текста.
    public struct Run: Sendable, Equatable {
        public let output: Output
        public let provenance: PipelineProvenance
    }

    private let replacements: [DictionaryReplacement]
    private let allowPressReturnCommand: Bool
    /// Выключатель фонетического добора — существует ради замера «а нужен ли
    /// он вообще поверх акустического подсказчика» (WAI_EVAL_PIPELINE=exact).
    private let phoneticMatching: Bool

    public init(
        replacements: [DictionaryReplacement] = [],
        allowPressReturnCommand: Bool = false,
        phoneticMatching: Bool = true
    ) {
        self.replacements = replacements
        self.allowPressReturnCommand = allowPressReturnCommand
        self.phoneticMatching = phoneticMatching
    }

    public func process(_ recognized: String) -> Output {
        run(recognized).output
    }

    /// То же, что `process`, но с записью происхождения текста.
    ///
    /// Происхождение строится **безусловно** — оно не зависит ни от одного
    /// пользовательского тумблера. Единственный путь один и тот же: `process`
    /// вызывает `run` и выбрасывает запись, поэтому «ветки без провенанса»
    /// в продукте не существует.
    public func run(_ recognized: String) -> Run {
        var parsed = TrailingCommandParser.parse(recognized)
        // В safe beta голосовая команда Send/Return отключена: один false
        // trigger необратимо отправляет сообщение или форму. Сам parser
        // остаётся отдельно тестируемым для возможного явного режима позже.
        if parsed.command == .pressReturn, !allowPressReturnCommand {
            parsed = TrailingCommandParser.Result(text: recognized, command: nil)
        }

        // Стадия 2: точный проход — до того, как спаны существуют.
        let exact = DictionaryReplacements.applyExact(replacements, to: parsed.text)
        // Стадия 3: первый расчёт спанов — уже по результату точных замен.
        let spansAfterExact = ProtectedSpanDetector.detect(in: exact)
        // Стадия 4: фонетический добор вне спанов.
        let afterDictionary = phoneticMatching
            ? DictionaryReplacements.applyPhonetic(replacements, to: exact, protecting: spansAfterExact)
            : exact

        // Стадия 7: свёртка типографики вне спанов.
        let folded = TypographyFold.fold(
            afterDictionary,
            protecting: ProtectedSpanDetector.detect(in: afterDictionary)
        )
        // Стадия 8: полишер (спаны пересчитывает сам).
        let polished = TranscriptPolisher.polish(folded)

        // Стадия 9: материализация «новой строки» — строго последней, иначе
        // полишер срежет перенос своим trim.
        let output: Output
        if parsed.command == .newLine, !polished.isEmpty {
            // «Новая строка» — команда, которую нельзя выполнить нажатием: Return
            // отправил бы сообщение. Поэтому перенос уходит прямо в текст — он и
            // вставляется вместе с ним. Раньше слова из текста вырезались, а взамен
            // не происходило ничего: команда пропадала целиком.
            output = Output(text: polished + "\n", command: nil)
        } else {
            output = Output(text: polished, command: parsed.command)
        }

        return Run(
            output: output,
            provenance: PipelineProvenance(
                raw: recognized,
                afterDictionary: afterDictionary,
                finalText: output.text,
                spans: ProtectedSpanDetector.detect(in: output.text)
            )
        )
    }
}
