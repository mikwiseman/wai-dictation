import Foundation

/// Как обходиться с текстом в конкретном приложении.
///
/// В терминале и редакторе кода человек диктует то, что должно попасть в файл
/// дословно. В письме и чате — фразу, которую не жалко прибрать.
public enum PromptMode: String, Sendable, Equatable, CaseIterable {
    /// Дословно: косметика по минимуму, код неприкосновенен.
    case verbatim
    /// Проза: разрешена та обработка, которая не меняет смысл.
    case prose
}

/// Категория приложения-получателя.
///
/// Девять категорий — сид, перенесённый из wai-computer. Категория, а не
/// плоский список bundle id, потому что человек рассуждает именно так:
/// «в терминалах дословно» — одно решение, а не двадцать.
public enum ApplicationCategory: String, Sendable, Equatable, CaseIterable {
    case terminal
    case codeEditor
    case notes
    case messaging
    case mail
    case browser
    case design
    case office
    case unknown

    /// Режим по умолчанию для категории.
    public var defaultMode: PromptMode {
        switch self {
        case .terminal, .codeEditor:
            return .verbatim
        case .notes, .messaging, .mail, .browser, .design, .office:
            return .prose
        case .unknown:
            // **Дефолт неизвестного — дословно.** Ошибка в эту сторону оставит
            // лишнее слово; ошибка в другую тихо перепишет команду в терминале,
            // который мы просто не узнали.
            return .verbatim
        }
    }
}

/// Решение «какой режим применить к этому приложению».
///
/// Чистый тип с тестами, как требует CLAUDE.md: это политика, а не логика
/// внутри вью-модели. Единственный вход — то, что приложение и так знает о
/// цели: bundle id и человекочитаемое имя. Ни экран, ни содержимое окна,
/// ни скриншоты — только эти два поля.
public struct PromptModePolicy: Sendable, Equatable {
    /// Что человек выбрал руками: bundle id → режим. Главнее карты.
    public var overrides: [String: PromptMode]

    public init(overrides: [String: PromptMode] = [:]) {
        self.overrides = overrides
    }

    /// Прецеденс: выбор человека → карта категорий → дефолт.
    public func mode(for target: TargetApplication?) -> PromptMode {
        guard let target else { return ApplicationCategory.unknown.defaultMode }
        if let identifier = target.bundleIdentifier,
           let override = overrides[identifier.lowercased()] {
            return override
        }
        return Self.category(for: target).defaultMode
    }

    /// Категория цели. Публично — настройки показывают её человеку.
    public static func category(for target: TargetApplication?) -> ApplicationCategory {
        guard let target else { return .unknown }
        if let identifier = target.bundleIdentifier?.lowercased(),
           let known = seed[identifier] {
            return known
        }
        // Имя — вторая попытка, а не первая. Bundle id стабилен, а имя
        // локализуется и меняется между версиями; полагаться на него как на
        // основной признак значило бы менять режим от языка системы.
        return categoryByName(target.localizedName)
    }

    /// Сид категорий. Список заведомо неполный — на то и `.unknown` с дословным
    /// дефолтом: незнакомое приложение получает безопасный режим, а не догадку.
    static let seed: [String: ApplicationCategory] = [
        // Терминалы
        "com.apple.terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "dev.warp.warp-stable": .terminal,
        "co.zeit.hyper": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "com.github.wez.wezterm": .terminal,
        "com.mitchellh.ghostty": .terminal,
        // Редакторы кода
        "com.microsoft.vscode": .codeEditor,
        "com.microsoft.vscodeinsiders": .codeEditor,
        "com.todesktop.230313mzl4w4u92": .codeEditor,  // Cursor
        "com.apple.dt.xcode": .codeEditor,
        "com.jetbrains.intellij": .codeEditor,
        "com.jetbrains.pycharm": .codeEditor,
        "com.jetbrains.webstorm": .codeEditor,
        "com.sublimetext.4": .codeEditor,
        "dev.zed.zed": .codeEditor,
        "com.panic.nova": .codeEditor,
        // Заметки
        "com.apple.notes": .notes,
        "notion.id": .notes,
        "md.obsidian": .notes,
        "com.agiletortoise.drafts-osx": .notes,
        "com.bear-writer": .notes,
        // Мессенджеры
        "com.tinyspeck.slackmacgap": .messaging,
        "com.hnc.discord": .messaging,
        "ru.keepcoder.telegram": .messaging,
        "net.whatsapp.whatsapp": .messaging,
        "com.apple.messages": .messaging,
        "us.zoom.xos": .messaging,
        // Почта
        "com.apple.mail": .mail,
        "com.readdle.smartemail-mac": .mail,
        "com.superhuman.mail": .mail,
        // Браузеры
        "com.apple.safari": .browser,
        "com.google.chrome": .browser,
        "org.mozilla.firefox": .browser,
        "company.thebrowser.browser": .browser,  // Arc
        "com.brave.browser": .browser,
        // Дизайн
        "com.figma.desktop": .design,
        "com.bohemiancoding.sketch3": .design,
        "com.adobe.photoshop": .design,
        // Офис
        "com.microsoft.word": .office,
        "com.apple.iwork.pages": .office,
        "com.microsoft.powerpoint": .office,
    ]

    private static func categoryByName(_ name: String?) -> ApplicationCategory {
        guard let name = name?.lowercased(), !name.isEmpty else { return .unknown }
        // Только те слова, которые сами по себе означают категорию. «Code»
        // сюда не входит намеренно: так называется слишком многое.
        if name.contains("terminal") || name.contains("console") { return .terminal }
        if name.contains("mail") { return .mail }
        return .unknown
    }
}
