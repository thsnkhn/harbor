import Foundation

struct Aria2BinaryResolver {
    struct Resolution: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            case bundled
            case environmentOverride
            case standardLocation
            case pathLookup

            nonisolated var displayName: String {
                switch self {
                case .bundled:
                    "Bundled with Harbor"
                case .environmentOverride:
                    "ARIA2_NEXT_PATH override"
                case .standardLocation:
                    "System installation"
                case .pathLookup:
                    "PATH lookup"
                }
            }
        }

        let url: URL
        let source: Source
    }

    struct Context {
        nonisolated(unsafe) let fileManager: FileManager
        let environment: [String: String]
        let bundledResourceRoots: [URL]
        let candidatePaths: [String]
        let pathLookup: @Sendable () -> URL?

        nonisolated init(
            fileManager: FileManager = .default,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            bundledResourceRoots: [URL] = HarborApplicationSupport.bundledResourceRoots(),
            candidatePaths: [String] = Self.defaultCandidatePaths,
            pathLookup: @escaping @Sendable () -> URL? = Aria2BinaryResolver.resolveFromPATH
        ) {
            self.fileManager = fileManager
            self.environment = environment
            self.bundledResourceRoots = bundledResourceRoots
            self.candidatePaths = candidatePaths
            self.pathLookup = pathLookup
        }

        nonisolated private static let defaultCandidatePaths = [
            "/opt/homebrew/bin/aria2-next",
            "/usr/local/bin/aria2-next",
            "/opt/local/bin/aria2-next"
        ]

    }

    nonisolated static let installHint = "Harbor couldn’t find Aria2 Next. Reinstall the app, or set `ARIA2_NEXT_PATH` to an Aria2 Next executable."

    nonisolated static func resolveBinaryURL() -> URL? {
        resolveBinary()?.url
    }

    nonisolated static func resolveBinary(using context: Context = Context()) -> Resolution? {
        if let bundledBinary = resolveBundledRuntime(using: context) {
            return bundledBinary
        }

        if let path = context.environment["ARIA2_NEXT_PATH"],
           context.fileManager.isExecutableFile(atPath: path) {
            return Resolution(
                url: URL(fileURLWithPath: path),
                source: .environmentOverride
            )
        }

        for path in context.candidatePaths where context.fileManager.isExecutableFile(atPath: path) {
            return Resolution(
                url: URL(fileURLWithPath: path),
                source: .standardLocation
            )
        }

        guard let pathLookupURL = context.pathLookup() else {
            return nil
        }

        return Resolution(
            url: pathLookupURL,
            source: .pathLookup
        )
    }

    private nonisolated static func resolveBundledRuntime(using context: Context) -> Resolution? {
        for root in context.bundledResourceRoots {
            let candidateURLs = [
                root
                    .appendingPathComponent("TorrentRuntime", isDirectory: true)
                    .appendingPathComponent(HarborApplicationSupport.architectureName, isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("aria2-next", isDirectory: false),
                root
                    .appendingPathComponent("TorrentRuntime", isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("aria2-next", isDirectory: false)
            ]

            for binaryURL in candidateURLs where context.fileManager.isExecutableFile(atPath: binaryURL.path) {
                return Resolution(url: binaryURL, source: .bundled)
            }
        }

        return nil
    }

    private nonisolated static func resolveFromPATH() -> URL? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["aria2-next"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            path.isEmpty == false else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

}
