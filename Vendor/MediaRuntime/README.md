# Bundled Media Runtime

This directory holds Harbor's self-contained media runtime for public media downloads.

- yt-dlp: 2026.06.09, universal macOS build copied into both architecture folders.
- arm64 ffmpeg/ffprobe: copied from /opt/homebrew
- x86_64 ffmpeg/ffprobe: Evermeet 8.1.2 static macOS builds.

The app launches one yt-dlp process per active media download. yt-dlp may spawn the bundled ffmpeg/ffprobe binaries for probing and merging; Harbor runs the process in its own process group so pause, cancel, and quit terminate the full child tree.

TODO: Add a third-party license manifest to release packaging before public distribution. The bundled ffmpeg build is GPL-enabled.

To refresh this runtime:

```bash
./Scripts/vendor-media-runtime.sh
```
