Harbor 1.4.0

- Added a yt-dlp powered Media URL downloader for public social/video links supported by yt-dlp.
- Added media previews with title, platform, thumbnail, size estimate, and MP4/original format choices.
- Added queue, pause, resume, cancel, and completion handling for media downloads.
- Bundled MediaRuntime helpers for Apple silicon and Intel Macs.
- Improved process cleanup so media helpers do not linger after pause, cancel, or quit.
- Kept the public-only compliance boundary: no private account, DRM, authentication, or platform security bypass support.
