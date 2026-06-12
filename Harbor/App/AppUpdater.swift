import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var automaticallyChecksForUpdates: Bool
    @Published private(set) var canCheckForUpdates: Bool

    private let currentBundle: Bundle
    private let previewVersionLabel: String?
    private let updaterController: SPUStandardUpdaterController?
    private var didCheckForUpdatesOnLaunch = false
    private var observations: [NSKeyValueObservation] = []

    init(bundle: Bundle = .main) {
        self.currentBundle = bundle
        self.previewVersionLabel = nil

        guard PreviewRuntime.isActive == false else {
            self.updaterController = nil
            self.automaticallyChecksForUpdates = false
            self.canCheckForUpdates = false
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        self.updaterController = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.canCheckForUpdates = controller.updater.canCheckForUpdates

        installObservers(for: controller.updater)
        checkForUpdatesOnLaunchIfAllowed()
    }

    private init(
        previewVersionLabel: String,
        automaticallyChecksForUpdates: Bool,
        canCheckForUpdates: Bool
    ) {
        self.currentBundle = .main
        self.previewVersionLabel = previewVersionLabel
        self.updaterController = nil
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.canCheckForUpdates = canCheckForUpdates
    }

    var currentVersionLabel: String {
        if let previewVersionLabel {
            return previewVersionLabel
        }

        return Self.versionLabel(bundle: currentBundle)
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

    static func preview(
        automaticallyChecksForUpdates: Bool = true,
        canCheckForUpdates: Bool = true
    ) -> AppUpdater {
        AppUpdater(
            previewVersionLabel: "1.0 (1)",
            automaticallyChecksForUpdates: automaticallyChecksForUpdates,
            canCheckForUpdates: canCheckForUpdates
        )
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
