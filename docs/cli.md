# Harbor CLI

The CLI controls the running Harbor app. It uses the same queue, saved downloads,
settings, and download engines as the GUI. It does not require an MCP server.

## Setup

1. Open Harbor > Settings > General.
2. Select **Install Command**. This installs `~/.local/bin/harbor` for your user.
3. Enable **Allow CLI access**.
4. Select **Install Agent Skill…**, review the folders, and select **Install**.
5. Restart your agent to load its new skill.

Use `"$HOME/.local/bin/harbor"` if `~/.local/bin` is not on your PATH. Harbor does
not change shell profiles or request administrator access. Install Command does
not enable CLI access. An installed command updates when Harbor starts, provided
its file has not been changed outside Harbor.

The shared skill goes in `~/.agents/skills/harbor`, which Codex and Cursor read.
Harbor also detects `~/.claude`, `~/.copilot`, and `~/.gemini`, then offers their
`skills/harbor` folders. It does not scan projects. Linked paths and changed or
unowned files are kept. Each target reports its own result. The same sheet can
remove unchanged Harbor-owned skill files.

## Commands

Run `harbor help` for syntax and `harbor capabilities --json` for the installed
app's supported operations. Run `harbor settings list --json` for setting names,
values, types, and allowed ranges.

```sh
harbor list --status downloading --json
harbor add 'https://example.com/file.zip' --paused --request-id "$(uuidgen)" --json
harbor inspect DOWNLOAD_ID --json
harbor resume DOWNLOAD_ID --json
harbor wait DOWNLOAD_ID --timeout 60 --json
harbor tags set DOWNLOAD_ID work archive --json
harbor limit DOWNLOAD_ID download 2048 --json
harbor torrent files DOWNLOAD_ID --json
harbor torrent select DOWNLOAD_ID 1 3 --json
harbor settings set trafficMode quiet --json
```

Add supports direct links, media links (`--kind mediaURL`), magnets, and torrent
files or URLs. `--destination` selects an existing writable folder. `--start`
overrides the automatic-start setting; `--paused` keeps the new item paused.
`--files 1,3` selects torrent files and `--sequential` requests sequential pieces.
Media preview returns format IDs; `--format ID` uses the selected format and
Harbor's normal matching audio selection. Settings media defaults apply when
no format is supplied. Manifest import uses the existing experimental import
setting and reports accepted IDs if only part of the batch completes.

Use `source ID` only when you need the original URL. Normal list output omits
source URLs and headers. `inspect` includes the error message; source URLs,
errors, filenames, destinations, and media metadata can contain private data.

Pass private URLs and headers through JSON input, not process arguments:

```sh
harbor add --input /path/to/private-request.json --json
```

The file must contain an object such as:

```json
{"source":"https://example.com/private-file","paused":true,"headers":[{"name":"Authorization","value":"Bearer REPLACE_ME"}]}
```

`--input -` reads that object from standard input. Protect input files and remove
them when they are no longer needed. Do not put secrets in shell history.

## Results and retries

`--json` returns one object with `protocol`, `ok`, and `result` or `error`. Partial
failures also return `result`, including accepted IDs or per-folder outcomes.
Commands that start background work return `accepted: true`. Use `inspect` or
`wait` to check completion. A timeout does not cancel the action.

| Exit | Meaning |
| --- | --- |
| 0 | Read succeeded or change was accepted |
| 1 | Operation failed, including partial failure or failed/cancelled download |
| 2 | Invalid command or argument |
| 3 | App or local connection unavailable |
| 4 | User interaction required |
| 5 | Wait timeout |

Save a UUID before an add command and reuse the same `--request-id` and options
when retrying it. Harbor saves the receipt across app restarts. An interrupted
request with an uncertain result returns `outcome_unknown`; inspect the list
before submitting a new request. Replaying an ID for a removed download returns
the original ID and does not create another download.

Bulk changes require `--all`. Missing IDs never mean all downloads. `remove`
keeps downloaded files. `trash ID --confirm-trash` moves files to Trash. Do not
use Trash unless the user requested removal of the files.

## Interactive operations

`browser ID` opens Harbor's browser when the download requires a browser session.
Sign-in remains interactive. `ui PANE` opens a settings pane and returns
`needs_user_interaction`. Use it for macOS permissions, start-at-login setup,
default-app registration, Safari extension management, VPN profile/credentials,
and software update dialogs. These commands do not claim that setup completed.

## Local access and testing

Access is disabled by default. Once enabled, commands run directly. The socket
accepts only the same macOS user and is stored in a private directory with mode
0700; the socket has mode 0600. There is no network listener. This is a user
boundary, not protection from other software already running as that user.
An assistant can still send returned information to its model provider.

The CLI starts the installed app in the background if needed. It waits up to ten
seconds for access; it cannot enable access itself. The app owns its socket using
an exclusive lock, so another instance cannot replace an active endpoint.
Requests run in sequence, and incomplete request reads expire after five seconds.
A long metadata preview can delay another command. Client response waits are
bounded to 120 seconds. JSON messages are limited to 4 MB; list pages are limited
to 500 entries.

Run `python3 Scripts/test-cli.py` after building. The test uses temporary download,
app-support, settings, and agent folders, plus the existing local fixture server.
`--keep` leaves that instance open for manual UI review. Development overrides
`HARBOR_CLI_DIRECTORY` and `HARBOR_AGENT_HOME` isolate the socket and installer.
A custom socket directory disables automatic app launch in the client.

## Open a link in Harbor

Extensions and other tools can open the Add Download window with a link:

```sh
open 'harbor://download?url=https%3A%2F%2Fexample.com%2Ffile.zip'
```

Percent-encode the HTTP or HTTPS download URL in the `url` query value.
