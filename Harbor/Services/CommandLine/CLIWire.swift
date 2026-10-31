import Foundation
import Darwin

nonisolated struct CLIError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Shared framing for the native client and the app. One JSON request per connection.
nonisolated enum CLIWire {
    static let protocolVersion = 1
    static let maximumBytes = 4 * 1_024 * 1_024
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARBOR_CLI_DIRECTORY"]
            ?? "/tmp/co.hapy.harbor.cli-\(getuid())", isDirectory: true)
    }
    static var socketPath: String { directory.appendingPathComponent("control.sock").path }

    static func validateDirectory(create: Bool) throws {
        let path = directory.path
        if create, mkdir(path, 0o700) != 0, errno != EEXIST { throw systemError() }
        var info = stat()
        if !create, lstat(path, &info) != 0, errno == ENOENT {
            throw CLIError("unavailable", "Open Harbor and enable Settings > General > CLI access.")
        }
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw CLIError("unsafe_endpoint", "CLI directory must be a private directory owned by this user.")
        }
    }
    static func address<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLIError("unsafe_endpoint", "CLI socket path is too long.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw CLIError("unauthorized", "The CLI connection belongs to another user.")
        }
    }
    static func connect() throws -> Int32 {
        try validateDirectory(create: false)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError() }
        configure(fd)
        do {
            guard try address({ Darwin.connect(fd, $0, $1) }) == 0 else {
                throw CLIError("unavailable", "Open Harbor and enable Settings > General > CLI access.")
            }
            try verifyPeer(fd)
            return fd
        } catch { close(fd); throw error }
    }
    static func read(_ fd: Int32, timeout: TimeInterval = 120) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumBytes {
            guard Date() < deadline else { throw CLIError("timeout", "The message did not finish before the deadline.") }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { throw CLIError("connection_closed", "Connection ended before a complete response. Check Harbor before retrying a change.") }
            if let end = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<end])
                guard data.count <= maximumBytes else { break }
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw CLIError("too_large", "Request or response exceeds 4 MB. Use a smaller page or batch.")
    }
    static func write(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumBytes else { throw CLIError("too_large", "Response exceeds 4 MB. Use a smaller page.") }
        let framed = data + Data([10])
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw systemError() }
                offset += count
            }
        }
    }
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func failure(_ error: Error) -> Data {
        let known = error as? CLIError ?? CLIError("operation_failed", error.localizedDescription)
        return try! encode(["protocol": protocolVersion, "ok": false,
                            "error": ["code": known.code, "message": known.message]])
    }
    static func systemError() -> CLIError { CLIError("io_error", String(cString: strerror(errno))) }
}
