import XCTest
@testable import DictationCore

/// Режим по приложению-получателю.
final class PromptModeTests: XCTestCase {
    private func target(_ bundleIdentifier: String?, name: String? = nil) -> TargetApplication {
        TargetApplication(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 42,
            localizedName: name
        )
    }

    // MARK: - Категории

    func testTerminalsAndEditorsAreVerbatim() {
        let policy = PromptModePolicy()
        for identifier in [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "com.microsoft.VSCode",
            "com.apple.dt.Xcode",
            "dev.zed.Zed",
        ] {
            XCTAssertEqual(policy.mode(for: target(identifier)), .verbatim, identifier)
        }
    }

    func testChatsMailAndNotesAreProse() {
        let policy = PromptModePolicy()
        for identifier in [
            "com.tinyspeck.slackmacgap",
            "com.apple.mail",
            "com.apple.Notes",
            "md.obsidian",
            "com.apple.Safari",
        ] {
            XCTAssertEqual(policy.mode(for: target(identifier)), .prose, identifier)
        }
    }

    /// Регистр bundle id не должен решать: система отдаёт его как есть.
    func testBundleIdentifierIsMatchedCaseInsensitively() {
        let policy = PromptModePolicy()
        XCTAssertEqual(policy.mode(for: target("COM.APPLE.TERMINAL")), .verbatim)
        XCTAssertEqual(policy.mode(for: target("com.apple.terminal")), .verbatim)
    }

    // MARK: - Дефолт

    /// **Незнакомое приложение — дословно.**
    ///
    /// Ошибка в эту сторону оставит лишнее слово. Ошибка в другую тихо
    /// перепишет команду в терминале, который мы просто не узнали.
    func testUnknownApplicationDefaultsToVerbatim() {
        let policy = PromptModePolicy()
        XCTAssertEqual(policy.mode(for: target("com.example.something")), .verbatim)
        XCTAssertEqual(policy.mode(for: target(nil)), .verbatim)
        XCTAssertEqual(policy.mode(for: nil), .verbatim)
    }

    func testUnknownCategoryDefaultIsVerbatim() {
        XCTAssertEqual(ApplicationCategory.unknown.defaultMode, .verbatim)
    }

    // MARK: - Прецеденс

    func testUserOverrideBeatsTheMap() {
        let policy = PromptModePolicy(overrides: ["com.apple.terminal": .prose])
        XCTAssertEqual(
            policy.mode(for: target("com.apple.Terminal")), .prose,
            "выбор человека главнее нашей карты"
        )
    }

    func testUserOverrideCanForceVerbatimInAChat() {
        let policy = PromptModePolicy(overrides: ["com.tinyspeck.slackmacgap": .verbatim])
        XCTAssertEqual(policy.mode(for: target("com.tinyspeck.slackmacgap")), .verbatim)
    }

    func testOverrideForOneApplicationDoesNotLeakToOthers() {
        let policy = PromptModePolicy(overrides: ["com.apple.terminal": .prose])
        XCTAssertEqual(policy.mode(for: target("com.googlecode.iterm2")), .verbatim)
    }

    // MARK: - Имя как запасной признак

    /// Имя — вторая попытка, а не первая: bundle id стабилен, а имя
    /// локализуется и меняется между версиями.
    func testNameIsOnlyAFallback() {
        let policy = PromptModePolicy()
        XCTAssertEqual(
            policy.mode(for: target("com.unknown.thing", name: "Some Terminal")), .verbatim
        )
        // Знакомый id решает сам, что бы ни было в имени.
        XCTAssertEqual(
            policy.mode(for: target("com.apple.Notes", name: "Terminal")), .prose,
            "bundle id знаком — имя не спрашиваем"
        )
    }

    /// «Code» намеренно не признак: так называется слишком многое.
    func testGenericWordsInNamesDoNotDecide() {
        let policy = PromptModePolicy()
        XCTAssertEqual(PromptModePolicy.category(for: target("x.y", name: "Code Notes")), .unknown)
        XCTAssertEqual(policy.mode(for: target("x.y", name: "Code Notes")), .verbatim)
    }

    // MARK: - Карта

    func testCategoryIsExposedForSettings() {
        XCTAssertEqual(PromptModePolicy.category(for: target("com.apple.Terminal")), .terminal)
        XCTAssertEqual(PromptModePolicy.category(for: target("com.apple.mail")), .mail)
        XCTAssertEqual(PromptModePolicy.category(for: target("com.example.nope")), .unknown)
    }

    /// В карте только строчные ключи — иначе поиск по lowercased() промахнётся
    /// молча, и приложение просто получит не тот режим.
    func testSeedKeysAreAllLowercased() {
        for key in PromptModePolicy.seed.keys {
            XCTAssertEqual(key, key.lowercased(), "ключ карты обязан быть в нижнем регистре: \(key)")
        }
    }

    func testEveryCategoryHasAMode() {
        for category in ApplicationCategory.allCases {
            XCTAssertTrue(PromptMode.allCases.contains(category.defaultMode))
        }
    }
}
