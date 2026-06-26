import Darwin
import Foundation

@main
struct MediaRuntimeSmokeTests {
    static func main() async throws {
        try testMetadataParserVideo()
        try testMetadataParserCollection()
        try testProgressAndFinalPathParsers()
        try testManagedChildProcessTerminatesProcessGroup()
        print("Media runtime smoke tests passed")
    }

    private static func testMetadataParserVideo() throws {
        let json = """
        {
          "id": "abc123",
          "title": "Sample Short",
          "extractor_key": "Youtube",
          "thumbnail": "https://img.example.test/thumb.jpg",
          "webpage_url": "https://www.youtube.com/shorts/abc123",
          "ext": "mp4",
          "filesize": 4096,
          "formats": [
            { "ext": "mp4", "vcodec": "h264", "filesize": 4096 }
          ]
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://www.youtube.com/shorts/abc123")!
        )

        try assert(metadata.title == "Sample Short", "Video title should parse")
        try assert(metadata.platform == "Youtube", "Extractor key should become platform")
        try assert(metadata.mediaType == .video, "MP4 with video codec should be video")
        try assert(metadata.expectedBytes == 4096, "File size should parse")
        try assert(metadata.defaultFormatPreference == .bestMP4, "Video default format should be MP4")
    }

    private static func testMetadataParserCollection() throws {
        let json = """
        {
          "title": "Carousel",
          "extractor": "Instagram",
          "entries": [
            { "id": "one", "title": "One", "filesize": 1000 },
            { "id": "two", "title": "Two", "filesize_approx": 2000 }
          ]
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://www.instagram.com/p/example/")!
        )

        try assert(metadata.isCollection, "Multiple entries should be collection")
        try assert(metadata.entryCount == 2, "Entry count should parse")
        try assert(metadata.expectedBytes == 2000, "Collection expected bytes should use largest known entry")
        try assert(metadata.defaultFormatPreference == .original, "Collection default format should preserve originals")
    }

    private static func testProgressAndFinalPathParsers() throws {
        let progress = MediaDownloadProgressParser.progress(
            from: "harbor-progress:1024\t4096\t512.5"
        )

        try assert(progress?.bytesWritten == 1024, "Progress bytes should parse")
        try assert(progress?.expectedBytes == 4096, "Progress total should parse")
        try assert(progress?.speedBytesPerSecond == 512.5, "Progress speed should parse")

        let encodedPath = String(
            data: try JSONEncoder().encode("/tmp/Harbor Test.mp4"),
            encoding: .utf8
        )!
        let finalURL = MediaDownloadFinalPathParser.fileURL(from: "harbor-file:\(encodedPath)")
        try assert(finalURL?.path == "/tmp/Harbor Test.mp4", "JSON final file path should parse")
    }

    private static func testManagedChildProcessTerminatesProcessGroup() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("harbor-process-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let childPIDURL = temporaryDirectory.appendingPathComponent("child.pid")
        let command = "sleep 30 & echo $! > '\(childPIDURL.path)'; wait"
        let semaphore = DispatchSemaphore(value: 0)
        let terminationBox = LockedBox<ManagedChildProcessTermination?>(nil)

        let process = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            environment: ProcessInfo.processInfo.environment,
            onStdout: { _ in },
            onStderr: { _ in },
            onTermination: { finishedTermination in
                terminationBox.value = finishedTermination
                semaphore.signal()
            }
        )

        let childPID = try waitForChildPID(at: childPIDURL)
        process.terminate(grace: 0.2)

        let result = semaphore.wait(timeout: .now() + 4)
        try assert(result == .success, "Managed process should terminate promptly")
        try assert(terminationBox.value != nil, "Termination should be reported")

        Thread.sleep(forTimeInterval: 0.4)
        let childStillExists = kill(childPID, 0) == 0
        if childStillExists {
            _ = kill(childPID, SIGKILL)
        }
        try assert(childStillExists == false, "Child process should not survive process-group termination")
    }

    private static func waitForChildPID(at url: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        throw TestFailure("Timed out waiting for child process pid")
    }

    private static func assert(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
