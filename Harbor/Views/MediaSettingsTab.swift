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
                Text("MP4 compatibility selects H.264 video and AAC audio when available. Harbor does not convert unsupported formats.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Applies to new video downloads, including pasted batches. You can change the format for each download. Audio and image downloads are unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
