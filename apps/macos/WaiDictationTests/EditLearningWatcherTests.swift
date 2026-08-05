import XCTest

/// Наблюдатель правок: перечитывает поле после вставки и отдаёт правку.
@MainActor
final class EditLearningWatcherTests: XCTestCase {
    /// Подставное поле: значение меняется по ходу теста, как его менял бы человек.
    private final class FakeField: FocusedFieldReading {
        var value: String?
        var captured = 0

        func captureFocusedField() -> FocusedFieldHandle? {
            captured += 1
            return FocusedFieldHandle { [weak self] in self?.value }
        }
    }

    func testПравкаВПолеДоезжаетДоОбучения() async throws {
        let field = FakeField()
        field.value = "Привет! Открой поуст герз."
        let watcher = EditLearningWatcher(
            reader: field,
            checkDelays: [.milliseconds(30), .milliseconds(60)]
        )

        var learned: (String, String)?
        watcher.beginWatching(inserted: "Открой поуст герз.") { original, edited in
            learned = (original, edited)
        }
        // Человек поправил термин, пока наблюдение ждёт.
        field.value = "Привет! Открой Postgres."

        for _ in 0..<100 where learned == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(learned?.0, "Открой поуст герз.")
        XCTAssertEqual(learned?.1, "Открой Postgres.")
    }

    func testПолеБезВставкиНеНаблюдается() {
        let field = FakeField()
        field.value = "Совсем другой текст"
        let watcher = EditLearningWatcher(reader: field, checkDelays: [.milliseconds(20)])

        var fired = false
        watcher.beginWatching(inserted: "Открой поуст герз.") { _, _ in fired = true }

        XCTAssertEqual(field.captured, 1)
        XCTAssertFalse(fired)
    }

    func testНоваяВставкаОтменяетПрежнееНаблюдение() async throws {
        let field = FakeField()
        field.value = "Первый текст"
        let watcher = EditLearningWatcher(
            reader: field,
            checkDelays: [.milliseconds(50)]
        )

        var firstFired = false
        watcher.beginWatching(inserted: "Первый текст") { _, _ in firstFired = true }
        // Новая диктовка до срабатывания первой проверки.
        field.value = "Второй текст"
        watcher.beginWatching(inserted: "Второй текст") { _, _ in }
        // Правка «первого» уже никого не касается.
        field.value = "Пёрвый текст исправленный"

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(firstFired, "Отменённое наблюдение не имеет права учить")
    }
}
