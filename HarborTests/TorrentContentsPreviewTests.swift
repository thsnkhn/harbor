import Foundation
import XCTest
@testable import Harbor

final class TorrentContentsPreviewTests: XCTestCase {
    func testParsesSingleFileTorrent() throws {
        let data = makeSingleFileTorrent(name: "archive.zip", length: 42)

        let preview = try TorrentMetainfoParser.preview(from: data)

        XCTAssertEqual(preview.name, "archive.zip")
        XCTAssertEqual(
            preview.files,
            [TorrentFileDescriptor(index: 1, path: "archive.zip", byteCount: 42)]
        )
        XCTAssertEqual(preview.totalBytes, 42)
        XCTAssertEqual(preview.infoHash, ManagedTorrentSourceStore.fingerprint(for: data))
    }

    func testParsesMultiFileTorrentInEncodedOrder() throws {
        let data = makeMultiFileTorrent()

        let preview = try TorrentMetainfoParser.preview(from: data)

        XCTAssertEqual(preview.name, "Release")
        XCTAssertEqual(
            preview.files,
            [
                TorrentFileDescriptor(index: 1, path: "Docs/Résumé.txt", byteCount: 7),
                TorrentFileDescriptor(index: 2, path: "Video/clip.mp4", byteCount: 15)
            ]
        )
        XCTAssertEqual(preview.totalBytes, 22)
    }

    func testRejectsMalformedTorrent() {
        XCTAssertThrowsError(try TorrentMetainfoParser.preview(from: Data("not-bencode".utf8)))
    }

    func testRejectsOversizedTorrentBeforeParsing() {
        let oversized = Data(
            repeating: 0,
            count: TorrentMetainfoParser.maximumMetainfoBytes + 1
        )

        XCTAssertThrowsError(try TorrentMetainfoParser.preview(from: oversized)) { error in
            XCTAssertEqual(error as? TorrentMetainfoError, .tooLarge)
        }
    }

    func testTorrentEngineLogBufferIsBoundedAndStopsAfterStartup() {
        let buffer = TorrentEngineLogBuffer(maximumCharacterCount: 16)
        buffer.append(String(repeating: "a", count: 32))

        XCTAssertEqual(buffer.snapshot().count, 16)
        XCTAssertTrue(buffer.snapshot().hasSuffix("\n"))

        buffer.stopCapturing()
        buffer.append("ignored")
        XCTAssertEqual(buffer.snapshot(), "")

        buffer.reset()
        buffer.append("ready")
        XCTAssertEqual(buffer.snapshot(), "ready\n")
    }

    func testBuildsPartialSelectionSummaryInTorrentOrder() throws {
        let preview = try TorrentMetainfoParser.preview(from: makeMultiFileTorrent())

        let selection = TorrentFileSelection.partial(selectedIndexes: [2], in: preview)

        XCTAssertEqual(selection?.selectedIndexes, [2])
        XCTAssertEqual(selection?.selectedFileCount, 1)
        XCTAssertEqual(selection?.totalFileCount, 2)
        XCTAssertEqual(selection?.selectedBytes, 15)
        XCTAssertEqual(selection?.totalBytes, 22)
        XCTAssertNil(TorrentFileSelection.partial(selectedIndexes: [1, 2], in: preview))
        XCTAssertNil(TorrentFileSelection.partial(selectedIndexes: [], in: preview))
    }

    func testCompactsSelectedIndexesForAria2() {
        XCTAssertEqual(
            Aria2TorrentService.selectFileOption(from: [6, 2, 1, 3, 6, -1]),
            "1-3,6"
        )
        XCTAssertNil(Aria2TorrentService.selectFileOption(from: []))
    }

    func testDownloadOptionsIncludeSelectionOnlyForPartialRequest() {
        let selectedOptions = Aria2TorrentService.downloadOptions(
            destinationFolderPath: "/tmp/downloads",
            transferSettings: .default,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: nil,
                shouldSeed: false,
                selectedFileIndexes: [1, 3, 4]
            )
        )
        let allFileOptions = Aria2TorrentService.downloadOptions(
            destinationFolderPath: "/tmp/downloads",
            transferSettings: .default,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: nil,
                shouldSeed: false
            )
        )

        XCTAssertEqual(selectedOptions["select-file"], "1,3-4")
        XCTAssertNil(allFileOptions["select-file"])
    }

    func testBuildsMagnetPreviewFromAria2NextStatusWithoutMetainfoSidecar() throws {
        let payload = try JSONDecoder().decode(
            Aria2NextMagnetStatus.self,
            from: Data(
                #"{"status":"paused","infoHash":"0123456789abcdef0123456789abcdef01234567","errorMessage":null,"files":[{"index":"1","path":"/tmp/preview/Release/Docs/readme.txt","length":"7"},{"index":"2","path":"/tmp/preview/Release/video.mp4","length":"15"}],"bittorrent":{"info":{"name":"Release"},"infoHashV1":"0123456789abcdef0123456789abcdef01234567","infoHashV2":null}}"#.utf8
            )
        )

        let preview = try XCTUnwrap(
            payload.preview(relativeTo: URL(fileURLWithPath: "/tmp/preview", isDirectory: true))
        )

        XCTAssertEqual(preview.name, "Release")
        XCTAssertEqual(preview.totalBytes, 22)
        XCTAssertEqual(
            preview.files,
            [
                TorrentFileDescriptor(index: 1, path: "Docs/readme.txt", byteCount: 7),
                TorrentFileDescriptor(index: 2, path: "video.mp4", byteCount: 15)
            ]
        )
        XCTAssertNil(preview.metainfoData)
    }

    @MainActor
    func testPartialSelectionPersistsAndLegacyRecordDefaultsToAllFiles() throws {
        let selection = TorrentFileSelection(
            selectedIndexes: [2],
            selectedFileCount: 1,
            totalFileCount: 3,
            selectedBytes: 15,
            totalBytes: 40
        )
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/example.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp/downloads",
            status: .paused,
            torrentFileSelection: selection
        )

        let encoded = try JSONEncoder().encode(item.makeRecord())
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: encoded)
        XCTAssertEqual(restored.torrentFileSelection, selection)

        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "torrentFileSelection")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacyRecord = try JSONDecoder().decode(DownloadRecord.self, from: legacyData)
        XCTAssertNil(legacyRecord.torrentFileSelection)
    }

    private func makeSingleFileTorrent(name: String, length: Int64) -> Data {
        var info = Data([UInt8(ascii: "d")])
        appendString("length", to: &info)
        info.append(Data("i\(length)e".utf8))
        appendString("name", to: &info)
        appendString(name, to: &info)
        appendString("piece length", to: &info)
        info.append(Data("i16384e".utf8))
        appendString("pieces", to: &info)
        appendBytes(Data(repeating: 0x11, count: 20), to: &info)
        info.append(UInt8(ascii: "e"))
        return wrapInfoDictionary(info)
    }

    private func makeMultiFileTorrent() -> Data {
        var firstFile = Data([UInt8(ascii: "d")])
        appendString("length", to: &firstFile)
        firstFile.append(Data("i7e".utf8))
        appendString("path", to: &firstFile)
        firstFile.append(UInt8(ascii: "l"))
        appendString("Docs", to: &firstFile)
        appendString("Résumé.txt", to: &firstFile)
        firstFile.append(UInt8(ascii: "e"))
        firstFile.append(UInt8(ascii: "e"))

        var secondFile = Data([UInt8(ascii: "d")])
        appendString("length", to: &secondFile)
        secondFile.append(Data("i15e".utf8))
        appendString("path", to: &secondFile)
        secondFile.append(UInt8(ascii: "l"))
        appendString("Video", to: &secondFile)
        appendString("clip.mp4", to: &secondFile)
        secondFile.append(UInt8(ascii: "e"))
        secondFile.append(UInt8(ascii: "e"))

        var info = Data([UInt8(ascii: "d")])
        appendString("files", to: &info)
        info.append(UInt8(ascii: "l"))
        info.append(firstFile)
        info.append(secondFile)
        info.append(UInt8(ascii: "e"))
        appendString("name", to: &info)
        appendString("Release", to: &info)
        appendString("piece length", to: &info)
        info.append(Data("i16384e".utf8))
        appendString("pieces", to: &info)
        appendBytes(Data(repeating: 0x22, count: 20), to: &info)
        info.append(UInt8(ascii: "e"))
        return wrapInfoDictionary(info)
    }

    private func wrapInfoDictionary(_ info: Data) -> Data {
        var data = Data([UInt8(ascii: "d")])
        appendString("info", to: &data)
        data.append(info)
        data.append(UInt8(ascii: "e"))
        return data
    }

    private func appendString(_ value: String, to data: inout Data) {
        appendBytes(Data(value.utf8), to: &data)
    }

    private func appendBytes(_ value: Data, to data: inout Data) {
        data.append(Data("\(value.count):".utf8))
        data.append(value)
    }
}
