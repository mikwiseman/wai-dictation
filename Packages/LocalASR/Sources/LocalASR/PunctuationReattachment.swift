import Foundation

/// Возврат знаков препинания, потерянных словарным ресорером.
///
/// Замер в `docs/benchmarks.md`: на длинных записях ресорер оставлял 347 знаков
/// из 450 — он подменяет слово вместе с прилипшей к нему пунктуацией. Дефект
/// библиотечный, но вызов наш (`FluidAudioAdapter.rescore`), поэтому чинится
/// обёрткой вокруг результата, а не правкой FluidAudio.
///
/// Шов намеренно на уровне строк, а не токенов: обе стороны — обычный `String`,
/// поэтому функция чистая и проверяется вообще без модели.
///
/// Знаки снимаются **только с краёв** поля, середина не трогается. Это и
/// защищает `3.14`, `т.д.`, `https://`, `don't` и `тайп-скрипт`.
///
/// Три инварианта, на которых держатся тесты:
/// 1. ни один знак, который дал ресорер, не удаляется;
/// 2. новых знаков не появляется — только из объединения обеих сторон;
/// 3. **слова не меняются никогда** — иначе возврат пунктуации отменил бы
///    словарную правку, ради которой ресорер и работает.
enum PunctuationReattachment {
    /// Единственная публичная точка входа.
    static func restore(original: String, rescored: String) -> String {
        guard original != rescored else { return rescored }
        guard !original.isEmpty, !rescored.isEmpty else { return rescored }

        let originalFields = fields(original)
        let rescoredFields = fields(rescored)
        guard !originalFields.isEmpty, !rescoredFields.isEmpty else { return rescored }

        let steps = align(originalFields, rescoredFields)

        // Предохранитель. Если тексты разошлись слишком сильно, понять, какой
        // знак куда относится, уже нельзя, а выдумывать пунктуацию хуже, чем
        // её потерять. Это ровно сегодняшнее поведение — и оно тестируется.
        //
        // Знаменатель — короткая сторона, а не сторона ресорера. Разрыв слова
        // («постгрес» → «Post gres») законно увеличивает число полей справа, и
        // деление на них глушило бы ровно тот случай, ради которого всё писано.
        // Считаются только точные совпадения: при полном расхождении текстов
        // выравнивание всё равно даст сплошные замены, и они сигналом не служат.
        let matched = steps.filter { if case .match = $0 { return true } else { return false } }.count
        let anchor = min(originalFields.count, rescoredFields.count)
        guard anchor > 0, Double(matched) / Double(anchor) >= 0.5 else { return rescored }

        var rendered: [Field] = []
        // Куда сел знак, взятый у оригинала. Нужен, потому что разрыв слова
        // приходит хвостом из вставок: знак обязан доехать до последнего куска,
        // иначе «постгрес.» → «Post. gres» вместо «Post gres.».
        var borrowedTrailAt: Int?

        for step in steps {
            switch step {
            case let .match(originalIndex, rescoredIndex),
                 let .substitution(originalIndex, rescoredIndex):
                let source = originalFields[originalIndex]
                var field = rescoredFields[rescoredIndex]
                // Свой знак ресорера всегда главнее: там он ничего не терял.
                if field.lead.isEmpty { field.lead = source.lead }
                var borrowed = false
                if field.trail.isEmpty, !source.trail.isEmpty {
                    field.trail = source.trail
                    borrowed = true
                }
                rendered.append(field)
                borrowedTrailAt = borrowed ? rendered.count - 1 : nil

            case let .insertion(rescoredIndex):
                // Ресорер разбил слово на несколько — переносим как есть,
                // но одолженный знак забираем с собой в конец разрыва.
                var field = rescoredFields[rescoredIndex]
                if let source = borrowedTrailAt,
                   source == rendered.count - 1,
                   field.trail.isEmpty {
                    field.trail = rendered[source].trail
                    rendered[source].trail = ""
                    rendered.append(field)
                    borrowedTrailAt = rendered.count - 1
                } else {
                    rendered.append(field)
                    borrowedTrailAt = nil
                }

            case let .deletion(originalIndex):
                // Ресорер склеил несколько слов в одно. Знак отдаёт только
                // последнее удалённое поле, и только если принимающему нечего
                // терять: восстанавливать «pull, request» из «pull request»
                // значило бы выдумать пунктуацию внутри термина.
                guard !rendered.isEmpty, !originalFields[originalIndex].trail.isEmpty else { continue }
                if rendered[rendered.count - 1].trail.isEmpty {
                    rendered[rendered.count - 1].trail = originalFields[originalIndex].trail
                }
            }
        }

        return rendered.map(\.whole).joined()
    }

    // MARK: - Поля

    /// Поле — один непробельный кусок вместе с пробелами перед ним.
    ///
    /// Пробелы хранятся, чтобы собрать текст обратно без переформатирования:
    /// переводы строк и выравнивание остаются такими же, какими их дал ресорер.
    struct Field: Equatable {
        var spacingBefore: String
        var lead: String
        var core: String
        var trail: String

        var whole: String { spacingBefore + lead + core + trail }
    }

    /// Знаки, которые снимаются с краёв.
    ///
    /// Дефиса тут нет намеренно: `-x` — это ключ, а не слово со знаком, и
    /// отрывать у него дефис нельзя.
    private static let marks: Set<Character> = [
        ".", ",", "!", "?", ":", ";", "…",
        "«", "»", "\"", "'", "(", ")", "—", "–",
    ]

    static func fields(_ text: String) -> [Field] {
        let characters = Array(text)
        var result: [Field] = []
        var index = 0

        while index < characters.count {
            var spacing = ""
            while index < characters.count, characters[index].isWhitespace {
                spacing.append(characters[index])
                index += 1
            }
            guard index < characters.count else {
                // Хвостовые пробелы прицепляем к последнему полю, чтобы сборка
                // вернула текст байт-в-байт.
                if !spacing.isEmpty, !result.isEmpty {
                    result[result.count - 1].trail += spacing
                }
                break
            }

            var token = ""
            while index < characters.count, !characters[index].isWhitespace {
                token.append(characters[index])
                index += 1
            }
            result.append(split(token: token, spacingBefore: spacing))
        }
        return result
    }

    private static func split(token: String, spacingBefore: String) -> Field {
        var characters = Array(token)
        var lead = ""
        var trail = ""

        while let first = characters.first, marks.contains(first) {
            lead.append(first)
            characters.removeFirst()
        }
        while let last = characters.last, marks.contains(last) {
            trail.insert(last, at: trail.startIndex)
            characters.removeLast()
        }

        // Поле целиком из знаков — это самостоятельное «слово» (тире в роли
        // связки). Растащить его на lead и trail значило бы потерять его при
        // выравнивании.
        guard !characters.isEmpty else {
            return Field(spacingBefore: spacingBefore, lead: "", core: token, trail: "")
        }
        return Field(
            spacingBefore: spacingBefore,
            lead: lead,
            core: String(characters),
            trail: trail
        )
    }

    // MARK: - Выравнивание

    enum Step: Equatable {
        case match(Int, Int)
        case substitution(Int, Int)
        case deletion(Int)
        case insertion(Int)
    }

    /// Классический Левенштейн по полям, сравнение ядер без учёта регистра.
    static func align(_ left: [Field], _ right: [Field]) -> [Step] {
        let rows = left.count
        let columns = right.count
        var cost = Array(
            repeating: Array(repeating: 0, count: columns + 1),
            count: rows + 1
        )
        for row in 0...rows { cost[row][0] = row }
        for column in 0...columns { cost[0][column] = column }

        for row in 1...max(rows, 1) where rows > 0 {
            for column in 1...max(columns, 1) where columns > 0 {
                let same = left[row - 1].core.lowercased() == right[column - 1].core.lowercased()
                cost[row][column] = min(
                    cost[row - 1][column - 1] + (same ? 0 : 1),
                    cost[row - 1][column] + 1,
                    cost[row][column - 1] + 1
                )
            }
        }

        var steps: [Step] = []
        var row = rows
        var column = columns
        while row > 0 || column > 0 {
            if row > 0, column > 0 {
                let same = left[row - 1].core.lowercased() == right[column - 1].core.lowercased()
                if cost[row][column] == cost[row - 1][column - 1] + (same ? 0 : 1) {
                    steps.append(same ? .match(row - 1, column - 1) : .substitution(row - 1, column - 1))
                    row -= 1
                    column -= 1
                    continue
                }
            }
            if row > 0, cost[row][column] == cost[row - 1][column] + 1 {
                steps.append(.deletion(row - 1))
                row -= 1
                continue
            }
            steps.append(.insertion(column - 1))
            column -= 1
        }
        return steps.reversed()
    }
}
