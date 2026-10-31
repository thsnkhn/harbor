import Foundation
import AppKit
import Darwin

let help = """
Harbor CLI — controls the running Harbor app (protocol 1).
Usage: harbor COMMAND [ARGUMENTS] [--option value] [--json]

  list [--status STATUS] [--tag TAG] [--offset N] [--limit N]
  inspect ID | source ID | activity ID | wait ID [--timeout SECONDS]
  add URL [--kind directURL|mediaURL|torrentFile|magnetLink]
      [--destination PATH] [--name NAME] [--start|--paused] [--tags a,b]
      [--files 1,2] [--sequential] [--format FORMAT_ID] [--request-id UUID]
  import PATH [--destination PATH] [--paused] [--tags a,b]
  preview URL [--kind mediaURL|torrentFile|magnetLink]
  pause|resume|retry|cancel|remove ID... (or --all)
  trash ID... --confirm-trash
  clear completed|failed
  tags list|set ID TAG...|rename OLD NEW|delete NAME
  limit ID download|upload inherit|unlimited|KBPS
  torrent files ID | select ID INDEX... | trackers ID
          tracker-add ID URL | tracker-remove ID URL | reannounce ID
          seed ID | stop-seeding ID
  media formats ID | format ID FORMAT_ID
  open|reveal|quick-look|browser ID
  settings list|get KEY|set KEY VALUE
  ui general|downloads|media|torrents|bandwidth|network|extensions|updates
  skill status|install|uninstall
  doctor | capabilities | version | help

Use --input FILE or --input - for a JSON object of options. Pass private URLs
as {"source":"..."} and headers as {"headers":[{"name":"...","value":"..."}]}.
Never put credentials in command arguments. --json emits one versioned response.
Exit: 0 success/accepted, 1 operation failed, 2 invalid input, 3 unavailable,
4 needs user interaction, 5 wait timeout. Async commands report acceptance.
Enable access in Harbor > Settings > General. Install at ~/.local/bin/harbor.
HARBOR_CLI_DIRECTORY selects an isolated endpoint for development.
"""

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }
func emit(_ data: Data) {
    if json { FileHandle.standardOutput.write(data + Data([10])); return }
    if let object = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(pretty + Data([10]))
    }
}
var attemptedLaunch = false
func exchange(_ request: [String: Any]) throws -> Data {
    let fd: Int32
    do { fd = try CLIWire.connect() }
    catch {
        guard !attemptedLaunch, (error as? CLIError)?.code == "unavailable",
              ProcessInfo.processInfo.environment["HARBOR_CLI_DIRECTORY"] == nil else { throw error }
        attemptedLaunch = true
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "co.hapy.harbor") else {
            throw CLIError("unavailable", "Install and open Harbor, then enable CLI access in Settings > General.")
        }
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-g", app.path]
        try launch.run(); launch.waitUntilExit()
        let deadline = Date().addingTimeInterval(10)
        var connection: Int32?
        repeat {
            connection = try? CLIWire.connect()
            if connection != nil { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        guard let connection else { throw error }
        fd = connection
    }
    defer { close(fd) }
    try CLIWire.write(CLIWire.encode(request), to: fd)
    return try CLIWire.read(fd)
}
do {
    if args.isEmpty || args == ["help"] || args == ["--help"] {
        if json { emit(try CLIWire.encode(["protocol": 1, "ok": true, "result": ["help": help]])) }
        else { print(help) }; exit(0)
    }
    if args == ["version"] || args == ["--version"] {
        emit(try CLIWire.encode(["protocol": 1, "ok": true, "result": ["version": CLIInfo.version]])); exit(0)
    }
    var options: [String: Any] = [:]; var positional: [String] = []
    let flags = Set(["paused", "start", "all", "confirm-trash", "sequential"])
    var hasInput = false
    var index = 0
    while index < args.count {
        let arg = args[index]; index += 1
        if arg.hasPrefix("--") {
            let name = String(arg.dropFirst(2))
            guard options[name] == nil else { throw CLIError("invalid_argument", "Duplicate option: \(name)") }
            if flags.contains(name) { options[name] = true }
            else {
                guard index < args.count else { throw CLIError("invalid_argument", "Missing value for \(arg)") }
                let value = args[index]; index += 1
                if name == "input" {
                    guard !hasInput else { throw CLIError("invalid_argument", "Only one --input is allowed.") }
                    hasInput = true
                    let handle = value == "-" ? FileHandle.standardInput
                        : try FileHandle(forReadingFrom: URL(fileURLWithPath: value))
                    defer { if value != "-" { try? handle.close() } }
                    var data = Data()
                    while data.count <= CLIWire.maximumBytes {
                        let chunk = try handle.read(upToCount: min(65536, CLIWire.maximumBytes + 1 - data.count)) ?? Data()
                        if chunk.isEmpty { break }
                        data.append(chunk)
                    }
                    guard data.count <= CLIWire.maximumBytes,
                          let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          Set(input.keys).isDisjoint(with: options.keys) else {
                        throw CLIError("invalid_argument", "Input must be a JSON object without duplicate options.")
                    }
                    options.merge(input) { first, _ in first }
                } else { options[name] = value }
            }
        } else { positional.append(arg) }
    }
    guard !positional.isEmpty else { throw CLIError("invalid_argument", "A command is required.") }
    // Paths are resolved in the caller's working directory, never in the GUI's.
    if let path = options["destination"] as? String { options["destination"] = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path }
    if positional[0] == "import", positional.count == 2 { positional[1] = URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath).path }
    if ["add", "preview"].contains(positional[0]), positional.count == 2,
       !positional[1].contains(":") { positional[1] = URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath).absoluteString }
    let wait = positional[0] == "wait"
    var timeout = 60.0
    if wait {
        guard positional.count == 2, Set(options.keys).isSubset(of: ["timeout"]),
              let seconds = Double(String(describing: options["timeout"] ?? "60")), seconds > 0, seconds <= 3600 else {
            throw CLIError("invalid_argument", "wait requires an ID and a timeout from 1 to 3600 seconds.")
        }
        timeout = seconds; positional[0] = "inspect"; options = [:]
    }
    let request: [String: Any] = ["protocol": 1, "arguments": positional, "options": options]
    let deadline = Date().addingTimeInterval(timeout)
    var response: Data
    while true {
        response = try exchange(request)
        guard wait,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              object["ok"] as? Bool == true,
              let result = object["result"] as? [String: Any],
              let status = result["status"] as? String else { break }
        if ["completed", "seeding"].contains(status) { break }
        if ["failed", "cancelled"].contains(status) { emit(response); exit(1) }
        if status == "browserSessionRequired" { emit(response); exit(4) }
        if Date() >= deadline { throw CLIError("timeout", "Download is not complete. Inspect its ID before taking another action.") }
        Thread.sleep(forTimeInterval: 0.5)
    }
    emit(response)
    let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
    if object?["ok"] as? Bool != true {
        let code = (object?["error"] as? [String: Any])?["code"] as? String
        exit(code == "invalid_argument" ? 2 : code == "needs_user_interaction" ? 4 : 1)
    }
} catch {
    emit(CLIWire.failure(error))
    let code = (error as? CLIError)?.code
    exit(code == "invalid_argument" ? 2 : code == "timeout" ? 5 : 3)
}
