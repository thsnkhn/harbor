## Harbor 1.2.0

This release adds bandwidth controls and a cleaner download inspector.

### What's New

- Added Bandwidth settings for max active downloads, a global speed limit, a per-download speed limit, and per-download connection count.
- Applied transfer limits to direct URL downloads and torrent/magnet downloads, including updates while downloads are running.
- Redesigned the download detail view with a cleaner native layout, liquid-style rounded action buttons, and a compact transfer row for downloaded amount plus download/upload speed.
- Added a persisted Activity timeline for each download, including added, queued, started, resumed, paused, browser-required, completed, failed, and cancelled events.
- Activity is stored with each download and removed automatically when the download is deleted.
