import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Harbor

@MainActor
final class TorrentCheckingTests: XCTestCase {
    func testSingleFileValidCorruptShortAndOversizedWithoutWrites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("renamed.bin")
        let metainfo = torrent(payloads: [Data("abcd".utf8)], pieceLength: 4)
        for (text, expected) in [("abcd", TorrentCheckState.complete), ("abce", .incomplete), ("ab", .incomplete), ("abcdTAIL", .incomplete)] {
            let data = Data(text.utf8)
            try data.write(to: file)
            let before = try FileManager.default.attributesOfItem(atPath: file.path)
            let result = try await check(metainfo, file)
            XCTAssertEqual(result.state, expected)
            XCTAssertEqual(try Data(contentsOf: file), data)
            let after = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["renamed.bin"])
        }
    }

    func testCrossBoundarySelectedFileNeedsNeighborBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metainfo = torrent(payloads: [Data("abc".utf8), Data("def".utf8)], pieceLength: 4, multi: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("file0"))
        let preview = try TorrentMetainfoParser.preview(from: metainfo)
        let selection = TorrentFileSelection.partial(selectedIndexes: [1], in: preview)
        var result = try await check(metainfo, root, selection: selection)
        XCTAssertEqual(result.state, .incomplete)
        XCTAssertEqual(result.verifiedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file1").path))
        try Data("dXX".utf8).write(to: root.appendingPathComponent("file1"))
        result = try await check(metainfo, root, selection: selection)
        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.verifiedBytes, 3)
        XCTAssertEqual(result.totalBytes, 3)
        XCTAssertFalse(result.isFullTorrentComplete)
        try Data("def".utf8).write(to: root.appendingPathComponent("file1"))
        result = try await check(metainfo, root, selection: selection)
        XCTAssertTrue(result.isFullTorrentComplete)
    }

    func testVanishedSingleFileIsIncompleteAndNotRecreated() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vanished.bin")
        let result = try await check(torrent(payloads: [Data("abcd".utf8)], pieceLength: 4), file)
        XCTAssertEqual(result.state, .incomplete)
        XCTAssertEqual(result.verifiedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCheckStatePersistsWithoutChangingStatusEncoding() throws {
        let item = DownloadItem(sourceURL: URL(fileURLWithPath: "/tmp/source.torrent"),
            sourceKind: .torrentFile, backend: .aria2, preferredFilename: nil,
            destinationFolderPath: "/tmp", status: .paused,
            torrentCheckState: .checking, torrentExistingDataPath: "/tmp/payload")
        item.torrentCheckProgress = 0.5
        let data = try JSONEncoder().encode(item.makeRecord())
        let record = try JSONDecoder().decode(DownloadRecord.self, from: data)
        let restored = DownloadItem(record: record)
        XCTAssertEqual(restored.torrentCheckState, .checking)
        XCTAssertEqual(restored.torrentExistingDataPath, "/tmp/payload")
        XCTAssertNil(restored.torrentCheckProgress)
        XCTAssertFalse(restored.canResume)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(legacy["status"] as? String, "paused")
        legacy.removeValue(forKey: "torrentCheckState")
        legacy.removeValue(forKey: "torrentExistingDataPath")
        let old = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.torrentCheckState)
        XCTAssertNil(old.torrentExistingDataPath)
    }

    func testEmptyFilesMustExistAndRemainEmpty() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metainfo = torrent(payloads: [Data()], pieceLength: 4, multi: true)
        let missing = try await check(metainfo, root)
        XCTAssertEqual(missing.state, .incomplete)
        let file = root.appendingPathComponent("file0")
        try Data().write(to: file)
        let empty = try await check(metainfo, root)
        XCTAssertEqual(empty.state, .complete)
        try Data([1]).write(to: file)
        let oversized = try await check(metainfo, root)
        XCTAssertEqual(oversized.state, .incomplete)
    }

    func testMutationDuringCheckThrowsInsteadOfCompleting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data("abcd".utf8).write(to: file)
        do {
            _ = try await Aria2TorrentService().checkExistingData(
                metainfo: torrent(payloads: [Data("abcd".utf8)], pieceLength: 4), location: file
            ) { progress in
                if progress == 0 { try? Data("changed".utf8).write(to: file, options: .atomic) }
            }
            XCTFail("Changed files must not receive a verification result")
        } catch is TorrentCheckReadError { }
    }

    func testCancellationDoesNotReturnComplete() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data("abcd".utf8).write(to: file)
        let metainfo = torrent(payloads: [Data("abcd".utf8)], pieceLength: 4)
        let task = Task { try await check(metainfo, file) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled check returned a result") }
        catch is CancellationError { }
    }

    func testMalformedV1PieceHashesAndLengthOverflow() throws {
        for length in [0, -1] {
            let data = encode(["info": ["name": "file", "length": 4, "piece length": length, "pieces": Data(repeating: 0, count: 20)]])
            XCTAssertThrowsError(try TorrentMetainfoParser.verificationInfo(from: data))
        }
        for hashes in [Data(), Data(repeating: 0, count: 19), Data(repeating: 0, count: 40)] {
            let data = encode(["info": ["name": "file", "length": 4, "piece length": 4, "pieces": hashes]])
            XCTAssertThrowsError(try TorrentMetainfoParser.verificationInfo(from: data))
        }
        let overflow = encode(["info": ["name": "files", "files": [
            ["path": ["a"], "length": Int.max], ["path": ["b"], "length": 1]
        ], "piece length": Int.max, "pieces": Data(repeating: 0, count: 20)]])
        XCTAssertThrowsError(try TorrentMetainfoParser.verificationInfo(from: overflow))
    }

    func testHugePieceLengthUsesBoundedReads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data("abcd".utf8).write(to: file)
        let result = try await check(torrent(payloads: [Data("abcd".utf8)], pieceLength: Int.max), file)
        XCTAssertEqual(result.state, .complete)
    }

    func testMappingRejectsTraversalSymlinksAndNonregularFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = torrent(payloads: [Data("data".utf8)], pieceLength: 4, multi: true)
        let preview = try TorrentMetainfoParser.preview(from: data)
        let layout = try TorrentCheckPathMapping.resolve(preview: preview, location: root)
        XCTAssertEqual(layout.indexOut, ["1=\(root.lastPathComponent)/file0"])
        let rawPath = try XCTUnwrap(realpath(root.path, nil))
        defer { free(rawPath) }
        XCTAssertEqual(layout.payloadURLs[0].path, String(cString: rawPath) + "/file0")
        let target = root.appendingPathComponent("file0")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root)
        XCTAssertThrowsError(try TorrentCheckPathMapping.resolve(preview: preview, location: root))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try TorrentCheckPathMapping.resolve(preview: preview, location: root))
        let traversal = TorrentContentsPreview(name: "root", files: [TorrentFileDescriptor(index: 1, path: "../outside", byteCount: 4)], totalBytes: 4, metainfoData: Data(), infoHash: "test", isMultiFile: true)
        XCTAssertThrowsError(try TorrentCheckPathMapping.resolve(preview: traversal, location: root))
    }

    private func check(_ metainfo: Data, _ location: URL, selection: TorrentFileSelection? = nil) async throws -> TorrentCheckResult {
        try await Aria2TorrentService().checkExistingData(metainfo: metainfo, location: location, selection: selection)
    }

    private func torrent(payloads: [Data], pieceLength: Int, multi: Bool = false) -> Data {
        let combined = payloads.reduce(into: Data()) { $0.append($1) }
        var hashes = Data()
        var offset = 0
        while offset < combined.count {
            let count = min(pieceLength, combined.count - offset)
            hashes.append(contentsOf: Insecure.SHA1.hash(data: combined[offset..<(offset + count)]))
            offset += count
        }
        var info: [String: Any] = ["name": "original", "piece length": pieceLength, "pieces": hashes]
        if multi { info["files"] = payloads.enumerated().map { ["length": $0.element.count, "path": ["file\($0.offset)"]] as [String: Any] } }
        else { info["length"] = payloads[0].count }
        return encode(["info": info])
    }

    private func encode(_ value: Any) -> Data {
        if let value = value as? Int { return Data("i\(value)e".utf8) }
        if let value = value as? String { return encode(Data(value.utf8)) }
        if let value = value as? Data { return Data("\(value.count):".utf8) + value }
        if let value = value as? [Any] { return Data("l".utf8) + value.reduce(into: Data()) { $0.append(encode($1)) } + Data("e".utf8) }
        let dictionary = value as! [String: Any]
        return Data("d".utf8) + dictionary.keys.sorted().reduce(into: Data()) { $0.append(encode($1)); $0.append(encode(dictionary[$1]!)) } + Data("e".utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarborCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
