import SwiftUI

@main
struct HarborApp: App {
    @NSApplicationDelegateAdaptor(HarborAppDelegate.self) private var appDelegate
    @State private var settings: AppSettingsStore
    @State private var center: DownloadCenter
    @StateObject private var updater: AppUpdater

    init() {
        let settings = AppSettingsStore()
        _settings = State(initialValue: settings)
        _center = State(initialValue: DownloadCenter(settings: settings))
        _updater = StateObject(
            wrappedValue: PreviewRuntime.isActive ? AppUpdater.preview(canCheckForUpdates: false) : AppUpdater()
        )
    }

    var body: some Scene {
        WindowGroup("Harbor", id: "main") {
            RootView(center: center, settings: settings)
                .frame(minWidth: 1_040, minHeight: 680)
                .task {
                    appDelegate.center = center

                    guard PreviewRuntime.isActive == false else {
                        return
                    }

                    center.installExternalOpenHandlerIfNeeded()
                    await center.initializeIfNeeded()
                }
        }
        .defaultSize(width: 1_320, height: 820)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            DownloadCommands(center: center, updater: updater)
        }

        Settings {
            SettingsView(settings: settings, updater: updater)
                .frame(minWidth: 480, idealWidth: 500, minHeight: 340)
                .padding(20)
        }
        .windowResizability(.contentSize)
    }
}
