import SwiftUI

struct MediaSettingsTab: View {
    @Bindable var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Video Defaults") {
                Picker("Preferred format", selection: $settings.mediaPreferredFormat) {
                    ForEach(MediaPreferredFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Picker("Maximum resolution", selection: $settings.mediaMaximumResolution) {
                    ForEach(MediaMaximumResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                if settings.mediaPreferredFormat == .mp4Compatible {
                    Text("Uses H.264 video and AAC audio when available. Unsupported formats are not converted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Defaults for new video downloads. You can override them for each download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .harborSurface()
    }
}
