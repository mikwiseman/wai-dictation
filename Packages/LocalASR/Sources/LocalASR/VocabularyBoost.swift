import DictationCore
import Foundation

/// Термины, которые распознавание должно узнавать на уровне звука.
///
/// Это не словарь замен: замены чинят текст после распознавания, а эти
/// термины уходят в акустический подсказчик (CTC keyword spotting) и меняют
/// сам результат. Тип живёт отдельно от FluidAudio, чтобы правила подготовки
/// списка проверялись без модели.
public struct VocabularyBoost: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public let text: String
        /// Альтернативные написания того же термина — прежде всего
        /// кириллические: текст модели внутри русской фразы кириллический, и
        /// без такого моста кандидат на замену не находится вовсе.
        public let aliases: [String]

        /// Псевдонимы нормализуются как термины: пустое выбрасывается, края
        /// срезаются, дубликаты и совпадение с самим термином схлопываются.
        public init(text: String, aliases rawAliases: [String] = []) {
            self.text = text
            var seen: Set<String> = [text.lowercased()]
            var prepared: [String] = []
            for raw in rawAliases {
                let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alias.isEmpty else { continue }
                guard seen.insert(alias.lowercased()).inserted else { continue }
                prepared.append(alias)
            }
            aliases = prepared
        }
    }

    public let terms: [Term]

    /// Насколько похоже слово в тексте должно быть на термин или псевдоним,
    /// чтобы претендовать на замену (0…1). Ниже — шире охват и больше ложных
    /// срабатываний на обычной речи; выше — осторожнее. Значение выбрано
    /// замером на корпусе: см. docs/benchmarks.md.
    public let minSimilarity: Float

    /// Насколько акустическая улика термина должна перевешивать исходное
    /// слово. Больше — замена агрессивнее; обычная русская речь, похожая на
    /// термин по звуку («в центре» и Sentry), страдает первой.
    public let biasWeight: Float

    public var isEmpty: Bool { terms.isEmpty }

    /// Пустые строки выбрасываются, пробелы по краям срезаются, дубликаты
    /// схлопываются без учёта регистра — побеждает первое написание: его
    /// человек ввёл сам.
    public init(terms rawTerms: [Term], minSimilarity: Float = 0.65, biasWeight: Float = 3.0) {
        var seen = Set<String>()
        var prepared: [Term] = []
        for term in rawTerms {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            guard seen.insert(key).inserted else { continue }
            prepared.append(Term(text: text, aliases: term.aliases))
        }
        terms = prepared
        self.minSimilarity = min(1, max(0, minSimilarity))
        self.biasWeight = biasWeight
    }
}

extension VocabularyBoost {
    /// Термины, которые человек держит подальше от акустики.
    ///
    /// Раньше здесь лежал захардкоженный список из трёх слов. Теперь решает
    /// сама запись — `DictionaryReplacement.noAcousticBoost`, — потому что у
    /// каждого свои термины: «касса» ловит «Kassa», «сани» — «Sunny», и наш
    /// список из трёх слов про них ничего не знал. Причина, по которой такие
    /// термины вообще исключаются, — в документации к самому флагу.
    static func unboostable(_ replacements: [DictionaryReplacement]) -> Set<String> {
        Set(replacements.filter(\.noAcousticBoost).map(\.written))
    }

    /// Набор по словарю пользователя: стартовые термины плюс его собственные
    /// замены — включая выученные из правок.
    public static func withUserReplacements(
        _ replacements: [DictionaryReplacement]
    ) -> VocabularyBoost {
        let defaults = developerDefault()
        let known = Set(defaults.terms.map { $0.text.lowercased() })
        // Отмеченное человеком плюс отмеченное в заготовке: пользовательская
        // запись «деплой → deploy» не имеет права вернуть deploy в акустику
        // только потому, что в ней самой галочки нет.
        let blocked = unboostable(replacements).union(unboostable(StarterDictionary.developer))
        let userTerms = replacements
            .filter { !blocked.contains($0.written) }
            .filter { $0.written.contains { $0.isLetter && $0.isASCII } }
            .filter { !known.contains($0.written.lowercased()) }
            .map { Term(text: $0.written, aliases: [$0.spoken]) }
        return VocabularyBoost(terms: defaults.terms + userTerms)
    }

    /// Готовый набор для словаря разработчика: латинский термин плюс его
    /// кириллические написания как псевдонимы — мост от звука к латинице.
    public static func developerDefault() -> VocabularyBoost {
        let starter = StarterDictionary.developer
        let blocked = unboostable(starter)
        let grouped = Dictionary(grouping: starter, by: \.written)
        return VocabularyBoost(
            terms: grouped
                .filter { !blocked.contains($0.key) }
                .map { written, group in
                    Term(text: written, aliases: group.map(\.spoken))
                }
                .sorted { $0.text < $1.text }
        )
    }
}

/// Беда со списком терминов, а не с моделью.
///
/// Отдельный тип существует ради одного различия, которое пользователь видит
/// глазами: `ASREngineError.modelsUnavailable` означает «весам плохо, надо
/// перекачать», и приложение честно предлагает восстановление на 483 МБ.
/// Непереводимый в токены термин — это данные человека; перекачка модели его
/// не исправит, а предложение её сделать вводит в заблуждение и стоит
/// пользователю трафика. Ловите этот тип отдельно и показывайте правку словаря,
/// а не восстановление модели.
public enum VocabularyBoostError: Error, Sendable, Equatable {
    /// Термин под этим номером (с единицы) подсказчик не может разложить на
    /// токены. Сам текст термина в ошибку не попадает: содержимое словаря —
    /// такие же данные человека, как и текст диктовки.
    case termNotTokenizable(index: Int)
}

/// Движок, умеющий показывать распознавание вживую, пока человек говорит.
///
/// Текст предпросмотра — только для глаз: источником истины остаётся
/// batch-распознавание готовой записи тем же движком.
public protocol LivePreviewCapable: Sendable {
    /// `confirmed` — устоявшийся текст, `volatile` — хвост, который ещё может
    /// поменяться. Обновления приходят не чаще четырёх раз в секунду: мерцание
    /// отвлекает сильнее, чем задержка.
    func startPreview(
        onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
    ) async throws
    func feedPreview(samples: [Float]) async
    func stopPreview() async
}

extension FluidAudioAdapter: LivePreviewCapable {}

/// Движок, умеющий принимать акустические подсказки терминов.
///
/// Протокол живёт в LocalASR, а не в DictationCore: ядру диктовки безразлично,
/// откуда взялся текст, а способность «узнавать термины по звуку» — свойство
/// конкретного движка.
public protocol VocabularyBoostCapable: Sendable {
    func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws
}

extension FluidAudioAdapter: VocabularyBoostCapable {}
