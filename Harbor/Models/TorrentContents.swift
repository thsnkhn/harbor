import CryptoKit
import Foundation

struct TorrentFileDescriptor: Identifiable, Equatable, Sendable {
    let index: Int
    let path: String
    let byteCount: Int64

    var id: Int { index }
}

struct TorrentContentsPreview: Equatable, Sendable {
    let name: String
    let files: [TorrentFileDescriptor]
    let totalBytes: Int64
    let metainfoData: Data
    let infoHash: String
    var isMultiFile: Bool = false
}

struct TorrentFileSelection: Codable, Equatable, Sendable {
    let selectedIndexes: [Int]
    let selectedFileCount: Int
    let totalFileCount: Int
    let selectedBytes: Int64
    let totalBytes: Int64

    var isPartial: Bool {
        selectedFileCount < totalFileCount
    }

    static func partial(
        selectedIndexes: Set<Int>,
        in preview: TorrentContentsPreview
    ) -> TorrentFileSelection? {
        let selectedFiles = preview.files.filter { selectedIndexes.contains($0.index) }
        guard selectedFiles.isEmpty == false,
              selectedFiles.count < preview.files.count else {
            return nil
        }

        return TorrentFileSelection(
            selectedIndexes: selectedFiles.map(\.index),
            selectedFileCount: selectedFiles.count,
            totalFileCount: preview.files.count,
            selectedBytes: selectedFiles.reduce(0) { $0 + $1.byteCount },
            totalBytes: preview.totalBytes
        )
    }
}

enum TorrentMetainfoError: LocalizedError, Equatable {
    case malformed
    case tooLarge
    case missingName
    case missingFiles
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .malformed:
            "The torrent metadata is malformed."
        case .tooLarge:
            "The torrent metadata is too large."
        case .missingName:
            "The torrent metadata does not include a name."
        case .missingFiles:
            "The torrent metadata does not include any files."
        case .invalidFile:
            "The torrent metadata includes an invalid file entry."
        }
    }
}

enum TorrentMetainfoParser {
    nonisolated static let maximumMetainfoBytes = 32 * 1_024 * 1_024
    nonisolated private static let maximumDepth = 128
    nonisolated private static let maximumCollectionEntries = 200_000

    nonisolated static func preview(from data: Data) throws -> TorrentContentsPreview {
        guard data.isEmpty == false else {
            throw TorrentMetainfoError.malformed
        }
        guard data.count <= maximumMetainfoBytes else {
            throw TorrentMetainfoError.tooLarge
        }

        var parser = Parser(data: data)
        let root = try parser.parseValue(depth: 0)
        guard parser.isAtEnd,
              case let .dictionary(rootEntries) = root.value,
              let infoNode = dictionaryValue(for: "info", in: rootEntries),
              case let .dictionary(infoEntries) = infoNode.value else {
            throw TorrentMetainfoError.malformed
        }

        guard let name = preferredString(
            utf8Key: "name.utf-8",
            fallbackKey: "name",
            in: infoEntries
        ), name.isEmpty == false else {
            throw TorrentMetainfoError.missingName
        }

        let files: [TorrentFileDescriptor]
        if let filesNode = dictionaryValue(for: "files", in: infoEntries) {
            guard case let .list(fileNodes) = filesNode.value,
                  fileNodes.isEmpty == false else {
                throw TorrentMetainfoError.missingFiles
            }

            files = try fileNodes.enumerated().map { offset, node in
                guard case let .dictionary(fileEntries) = node.value,
                      let length = integerValue(for: "length", in: fileEntries),
                      length >= 0,
                      let pathNode = dictionaryValue(for: "path.utf-8", in: fileEntries)
                        ?? dictionaryValue(for: "path", in: fileEntries),
                      case let .list(componentNodes) = pathNode.value else {
                    throw TorrentMetainfoError.invalidFile
                }

                let components = try componentNodes.map { componentNode in
                    guard case let .bytes(bytes) = componentNode.value else {
                        throw TorrentMetainfoError.invalidFile
                    }
                    let component = displayString(from: bytes)
                    guard component.isEmpty == false else {
                        throw TorrentMetainfoError.invalidFile
                    }
                    return component
                }
                guard components.isEmpty == false else {
                    throw TorrentMetainfoError.invalidFile
                }

                return TorrentFileDescriptor(
                    index: offset + 1,
                    path: components.joined(separator: "/"),
                    byteCount: length
                )
            }
        } else {
            guard let length = integerValue(for: "length", in: infoEntries),
                  length >= 0 else {
                throw TorrentMetainfoError.missingFiles
            }
            files = [TorrentFileDescriptor(index: 1, path: name, byteCount: length)]
        }

        var totalBytes: Int64 = 0
        for file in files {
            let (sum, overflow) = totalBytes.addingReportingOverflow(file.byteCount)
            guard overflow == false else {
                throw TorrentMetainfoError.invalidFile
            }
            totalBytes = sum
        }

        let infoHash = Insecure.SHA1.hash(data: data[infoNode.range])
            .map { String(format: "%02x", $0) }
            .joined()

        return TorrentContentsPreview(
            name: name,
            files: files,
            totalBytes: totalBytes,
            metainfoData: data,
            infoHash: infoHash,
            isMultiFile: dictionaryValue(for: "files", in: infoEntries) != nil
        )
    }

    nonisolated static func infoDictionaryRange(in data: Data) -> Range<Data.Index>? {
        var parser = Parser(data: data)
        guard let root = try? parser.parseValue(depth: 0),
              parser.isAtEnd,
              case let .dictionary(entries) = root.value,
              let infoNode = dictionaryValue(for: "info", in: entries),
              case .dictionary = infoNode.value else {
            return nil
        }
        return infoNode.range
    }

    nonisolated static func verificationInfo(from data: Data) throws -> (preview: TorrentContentsPreview, pieceLength: Int64, hashes: Data) {
        let preview = try preview(from: data)
        var parser = Parser(data: data)
        let root = try parser.parseValue(depth: 0)
        guard case let .dictionary(entries) = root.value,
              let info = dictionaryValue(for: "info", in: entries),
              case let .dictionary(infoEntries) = info.value,
              let pieceLength = integerValue(for: "piece length", in: infoEntries), pieceLength > 0,
              let pieces = dictionaryValue(for: "pieces", in: infoEntries),
              case let .bytes(hashes) = pieces.value,
              hashes.count % 20 == 0,
              Int64(hashes.count / 20) == preview.totalBytes / pieceLength + (preview.totalBytes % pieceLength == 0 ? 0 : 1) else {
            throw TorrentMetainfoError.malformed
        }
        return (preview, pieceLength, Data(hashes))
    }

    private nonisolated static func preferredString(
        utf8Key: String,
        fallbackKey: String,
        in entries: [(Data, Node)]
    ) -> String? {
        let node = dictionaryValue(for: utf8Key, in: entries)
            ?? dictionaryValue(for: fallbackKey, in: entries)
        guard let node, case let .bytes(bytes) = node.value else {
            return nil
        }
        return displayString(from: bytes)
    }

    private nonisolated static func integerValue(
        for key: String,
        in entries: [(Data, Node)]
    ) -> Int64? {
        guard let node = dictionaryValue(for: key, in: entries),
              case let .integer(value) = node.value else {
            return nil
        }
        return value
    }

    private nonisolated static func dictionaryValue(
        for key: String,
        in entries: [(Data, Node)]
    ) -> Node? {
        entries.first { $0.0.elementsEqual(key.utf8) }?.1
    }

    private nonisolated static func displayString(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private indirect enum Value {
        case integer(Int64)
        case bytes(Data)
        case list([Node])
        case dictionary([(Data, Node)])
    }

    nonisolated private struct Node {
        let value: Value
        let range: Range<Data.Index>
    }

    nonisolated private struct Parser {
        let data: Data
        var index = 0
        var parsedEntryCount = 0

        var isAtEnd: Bool { index == data.endIndex }

        mutating func parseValue(depth: Int) throws -> Node {
            guard depth <= TorrentMetainfoParser.maximumDepth,
                  parsedEntryCount < TorrentMetainfoParser.maximumCollectionEntries,
                  let byte = currentByte else {
                throw TorrentMetainfoError.malformed
            }
            parsedEntryCount += 1
            let start = index

            let value: Value
            switch byte {
            case UInt8(ascii: "i"):
                value = .integer(try parseInteger())
            case UInt8(ascii: "l"):
                value = .list(try parseList(depth: depth))
            case UInt8(ascii: "d"):
                value = .dictionary(try parseDictionary(depth: depth))
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                value = .bytes(try parseByteString())
            default:
                throw TorrentMetainfoError.malformed
            }
            return Node(value: value, range: start ..< index)
        }

        private mutating func parseInteger() throws -> Int64 {
            guard consume(UInt8(ascii: "i")) else {
                throw TorrentMetainfoError.malformed
            }
            let isNegative = consume(UInt8(ascii: "-"))
            let digitsStart = index
            while let byte = currentByte, byte.isASCIIDigit {
                index += 1
            }
            guard index > digitsStart,
                  currentByte == UInt8(ascii: "e") else {
                throw TorrentMetainfoError.malformed
            }
            let digits = data[digitsStart ..< index]
            guard (digits.count == 1 || digits.first != UInt8(ascii: "0")),
                  (isNegative == false || digits.first != UInt8(ascii: "0")) else {
                throw TorrentMetainfoError.malformed
            }

            var value: Int64 = 0
            for digit in digits {
                let next = Int64(digit - UInt8(ascii: "0"))
                let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
                let (summed, addOverflow) = multiplied.addingReportingOverflow(next)
                guard multiplyOverflow == false, addOverflow == false else {
                    throw TorrentMetainfoError.malformed
                }
                value = summed
            }
            index += 1
            return isNegative ? -value : value
        }

        private mutating func parseList(depth: Int) throws -> [Node] {
            guard consume(UInt8(ascii: "l")) else {
                throw TorrentMetainfoError.malformed
            }
            var values: [Node] = []
            while currentByte != UInt8(ascii: "e") {
                values.append(try parseValue(depth: depth + 1))
            }
            guard consume(UInt8(ascii: "e")) else {
                throw TorrentMetainfoError.malformed
            }
            return values
        }

        private mutating func parseDictionary(depth: Int) throws -> [(Data, Node)] {
            guard consume(UInt8(ascii: "d")) else {
                throw TorrentMetainfoError.malformed
            }
            var entries: [(Data, Node)] = []
            var previousKey: Data?
            while currentByte != UInt8(ascii: "e") {
                let key = try parseByteString()
                if let previousKey,
                   key.lexicographicallyPrecedes(previousKey) || key == previousKey {
                    throw TorrentMetainfoError.malformed
                }
                previousKey = key
                entries.append((key, try parseValue(depth: depth + 1)))
            }
            guard consume(UInt8(ascii: "e")) else {
                throw TorrentMetainfoError.malformed
            }
            return entries
        }

        private mutating func parseByteString() throws -> Data {
            let lengthStart = index
            while let byte = currentByte, byte.isASCIIDigit {
                index += 1
            }
            guard index > lengthStart,
                  currentByte == UInt8(ascii: ":") else {
                throw TorrentMetainfoError.malformed
            }
            let digits = data[lengthStart ..< index]
            guard digits.count == 1 || digits.first != UInt8(ascii: "0") else {
                throw TorrentMetainfoError.malformed
            }

            var length = 0
            for digit in digits {
                let next = Int(digit - UInt8(ascii: "0"))
                guard length <= (Int.max - next) / 10 else {
                    throw TorrentMetainfoError.malformed
                }
                length = length * 10 + next
            }
            index += 1
            guard length <= data.endIndex - index else {
                throw TorrentMetainfoError.malformed
            }
            let bytes = Data(data[index ..< index + length])
            index += length
            return bytes
        }

        private var currentByte: UInt8? {
            index < data.endIndex ? data[index] : nil
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard currentByte == byte else {
                return false
            }
            index += 1
            return true
        }
    }
}

private extension UInt8 {
    nonisolated var isASCIIDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }
}
