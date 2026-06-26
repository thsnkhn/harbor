import Darwin
import Foundation

enum ManagedChildProcessError: LocalizedError {
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .spawnFailed(code):
            String(cString: strerror(code))
        }
    }
}

final class ManagedChildProcess: @unchecked Sendable {
    typealias OutputHandler = @Sendable (String) -> Void
    typealias TerminationHandler = @Sendable (ManagedChildProcessTermination) -> Void

    nonisolated let processIdentifier: pid_t

    nonisolated private let lock = NSLock()
    nonisolated private let stdoutHandle: FileHandle
    nonisolated private let stderrHandle: FileHandle
    nonisolated private let onTermination: TerminationHandler
    nonisolated(unsafe) private var hasExited = false

    nonisolated init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onStdout: @escaping OutputHandler,
        onStderr: @escaping OutputHandler,
        onTermination: @escaping TerminationHandler
    ) throws {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0,
              pipe(&stderrPipe) == 0 else {
            throw ManagedChildProcessError.spawnFailed(errno)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attributes)

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var pid = pid_t()
        let argv = [executableURL.lastPathComponent] + arguments
        let env = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        let spawnResult = executableURL.path.withCString { path in
            withCStringArray(argv) { argvPointer in
                withCStringArray(env) { envPointer in
                    posix_spawn(&pid, path, &fileActions, &attributes, argvPointer, envPointer)
                }
            }
        }

        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard spawnResult == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw ManagedChildProcessError.spawnFailed(spawnResult)
        }

        self.processIdentifier = pid
        self.stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        self.stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        self.onTermination = onTermination

        installReadHandler(stdoutHandle, onOutput: onStdout)
        installReadHandler(stderrHandle, onOutput: onStderr)
        waitForExit()
    }

    nonisolated func terminate(grace: TimeInterval = 2) {
        guard isRunning else {
            return
        }

        _ = killProcessGroup(SIGTERM)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, self.isRunning else {
                return
            }

            _ = self.killProcessGroup(SIGKILL)
        }
    }

    nonisolated var isRunning: Bool {
        lock.withLock {
            hasExited == false
        }
    }

    private nonisolated func killProcessGroup(_ signal: Int32) -> Int32 {
        let groupIdentifier = getpgid(processIdentifier)
        guard groupIdentifier == processIdentifier else {
            return Darwin.kill(processIdentifier, signal)
        }

        return Darwin.kill(-processIdentifier, signal)
    }

    private nonisolated func installReadHandler(
        _ handle: FileHandle,
        onOutput: @escaping OutputHandler
    ) {
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard data.isEmpty == false else {
                fileHandle.readabilityHandler = nil
                return
            }

            guard let output = String(data: data, encoding: .utf8),
                  output.isEmpty == false else {
                return
            }

            onOutput(output)
        }
    }

    private nonisolated func waitForExit() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }

            var status: Int32 = 0
            let waitedPID = waitpid(self.processIdentifier, &status, 0)
            guard waitedPID == self.processIdentifier else {
                return
            }

            self.markExited(status: status)
        }
    }

    private nonisolated func markExited(status: Int32) {
        let shouldNotify = lock.withLock {
            guard hasExited == false else {
                return false
            }

            hasExited = true
            return true
        }

        guard shouldNotify else {
            return
        }

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()

        onTermination(ManagedChildProcessTermination(waitStatus: status))
    }
}

struct ManagedChildProcessTermination: Sendable {
    let waitStatus: Int32

    nonisolated var exitCode: Int32? {
        guard waitStatus & 0x7f == 0 else {
            return nil
        }

        return (waitStatus >> 8) & 0xff
    }

    nonisolated var signal: Int32? {
        let signal = waitStatus & 0x7f
        return signal == 0 ? nil : signal
    }

    nonisolated var isSuccess: Bool {
        exitCode == 0
    }
}

private nonisolated func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) rethrows -> Result {
    let cStrings = strings.map { strdup($0) }
    defer {
        for cString in cStrings {
            free(cString)
        }
    }

    var pointers = cStrings
    pointers.append(nil)

    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

private extension NSLock {
    nonisolated func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
