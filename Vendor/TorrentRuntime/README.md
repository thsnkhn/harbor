# Bundled Aria2 Next Runtime

This directory holds Harbor's self-contained `aria2-next` runtime for torrent support.

Current bundled architectures:

- arm64 and x86_64: `QZGao/aria2-next`, a fork of `AnInsomniacy/aria2-next` with modifications to support per-download HTTP headers for BitTorrent web-seeds.

Each `TorrentRuntime/<arch>/bin` folder includes the standalone `aria2-next` binary so Harbor can launch torrents without requiring Homebrew on the user's Mac.

Harbor starts the engine with DHT, local peer discovery, and port mapping disabled. It enables DHT and port mapping before a torrent add, resume, or magnet preview. A local RPC check disables them when no active or runnable queued torrents remain. Paused recovery entries do not keep discovery enabled. The engine process stays available for recovery and settings operations.

Idle transitions use `aria2.changeGlobalOption`; they do not restart the engine. Libtorrent can bootstrap DHT again when discovery resumes. Peer blocklists, proxy settings, and interface bindings still apply. The five-second task-session checkpoint remains separate from DHT routing-state writes.
