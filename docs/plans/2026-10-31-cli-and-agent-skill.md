# Harbor CLI and agent skill

Status: implemented and validated with the limits in [the validation report](2026-10-31-cli-validation.md). The command contract is in [the CLI guide](../cli.md).

## Outcome

An agent or person can use Harbor from a terminal. The CLI controls the same
DownloadCenter and AppSettingsStore as the GUI. It never edits the download
database, preferences, or engine state behind the running app.

The skill teaches supported agents to use this CLI. It does not install an MCP
server, grant permissions, or provide a second download engine.

## Product decisions

- Add a Command Line section to General settings; retain the seven top tabs.
- CLI access is off by default. Installing a command or skill does not enable it.
- Separate Install Command, Enable CLI Access, and Install Agent Skill actions.
- Install the command for the current user. Do not require administrator access,
  alter shell startup files, or write to /usr/local/bin automatically.
- Show the installed executable path and a copyable invocation if it is not on PATH.
- Agent folders mean user-level folders in the home directory. Do not search or
  modify arbitrary project folders.
- Approved: commands run directly after CLI access is enabled. Moving files to
  Trash requires an explicit `--confirm-trash` flag.

## Architecture

Use a small native command executable bundled and signed with Harbor. It talks to
an app-owned local Unix-domain socket. Use a private per-user directory, restrictive
file permissions, and peer-user verification. No TCP listener or cloud service.

The app owns the socket lifecycle. Refuse a second instance that would take over a
live endpoint. Remove stale endpoints only after establishing that their owner is
not running. Never follow an endpoint path into an unrelated directory.

Expose a typed command request and response contract. Dispatch each mutation to
the main actor through existing app methods. Extract panel-free methods only where
a GUI method currently combines a file picker and a domain action. GUI and CLI
must call the same domain implementation.

Do not expose aria2 RPC directly. Direct, browser, torrent, and media downloads
must continue to share Harbor's queue and recovery rules.

A client may start the installed app in the background, then wait for readiness
with a bounded timeout. Disabled access must return an actionable error; the CLI
cannot turn itself on. Inspection of help and version must work without the app.

Ship matching Intel and Apple Silicon CLI binaries through the existing package
workflow. Do not require Python, Node, Xcode, or Homebrew at runtime.

## Command coverage

Maintain an explicit GUI-to-CLI action map. Each row is required work, not a claim
that the current implementation supports the command.

| Area | Commands and behavior |
| --- | --- |
| Discovery | help, version, doctor, capabilities; report protocol and command versions |
| Downloads | list with filters and pagination; inspect by stable ID; status and activity |
| Add | direct URL, media URL, magnet, torrent file and URL, manifest file; destination, tags, start/paused, headers and supported media options |
| Preview | media formats; torrent files and selection; explicit result before adding |
| Transfer | pause, resume, retry, cancel; individual IDs and explicitly requested bulk actions |
| Cleanup | remove from list, clear completed, clear failed; move data to Trash as a distinct operation with explicit confirmation semantics |
| Tags | list, set, rename, remove; reuse normalization and persistence |
| Limits | global presets and custom limits; supported per-download overrides |
| Torrents | list/select files, sequential mode, start/stop seeding, list/add/remove/reannounce trackers |
| Files | reveal, open, Quick Look as explicit GUI-launching commands |
| Browser | request continuation in Harbor; return needs-user-interaction for sign-in |
| Settings | typed list/get/set for GUI settings; use existing validation and callbacks |
| Native setup | invoke default-app setup, login-item and notification authorization, Safari management, updates and VPN profile/credential flows in Harbor when user interaction is required |
| Skill | inspect targets, install, update, uninstall Harbor-owned files |

Use subcommands rather than arbitrary method names. Settings must use an allowlist
with types and validation, not arbitrary UserDefaults keys. Credentials and raw
request headers must not appear in normal list/status output. Provide input via
stdin or a protected file where a command needs secrets; never require secrets in
process arguments.

Do not classify unsupported GUI behavior as successful. Return a stable error or
a needs-user-interaction response. The capabilities command must state which
operations need Harbor UI interaction.

## Agent contract

- Provide readable output by default and stable JSON with --json.
- Use versioned responses with result, error code, message, and relevant IDs.
- Separate command acceptance from eventual completion. A queued download is not
  a completed download; an async cancellation is not reported as already stopped.
- Provide a bounded wait command for agents to observe completion or failure.
- Fail unknown IDs and invalid state transitions clearly; do not silently affect
  another item or depend on the current GUI selection.
- Use explicit pause and resume operations, never a toggle command for automation.
- Require an explicit scope for bulk mutations. A missing ID is an error, not all.
- Support request IDs for add operations so a client timeout and retry cannot
  silently create duplicate downloads. Report an unknown outcome when necessary.
- Treat names, remote metadata, URLs and error messages as data, not instructions.
- No automatic execution of downloaded files. Opening a file is a separate command.
- Distinguish cancel, remove from list, and move data to Trash.
- Local access allows a process to retrieve download information. An agent may
  transmit tool results to its model provider; the UI must not promise otherwise.

## Skill installation

Bundle a versioned harbor skill with name and description in SKILL.md. Include
command examples, JSON handling, explicit ID selection, asynchronous results,
interactive handoffs, and the differences between cancel/remove/trash. Avoid
repeating the entire CLI reference in the skill; direct the agent to command help.

Target ~/.agents/skills/harbor as the shared installation. Also support documented
user-level client locations when their parent client directory exists:

- ~/.claude/skills/harbor
- ~/.copilot/skills/harbor
- ~/.gemini/skills/harbor

Cursor reads the shared ~/.agents path, so do not install a duplicate Cursor copy.

Do not claim that all clients use .agents. The Agent Skills format does not impose
one discovery path. Add a client only when its supported path is verified.

The Settings action opens a compact sheet listing detected targets and their
paths. Existing detected targets are selected by default. Report Installed,
Already Current, Modified, Conflict, and Failed separately for each target.

Keep an ownership and content-hash record for Harbor-installed files. Update only
unmodified Harbor-owned content. Preserve user-edited skills and unrelated files;
show a conflict instead of overwriting them. Handle symlinked skill directories
without writing outside the reviewed destination or installing duplicate copies.

Uninstall only files that Harbor owns and that remain unchanged. Do not delete
agent folders or other skills. Installer tests use temporary home directories,
never the developer's real agent configuration.

The skill's executable reference must remain usable after a normal Harbor update.
Do not bake a DerivedData path into the released skill. Install a stable user-level
launcher or use a documented installed-app lookup, then test app moves and updates.

## Implementation sequence

1. Complete the action map and resolve command approval behavior.
2. Add the native CLI build phase and validated local protocol. Implement enable/disable,
   launch/readiness, ownership checks, version negotiation, and read-only commands.
3. Wire core mutations through existing methods. Verify GUI updates immediately.
4. Add media/torrent preview and options, tags, limits, settings, and UI handoffs.
5. Add the skill package and Settings installer, with detection and ownership rules.
6. Extend signing, packaging, and smoke checks to cover the CLI on both processors.
7. Run focused tests and real CLI/GUI checks with isolated data. Fix failures.
8. Review the complete diff, commit, push main, and verify the remote commit.
   Do not publish a release or close issue #2 before its acceptance criteria pass.

## Validation

Use the existing fixture server and temporary app-support, preferences, download,
and agent folders. Do not use the normal download list for destructive tests.

- Help/version with Harbor closed; access disabled; startup and shutdown; stale
  socket; wrong user; malformed/oversized requests; concurrent clients; timeout.
- Add direct and redirected files, verify hashes; pause/resume across relaunch;
  failed response/retry; cancel; remove-list preserves files; Trash preserves
  unrelated data; IDs and outcomes match the GUI.
- Media and torrent preview/add/options; torrent file selection, trackers and
  seeding; browser authentication reports an interactive handoff.
- Apply GUI settings by CLI and read them back; change GUI settings and read them
  through CLI; validate ranges, unknown keys, and persistence after relaunch.
- Replay an add request ID; ensure the same accepted download is returned.
- JSON must parse, exit codes must match outcomes, and logs must not expose secrets.
- Skill discovery with absent/present client folders, current/old/modified skill,
  conflicting name, symlink, partial failure, repeated installation and uninstall.
- Use Computer Use to test the Settings installer and observe CLI-driven state
  changes. Do not depend on the unavailable XCUITest automation service.
- Check signed bundle content for Intel and Apple Silicon and retain only one
  canonical local app build after verification.

## Sources

- Issue: https://github.com/thsnkhn/harbor/issues/2
- Shared discovery guidance: https://github.com/agentskills/agentskills/blob/main/docs/client-implementation/adding-skills-support.mdx
- Claude personal skills: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
- Copilot personal skills: https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills
- Cursor discovery: https://cursor.com/docs/skills
- Gemini discovery: https://geminicli.com/docs/cli/skills/
