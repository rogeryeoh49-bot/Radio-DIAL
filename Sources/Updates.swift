import AppKit
import Sparkle

@MainActor final class UpdateController {
    static let shared = UpdateController()
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyInstallsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            if newValue { controller.updater.automaticallyChecksForUpdates = true }
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func start() { controller.startUpdater() }
    func check() { controller.checkForUpdates(nil) }
}
