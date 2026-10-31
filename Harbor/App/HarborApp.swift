import SwiftUI

@main
struct HarborApp: App {
    @NSApplicationDelegateAdaptor(HarborAppDelegate.self) private var appDelegate
    @State private var settings: AppSettingsStore
    @State private var center: DownloadCenter
    @State private var commandLine: CLIController
    @StateObject private var updater: AppUpdater

    init() {
        let settings = AppSettingsStore(userDefaults: HarborTestRuntime.userDefaults)
        _settings = State(initialValue: settings)
        let center = DownloadCenter(
            settings: settings,
            directRecoveryDirectoryURL: settings.directDownloadRecoveryURL,
            completedHandoffDirectoryURL: settings.completedHandoffStagingURL,
            storageLocations: DownloadStorageLocations()
        )
        _center = State(initialValue: center)
        let commandLine = CLIController(center: center, settings: settings)
        _commandLine = State(initialValue: commandLine)
        _updater = StateObject(wrappedValue: AppUpdater(
            checksForUpdatesOnLaunch: HarborTestRuntime.disablesAutomaticUpdateCheck == false,
            startsUpdater: HarborApplicationSupport.isRunningUnitTests == false
        ))
        appDelegate.center = center
        appDelegate.startServices = {
            commandLine.updateAccess()
            center.installExternalOpenHandlerIfNeeded()
            AgentSkillInstaller().updateOwnedCommand(from: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/harbor"))
            Task { await center.initializeIfNeeded() }
        }
    }

    var body: some Scene {
        WindowGroup("Harbor", id: "main") {
            RootView(center: center, settings: settings)
                .modifier(HarborAppearance(appearance: settings.appearance))
                .frame(minWidth: 1_040, minHeight: 680)
                .defaultAppStorage(HarborTestRuntime.userDefaults)
                .background(CLISettingsBridge(controller: commandLine))
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

private struct CLISettingsBridge: View {
    let controller: CLIController
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            controller.showSettings = { pane in
                HarborTestRuntime.userDefaults.set(pane, forKey: "settings.selectedPane")
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
