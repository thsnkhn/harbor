import Darwin
import Foundation

nonisolated enum AppUpdateArchitecture: String {
    case appleSilicon = "arm64"
    case intel = "x86_64"

    static var current: Self {
        #if arch(arm64)
        return .appleSilicon
        #else
        // An Intel app running through Rosetta must move to the native build.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return result == 0 && translated == 1 ? .appleSilicon : .intel
        #endif
    }

    func feedURL(relativeTo legacyFeedURL: URL) -> URL {
        legacyFeedURL.deletingLastPathComponent()
            .appendingPathComponent("appcast-\(rawValue).xml")
    }
}
