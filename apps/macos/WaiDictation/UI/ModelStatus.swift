import Foundation
import LocalASR

/// Что человек видит про модель — в любом её состоянии и на обоих экранах.
///
/// Один тип на онбординг и настройки намеренно: раньше эти шесть состояний были
/// расписаны в двух местах разными словами, и любое изменение приходилось
/// вносить дважды. Второе место рано или поздно отставало.
struct ModelStatus: Equatable {
    enum Tone: Equatable {
        case neutral
        case success
        case failure
    }

    enum Action: Hashable {
        case install
        case retry
        case repair
        case cancel
        case delete

        /// Кнопка называет настоящий объём: полный для чистой установки и
        /// только остаток — когда после обновления доскачивается подсказчик.
        func title(downloadMegabytes: Int) -> String {
            switch self {
            case .install: return "Download model — \(downloadMegabytes) MB"
            case .retry: return "Try again"
            case .repair: return "Redownload model — \(downloadMegabytes) MB"
            case .cancel: return "Cancel download"
            case .delete: return "Delete model"
            }
        }

        /// Подсказка для VoiceOver: что случится по нажатию.
        func hint(downloadMegabytes: Int) -> String {
            switch self {
            case .install: return "Downloads about \(downloadMegabytes) MB. This is the app's only download."
            case .retry: return "Restarts the model download from the beginning."
            case .repair: return "Downloads and verifies a fresh copy of the model. The damaged copy is not used."
            case .cancel: return "Stops the download and deletes the partially downloaded files."
            case .delete: return "Frees up disk space. Dictation stops working until the model is downloaded again."
            }
        }
    }

    /// Где показывается — от этого зависит только набор кнопок.
    enum Place {
        case onboarding
        case settings
    }

    var title: String
    var detail: String?
    /// Доля выполнения, если она осмысленна.
    var progress: Double?
    /// Подпись к индикатору — она же значение для VoiceOver.
    var progressLabel: String?
    var actions: [Action]
    var tone: Tone
    /// Что объявить VoiceOver при смене состояния.
    var announcement: String
    /// Сколько скачает кнопка install/repair — полный объём или остаток.
    var downloadMegabytes: Int = 586

    func title(for action: Action) -> String {
        action.title(downloadMegabytes: downloadMegabytes)
    }

    func hint(for action: Action) -> String {
        action.hint(downloadMegabytes: downloadMegabytes)
    }

    static func make(
        state: ModelState,
        isPreparingEngine: Bool,
        preparation: EnginePreparationState? = nil,
        place: Place,
        downloadMegabytes: Int = 586
    ) -> ModelStatus {
        var status = makeStatus(
            state: state,
            isPreparingEngine: isPreparingEngine,
            preparation: preparation,
            place: place,
            downloadMegabytes: downloadMegabytes
        )
        status.downloadMegabytes = downloadMegabytes
        return status
    }

    private static func makeStatus(
        state: ModelState,
        isPreparingEngine: Bool,
        preparation: EnginePreparationState?,
        place: Place,
        downloadMegabytes: Int
    ) -> ModelStatus {
        switch state {
        case .notInstalled:
            return ModelStatus(
                title: "Model not installed",
                detail: "\(downloadMegabytes) MB from the Hugging Face CDN; a GitHub mirror if it's unavailable. After verification, recognition works without the network.",
                progress: nil,
                progressLabel: nil,
                actions: [.install],
                tone: .neutral,
                announcement: "Model not installed"
            )

        case let .downloading(received, total):
            let label = "\(megabytes(received)) of \(megabytes(total)) MB"
            return ModelStatus(
                title: "Downloading model…",
                detail: "You can keep working — the download won't be interrupted.",
                progress: state.progress,
                progressLabel: label,
                actions: [.cancel],
                tone: .neutral,
                announcement: "Downloading model, \(label)"
            )

        case let .verifying(checked, total):
            let label = "File \(checked) of \(total)"
            return ModelStatus(
                title: "Verifying download…",
                detail: "Checking every file against its checksum.",
                progress: state.progress,
                progressLabel: label,
                actions: [],
                tone: .neutral,
                announcement: "Verifying download, \(label)"
            )

        case .ready:
            return ModelStatus(
                title: "Model ready",
                // Пока идёт первая загрузка в нейромодуль, человек видит
                // «готова», но диктовка ещё подумает. Молчать об этом — значит
                // получить жалобу на медленный первый раз.
                // Живые секунды, а не «обычно 20–40»: ожидание с идущим
                // счётчиком читается как работа, а без него — как зависание.
                detail: isPreparingEngine
                    ? (preparation?.title ?? "Preparing for this Mac — usually 20–40 seconds, and only once.")
                    : nil,
                progress: nil,
                progressLabel: nil,
                actions: place == .settings ? [.delete] : [],
                tone: .success,
                announcement: isPreparingEngine ? "Model ready, preparing for first use" : "Model ready"
            )

        case let .repairRequired(detail):
            let reason = message(for: .repairRequired(detail))
            return ModelStatus(
                title: "Model needs repair",
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [.repair],
                tone: .failure,
                announcement: "Model needs repair. \(reason)"
            )

        case let .failed(error):
            let reason = message(for: error)
            let requiresRepair: Bool
            if case .repairRequired = error {
                requiresRepair = true
            } else {
                requiresRepair = false
            }
            return ModelStatus(
                title: requiresRepair ? "Model needs repair" : "Model installation failed",
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [requiresRepair ? .repair : .retry],
                tone: .failure,
                announcement: requiresRepair
                    ? "Model needs repair. \(reason)"
                    : "Model installation failed. \(reason)"
            )

        case .deleting:
            return ModelStatus(
                title: "Deleting model…",
                detail: nil,
                progress: nil,
                progressLabel: nil,
                actions: [],
                tone: .neutral,
                announcement: "Deleting model"
            )
        }
    }

    /// Ошибка человеческими словами.
    ///
    /// Раньше сюда печаталось `String(describing:)` — то есть человек видел
    /// `notEnoughDiskSpace(requiredBytes: 594000000, availableBytes: 1200000)`
    /// и должен был сам догадаться, что на диске нет места.
    static func message(for error: ModelStoreError) -> String {
        switch error {
        case let .notEnoughDiskSpace(required, available):
            return """
                Not enough disk space: \(megabytes(required)) MB needed, \
                \(megabytes(available)) MB free.
                """
        case let .download(detail):
            return "Download failed: \(detail)"
        case let .verification(detail):
            return "The download didn't match its checksums: \(detail)"
        case let .install(detail):
            return "Couldn't put the files in place: \(detail)"
        case let .repairRequired(detail):
            return "The model is damaged or incomplete: \(detail). Redownload it explicitly."
        case let .manifest(detail):
            return "The model's file list is corrupted: \(detail)"
        case let .importSource(detail):
            return "That folder didn't work: \(detail)"
        case .cancelled:
            return "Download cancelled."
        }
    }

    /// Байты в мегабайты — так, как их считает Finder.
    private static func megabytes(_ bytes: Int64) -> Int {
        Int(bytes / 1_000_000)
    }
}
