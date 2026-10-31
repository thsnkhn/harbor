import Foundation
import Darwin

/// The flock protects stale-socket cleanup, including across multiple app instances.
nonisolated final class CLIServer: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let lock: Int32
    private let stopped = DispatchGroup()
    init(handler: @escaping @Sendable (Data) async -> Data) throws {
        try CLIWire.validateDirectory(create: true)
        let lock = open(CLIWire.directory.appendingPathComponent("owner.lock").path,
                        O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CLIWire.systemError() }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw CLIError("already_running", "Another Harbor instance owns CLI access.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); throw CLIWire.systemError() }
        do {
            unlink(CLIWire.socketPath)
            guard try CLIWire.address({ bind(fd, $0, $1) }) == 0,
                  chmod(CLIWire.socketPath, 0o600) == 0, listen(fd, 16) == 0 else { throw CLIWire.systemError() }
        } catch { close(fd); close(lock); throw error }
        descriptor = fd; self.lock = lock
        CLIWire.configure(fd)
        let queue = DispatchQueue(label: "co.hapy.harbor.cli")
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Keep the listener free to close immediately when access is disabled.
        // The worker serializes commands; only eight clients may wait at once.
        let worker = DispatchQueue(label: "co.hapy.harbor.cli.requests")
        let slots = DispatchSemaphore(value: 8)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard slots.wait(timeout: .now()) == .success else { close(client); return }
            worker.async {
                defer { slots.signal() }
                CLIWire.configure(client)
                var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout.size(ofValue: receiveTimeout)))
                do {
                    try CLIWire.verifyPeer(client)
                    let request = try CLIWire.read(client, timeout: 5)
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        let response = await handler(request)
                        try? CLIWire.write(response, to: client)
                        close(client)
                        done.signal()
                    }
                    done.wait()
                } catch {
                    try? CLIWire.write(CLIWire.failure(error), to: client)
                    close(client)
                }
            }
        }
        let stopped = self.stopped
        stopped.enter()
        source.setCancelHandler {
            close(fd)
            unlink(CLIWire.socketPath)
            close(lock)
            stopped.leave()
        }
        source.resume()
    }
    deinit { source.cancel(); stopped.wait() }
}
