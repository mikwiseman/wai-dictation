import Foundation

/// Кусок текста, который после словаря не трогает ни одна стадия конвейера.
///
/// Появился ради конкретного дефекта: полишер ставит пробел после точки перед
/// заглавной, и `TextPipeline.Output` превращался в `TextPipeline. Output`.
/// Тем же механизмом закрывается более неприятное — фонетическая замена,
/// сработавшая внутри пути или бэктиков.
///
/// Диапазон хранится в символьных офсетах (`Character`), а не в `String.Index`
/// и не в `NSRange`: весь пакет уже ходит по `Array(text)`, а перевод между
/// `NSRange` и `String.Index` в этом репозитории один раз уже стоил бага.
public struct ProtectedSpan: Sendable, Equatable, Hashable {
    /// Чем именно является защищённый кусок.
    ///
    /// Набор закрыт. Каждый случай — не «похоже на код», а конкретное
    /// написание, которое человек диктует и ожидает увидеть дословно.
    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        /// Текст в обратных кавычках вместе с самими кавычками.
        case backticks
        /// Путь в файловой системе или URL.
        case path
        /// Ключ командной строки: `--dry-run`, `-x`, `--out=build/app`.
        case flag
        /// CamelCase или точечный идентификатор: `TextPipeline`, `AppState.shared`.
        case identifier
    }

    public let kind: Kind
    /// Символьные офсеты в тексте, для которого спан посчитан.
    public let range: Range<Int>
    /// Сам текст спана.
    ///
    /// Дублирует `range` намеренно: гейт «спаны не изменились» становится
    /// сравнением строк, а упавший тест читается без пересчёта офсетов в уме.
    public let text: String

    public init(kind: Kind, range: Range<Int>, text: String) {
        self.kind = kind
        self.range = range
        self.text = text
    }
}

/// Поиск защищённых спанов в тексте.
///
/// Чистая функция: один и тот же текст всегда даёт одни и те же спаны. На этом
/// стоит весь контракт конвейера — стадии пересчитывают спаны после каждой
/// правки текста, поэтому «уплывших» офсетов в принципе не бывает.
///
/// Скан идёт слева направо, спаны не пересекаются, при конфликте побеждает
/// начавшийся раньше и более длинный.
enum ProtectedSpanDetector {
    static func detect(in text: String) -> [ProtectedSpan] {
        let characters = Array(text)
        var spans: [ProtectedSpan] = []
        var index = 0

        while index < characters.count {
            // Бэктики — первыми и безусловно: внутри уже код, и остальные
            // правила там искать нечего.
            if characters[index] == "`", let span = backtickSpan(characters, from: index) {
                spans.append(span)
                index = span.range.upperBound
                continue
            }

            guard isTokenStart(characters, at: index) else {
                index += 1
                continue
            }

            let end = tokenEnd(characters, from: index)
            let token = Array(characters[index..<end])

            if let span = spanForToken(token, startingAt: index) {
                spans.append(span)
            }
            index = end
        }

        return spans
    }

    // MARK: - Бэктики

    /// Пара из одинакового числа бэктиков с непустым содержимым без перевода строки.
    private static func backtickSpan(_ characters: [Character], from start: Int) -> ProtectedSpan? {
        var openEnd = start
        while openEnd < characters.count, characters[openEnd] == "`" { openEnd += 1 }
        let fenceLength = openEnd - start

        var cursor = openEnd
        while cursor < characters.count {
            if characters[cursor] == "\n" { return nil }
            guard characters[cursor] == "`" else { cursor += 1; continue }

            var closeEnd = cursor
            while closeEnd < characters.count, characters[closeEnd] == "`" { closeEnd += 1 }
            guard closeEnd - cursor == fenceLength else { cursor = closeEnd; continue }
            guard cursor > openEnd else { return nil }

            let range = start..<closeEnd
            return ProtectedSpan(
                kind: .backticks,
                range: range,
                text: String(characters[range])
            )
        }
        return nil
    }

    // MARK: - Токены

    /// Токен начинается там, где кончился пробел, и только с «непробельного».
    private static func isTokenStart(_ characters: [Character], at index: Int) -> Bool {
        guard !characters[index].isWhitespace else { return false }
        guard index > 0 else { return true }
        return characters[index - 1].isWhitespace
    }

    private static func tokenEnd(_ characters: [Character], from start: Int) -> Int {
        var end = start
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        return end
    }

    /// Разбор одного токена. Порядок проверок — от самого специфичного к общему.
    private static func spanForToken(_ token: [Character], startingAt start: Int) -> ProtectedSpan? {
        // Хвостовая пунктуация принадлежит фразе, а не токену: «открой /etc/hosts.»
        var body = token
        while let last = body.last, isTrailingPunctuation(last) { body.removeLast() }
        guard !body.isEmpty else { return nil }

        let kind: ProtectedSpan.Kind?
        if isFlag(body) {
            kind = .flag
        } else if isPath(body) {
            kind = .path
        } else if isIdentifier(body) {
            kind = .identifier
        } else {
            kind = nil
        }

        guard let kind else { return nil }
        let range = start..<(start + body.count)
        return ProtectedSpan(kind: kind, range: range, text: String(body))
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        ",.!?;:…»\")".contains(character)
    }

    // MARK: - Правила

    /// `--flag`, `--flag=value` или короткий `-x` ровно из одной буквы.
    ///
    /// Одна буква — не придирка: `-5` это число, а `-xvf` в диктовке не бывает,
    /// зато «слово -слово» бывает, и превращать это во флаг нельзя.
    private static func isFlag(_ token: [Character]) -> Bool {
        if token.count >= 3, token[0] == "-", token[1] == "-" {
            guard token[2].isLetter, token[2].isASCII else { return false }
            return true
        }
        if token.count == 2, token[0] == "-" {
            return token[1].isLetter && token[1].isASCII
        }
        return false
    }

    /// Путь: обязателен слэш и одно из трёх подтверждений.
    ///
    /// Голого `foo/bar` мало — в русской речи это «или», и таких сочетаний
    /// заметно больше, чем путей из двух простых сегментов.
    private static func isPath(_ token: [Character]) -> Bool {
        guard token.contains("/") else { return false }

        let string = String(token)
        if string.contains("://") { return true }
        if string.hasPrefix("/") || string.hasPrefix("./")
            || string.hasPrefix("../") || string.hasPrefix("~/") {
            return hasNonEmptySegment(string)
        }

        let segments = string.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return false }
        guard segments.allSatisfy({ $0.allSatisfy(isPathSegmentCharacter) }) else { return false }

        let slashes = token.filter { $0 == "/" }.count
        let hasRichSegment = segments.contains { $0.contains(".") || $0.contains("_") || $0.contains("-") }
        return slashes >= 2 || hasRichSegment
    }

    private static func hasNonEmptySegment(_ string: String) -> Bool {
        string.split(separator: "/").contains { !$0.isEmpty }
    }

    private static func isPathSegmentCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        if character.isLetter || character.isNumber { return true }
        return "._+@-".contains(character)
    }

    /// CamelCase либо точечный идентификатор с заглавной хотя бы в одном сегменте.
    private static func isIdentifier(_ token: [Character]) -> Bool {
        guard token.allSatisfy({ $0.isASCII }) else { return false }

        if token.contains(".") {
            let segments = String(token).split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return false }
            guard segments.allSatisfy(isIdentifierSegment) else { return false }
            // Домены и версии отсекаются здесь: у `wai.computer` и `2.0.1` нет
            // ни заглавной, ни CamelCase — и обе уже защищены гвардией полишера.
            return segments.contains { segment in
                segment.first?.isUppercase == true || isCamelCase(Array(segment))
            }
        }

        return isCamelCase(token)
    }

    private static func isIdentifierSegment(_ segment: Substring) -> Bool {
        guard let first = segment.first, first.isLetter || first == "_" else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Две формы CamelCase, и обе настоящие.
    ///
    /// Первая — переход со строчной на заглавную: `onTextInserted`, `TextPipeline`.
    /// Вторая — аббревиатура, за которой начинается слово: `URLSession`,
    /// `NSString`, `HTTPServer`. Во второй нет ни одного перехода lower→upper,
    /// и без отдельного правила такие имена оставались бы без защиты.
    ///
    /// `API`, `JSON`, `HTTP` не подходят ни под одну: за аббревиатурой ничего
    /// не начинается. Защита им и не нужна — точки внутри нет, ломать нечего.
    ///
    /// Защита одиночного слова не формальность: без неё `capitalizeFirstLetter`
    /// превращает продиктованное первым словом `onTextInserted` в `OnTextInserted`.
    private static func isCamelCase(_ token: [Character]) -> Bool {
        guard token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }

        for (previous, current) in zip(token, token.dropFirst())
        where previous.isLowercase && current.isUppercase {
            return true
        }

        for index in 0..<max(0, token.count - 2)
        where token[index].isUppercase
            && token[index + 1].isUppercase
            && token[index + 2].isLowercase {
            return true
        }

        return false
    }
}
