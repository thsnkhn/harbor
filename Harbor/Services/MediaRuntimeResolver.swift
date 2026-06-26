import Foundation

struct MediaRuntimeResolution: Equatable, Sendable {
    let ytDlpURL: URL
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
            bundledResourceRoots: [URL] = Self.defaultBundledResourceRoots(),
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

        nonisolated private static func defaultBundledResourceRoots() -> [URL] {
            var roots: [URL] = []
            var seenPaths = Set<String>()

            for resourceURL in [
                Bundle.main.resourceURL,
                Bundle(for: BundleToken.self).resourceURL
            ].compactMap({ $0 }) {
                guard seenPaths.insert(resourceURL.path).inserted else {
                    continue
                }

                roots.append(resourceURL)
            }

            return roots
        }
    }

    nonisolated static let installHint = "Harbor couldn’t find its bundled media engine. Reinstall the app, or set `YTDLP_PATH`, `FFMPEG_PATH`, and `FFPROBE_PATH` to compatible binaries."

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
        for root in context.bundledResourceRoots {
            let binDirectory = root
                .appendingPathComponent("MediaRuntime", isDirectory: true)
                .appendingPathComponent(runtimeArchitectureName, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)

            if let resolution = resolution(in: binDirectory, fileManager: context.fileManager) {
                return resolution
            }
        }

        return nil
    }

    private nonisolated static func resolveEnvironmentOverride(using context: Context) -> MediaRuntimeResolution? {
        guard let ytDlpPath = context.environment["YTDLP_PATH"],
              let ffmpegPath = context.environment["FFMPEG_PATH"],
              let ffprobePath = context.environment["FFPROBE_PATH"] else {
            return nil
        }

        let ytDlpURL = URL(fileURLWithPath: ytDlpPath)
        let ffmpegURL = URL(fileURLWithPath: ffmpegPath)
        let ffprobeURL = URL(fileURLWithPath: ffprobePath)

        guard context.fileManager.isExecutableFile(atPath: ytDlpURL.path),
              context.fileManager.isExecutableFile(atPath: ffmpegURL.path),
              context.fileManager.isExecutableFile(atPath: ffprobeURL.path) else {
            return nil
        }

        return MediaRuntimeResolution(
            ytDlpURL: ytDlpURL,
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL
        )
    }

    private nonisolated static func resolveStandardRuntime(using context: Context) -> MediaRuntimeResolution? {
        for path in context.candidateDirectories {
            let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            if let resolution = resolution(in: directoryURL, fileManager: context.fileManager) {
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
        let ffmpegURL = binDirectory.appendingPathComponent("ffmpeg")
        let ffprobeURL = binDirectory.appendingPathComponent("ffprobe")

        guard fileManager.isExecutableFile(atPath: ytDlpURL.path),
              fileManager.isExecutableFile(atPath: ffmpegURL.path),
              fileManager.isExecutableFile(atPath: ffprobeURL.path) else {
            return nil
        }

        return MediaRuntimeResolution(
            ytDlpURL: ytDlpURL,
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL
        )
    }

    private nonisolated static var runtimeArchitectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }
}

private final class BundleToken: NSObject {}
