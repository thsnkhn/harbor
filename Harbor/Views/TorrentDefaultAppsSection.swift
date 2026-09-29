import SwiftUI

struct TorrentDefaultAppsSection: View {
    @State private var controller = TorrentDefaultAppsController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section("Default App") {
            ForEach(TorrentAssociation.allCases) { association in
                let isDefault = controller.isDefault(for: association)
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(isDefault
                             ? String(localized: "Harbor is the default")
                             : controller.applications[association]?.name ?? String(localized: "No default app"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("settings.torrents.defaultApp.\(association.rawValue).status")

                        if isDefault == false {
                            Button("Make Default") {
                                Task { await controller.makeDefault(for: association) }
                            }
                            .disabled(controller.updatingAssociation != nil)
                            .accessibilityIdentifier("settings.torrents.defaultApp.\(association.rawValue).button")
                        }
                        if controller.updatingAssociation == association {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } label: {
                    Text(association.title)
                }

                if let error = controller.errors[association] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { controller.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.refresh() }
        }
    }
}
