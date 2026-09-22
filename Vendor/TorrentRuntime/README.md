# Bundled Aria2 Next Runtime

This directory holds Harbor's self-contained `aria2-next` runtime for torrent support.

Current bundled architectures:

- arm64 and x86_64: `QZGao/aria2-next`, a fork of `AnInsomniacy/aria2-next` with modifications to support per-download HTTP headers for BitTorrent web-seeds.

Each `TorrentRuntime/<arch>/bin` folder includes the standalone `aria2-next` binary so Harbor can launch torrents without requiring Homebrew on the user's Mac.
