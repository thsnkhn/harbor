import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var automaticallyChecksForUpdates: Bool
    @Published private(set) var canCheckForUpdates: Bool

    private let currentBundle: Bundle
    private var updaterController: SPUStandardUpdaterController?
    private var didCheckForUpdatesOnLaunch = false
    private var observations: [NSKeyValueObservation] = []

    init(
        bundle: Bundle = .main,
        checksForUpdatesOnLaunch: Bool = true,
        startsUpdater: Bool = true
    ) {
        self.currentBundle = bundle
        self.automaticallyChecksForUpdates = false
        self.canCheckForUpdates = false
        super.init()

        guard startsUpdater else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        self.updaterController = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.canCheckForUpdates = controller.updater.canCheckForUpdates

        installObservers(for: controller.updater)
        if checksForUpdatesOnLaunch {
            checkForUpdatesOnLaunchIfAllowed()
        }
    }

    var currentVersionLabel: String {
        Self.versionLabel(bundle: currentBundle)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let value = currentBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let legacyURL = URL(string: value) else { return nil }
        return AppUpdateArchitecture.current.feedURL(relativeTo: legacyURL).absoluteString
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func checkForUpdatesOnLaunchIfAllowed() {
        guard didCheckForUpdatesOnLaunch == false,
              let updater = updaterController?.updater,
              updater.automaticallyChecksForUpdates else {
            return
        }

        didCheckForUpdatesOnLaunch = true
        updater.checkForUpdatesInBackground()
    }

    func setAutomaticallyChecksForUpdates(_ newValue: Bool) {
        automaticallyChecksForUpdates = newValue
        updaterController?.updater.automaticallyChecksForUpdates = newValue
    }

    private func installObservers(for updater: SPUUpdater) {
        let canCheckObserver = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] observedUpdater, _ in
            DispatchQueue.main.async {
                self?.canCheckForUpdates = observedUpdater.canCheckForUpdates
            }
        }

        let autoCheckObserver = updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] observedUpdater, _ in
            DispatchQueue.main.async {
                self?.automaticallyChecksForUpdates = observedUpdater.automaticallyChecksForUpdates
            }
        }

        observations = [canCheckObserver, autoCheckObserver]
    }

    private static func versionLabel(bundle: Bundle) -> String {
        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Unknown"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""

        if build.isEmpty || build == shortVersion {
            return shortVersion
        }

        return "\(shortVersion) (\(build))"
    }
}
