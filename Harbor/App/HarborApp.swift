import SwiftUI

@main
struct HarborApp: App {
    @NSApplicationDelegateAdaptor(HarborAppDelegate.self) private var appDelegate
    @State private var settings: AppSettingsStore
    @State private var center: DownloadCenter
    @StateObject private var updater: AppUpdater

    init() {
        let settings = AppSettingsStore(userDefaults: HarborTestRuntime.userDefaults)
        _settings = State(initialValue: settings)
        _center = State(
            initialValue: DownloadCenter(
                settings: settings,
                directRecoveryDirectoryURL: settings.directDownloadRecoveryURL,
                completedHandoffDirectoryURL: settings.completedHandoffStagingURL,
                storageLocations: DownloadStorageLocations()
            )
        )
        _updater = StateObject(wrappedValue: AppUpdater(
            checksForUpdatesOnLaunch: HarborTestRuntime.disablesAutomaticUpdateCheck == false,
            startsUpdater: HarborApplicationSupport.isRunningUnitTests == false
        ))
    }

    var body: some Scene {
        WindowGroup("Harbor", id: "main") {
            RootView(center: center, settings: settings)
                .modifier(HarborAppearance(appearance: settings.appearance))
                .frame(minWidth: 1_040, minHeight: 680)
                .defaultAppStorage(HarborTestRuntime.userDefaults)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .task {
                    appDelegate.center = center

                    guard HarborApplicationSupport.isRunningUnitTests == false else {
                        return
                    }

                    center.installExternalOpenHandlerIfNeeded()
                    appDelegate.dockProgress.start(center: center)
                    await center.initializeIfNeeded()
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1_040, height: 680)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            DownloadCommands(center: center, updater: updater)
        }

        Settings {
            SettingsView(settings: settings, updater: updater)
                .modifier(HarborAppearance(appearance: settings.appearance))
                .defaultAppStorage(HarborTestRuntime.userDefaults)
        }
        .defaultSize(width: 840, height: 720)
        .windowResizability(.contentMinSize)
    }
}
