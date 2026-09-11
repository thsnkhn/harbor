import Foundation

struct MediaRuntimeResolution: Equatable, Sendable {
    let ytDlpURL: URL
    let denoURL: URL
    let ffmpegURL: URL
    let ffprobeURL: URL
}

struct MediaRuntimeResolver {
    struct Context {
        nonisolated(unsafe) let fileManager: FileManager
        let environment: [String: String]
        let bundledResourceRoots: [URL]
        let candidateDirectories: [String]

        nonisolated init(
            fileManager: FileManager = .default,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            bundledResourceRoots: [URL] = HarborApplicationSupport.bundledResourceRoots(),
            candidateDirectories: [String] = Self.defaultCandidateDirectories
        ) {
            self.fileManager = fileManager
            self.environment = environment
            self.bundledResourceRoots = bundledResourceRoots
            self.candidateDirectories = candidateDirectories
        }

        nonisolated private static let defaultCandidateDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin"
        ]

    }

    nonisolated static let installHint = "Harbor couldn’t find its bundled media engine. Reinstall the app, or set `YTDLP_PATH`, `DENO_PATH`, `FFMPEG_PATH`, and `FFPROBE_PATH` to compatible binaries."

    nonisolated static func resolveRuntime(using context: Context = Context()) -> MediaRuntimeResolution? {
        if let bundledRuntime = resolveBundledRuntime(using: context) {
            return bundledRuntime
        }

        if let overrideRuntime = resolveEnvironmentOverride(using: context) {
            return overrideRuntime
        }

        return resolveStandardRuntime(using: context)
    }

    private nonisolated static func resolveBundledRuntime(using context: Context) -> MediaRuntimeResolution? {
        resolveRuntime(in: context.bundledResourceRoots.map { root in
            root.appendingPathComponent("MediaRuntime", isDirectory: true)
                .appendingPathComponent(HarborApplicationSupport.architectureName, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
        }, fileManager: context.fileManager)
    }

    private nonisolated static func resolveEnvironmentOverride(using context: Context) -> MediaRuntimeResolution? {
        guard let ytDlpPath = context.environment["YTDLP_PATH"],
              let denoPath = context.environment["DENO_PATH"],
              let ffmpegPath = context.environment["FFMPEG_PATH"],
              let ffprobePath = context.environment["FFPROBE_PATH"] else {
            return nil
        }

        let ytDlpURL = URL(fileURLWithPath: ytDlpPath)
        let denoURL = URL(fileURLWithPath: denoPath)
        let ffmpegURL = URL(fileURLWithPath: ffmpegPath)
        let ffprobeURL = URL(fileURLWithPath: ffprobePath)

        guard context.fileManager.isExecutableFile(atPath: ytDlpURL.path),
              context.fileManager.isExecutableFile(atPath: denoURL.path),
              context.fileManager.isExecutableFile(atPath: ffmpegURL.path),
              context.fileManager.isExecutableFile(atPath: ffprobeURL.path) else {
            return nil
        }

        return MediaRuntimeResolution(
            ytDlpURL: ytDlpURL,
            denoURL: denoURL,
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL
        )
    }

    private nonisolated static func resolveStandardRuntime(using context: Context) -> MediaRuntimeResolution? {
        resolveRuntime(in: context.candidateDirectories.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }, fileManager: context.fileManager)
    }

    private nonisolated static func resolveRuntime(
        in directories: [URL],
        fileManager: FileManager
    ) -> MediaRuntimeResolution? {
        for directory in directories {
            if let resolution = resolution(in: directory, fileManager: fileManager) {
                return resolution
            }
        }
        return nil
    }

    private nonisolated static func resolution(
        in binDirectory: URL,
        fileManager: FileManager
    ) -> MediaRuntimeResolution? {
        let ytDlpURL = binDirectory.appendingPathComponent("yt-dlp")
        let denoURL = binDirectory.appendingPathComponent("deno")
        let ffmpegURL = binDirectory.appendingPathComponent("ffmpeg")
        let ffprobeURL = binDirectory.appendingPathComponent("ffprobe")

        guard fileManager.isExecutableFile(atPath: ytDlpURL.path),
              fileManager.isExecutableFile(atPath: denoURL.path),
              fileManager.isExecutableFile(atPath: ffmpegURL.path),
              fileManager.isExecutableFile(atPath: ffprobeURL.path) else {
            return nil
        }

        return MediaRuntimeResolution(
            ytDlpURL: ytDlpURL,
            denoURL: denoURL,
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL
        )
    }

}
