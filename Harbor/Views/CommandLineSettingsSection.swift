import SwiftUI

struct CommandLineSettingsSection: View {
    let settings: AppSettingsStore
    @State private var message: String?
    @State private var showsSkills = false
    private let installer = AgentSkillInstaller()

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Allow CLI access", isOn: $settings.cliAccessEnabled)
                .accessibilityIdentifier("settings.cli.enabled")
            HStack {
                Button("Install Command") {
                    do {
                        try installer.installCommand(from: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/harbor"))
                        message = "Installed at \(installer.command.path)"
                    } catch { message = error.localizedDescription }
                }
                Button("Install Agent Skill…") { showsSkills = true }
                    .accessibilityIdentifier("settings.cli.skills")
            }
            if let message = settings.cliStatus ?? message {
                Text(message).font(.callout).textSelection(.enabled)
            }
        } header: {
            Text("Command Line")
        } footer: {
            Text("Local commands can read and change downloads. Moving files to Trash requires an explicit flag.")
        }
        .sheet(isPresented: $showsSkills) { AgentSkillInstallSheet() }
    }
}

private struct AgentSkillInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [AgentSkillInstaller.Target] = []
    @State private var selected: Set<String> = []
    @State private var results: [String: String] = [:]
    private let installer = AgentSkillInstaller()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Harbor Skill").font(.title2.bold())
            ForEach(targets) { target in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(target.name, isOn: Binding(get: { selected.contains(target.id) }, set: {
                        if $0 { selected.insert(target.id) } else { selected.remove(target.id) }
                    }))
                    Text(target.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let result = results[target.id] { Text(result).font(.caption) }
                    else if target.status != "not installed" { Text(target.status).font(.caption) }
                }
            }
            Text("Restart your agent to load the skill. CLI access stays under your control.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Remove Installed Skills") { perform(remove: true) }.disabled(selected.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { perform(remove: false) }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }
        .padding(24).frame(width: 600)
        .onAppear {
            targets = installer.targets()
            selected = Set(targets.filter { ["not installed", "current", "update available"].contains($0.status) }.map(\.id))
        }
    }
    private func perform(remove: Bool) {
        for target in targets where selected.contains(target.id) {
            do {
                if remove { try installer.uninstallSkill(at: target) }
                else { try installer.installSkill(at: target) }
                results[target.id] = remove ? "Removed" : "Installed"
            } catch { results[target.id] = error.localizedDescription }
        }
        targets = installer.targets()
    }
}
