# Bundled aria2 Runtime

This directory holds the self-contained `aria2c` runtime that Harbor ships for torrent support.

Current bundled architectures:

- arm64: aria2 1.37.0 with bundled non-system Homebrew libraries.
- x86_64: aria2 1.36.0 with bundled non-system conda-forge libraries.

Each `TorrentRuntime/<arch>/bin` and `TorrentRuntime/<arch>/lib` folder includes the `aria2c` binary and its non-system dynamic libraries so Harbor can launch torrents without requiring Homebrew on the user's Mac.

TODO: Add a refresh script that rebuilds both architecture folders from pinned upstream artifacts.
