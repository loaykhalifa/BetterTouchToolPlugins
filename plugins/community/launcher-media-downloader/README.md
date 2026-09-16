# Media Downloader — BetterTouchTool Launcher Plugin

![Media Downloader screenshot](https://raw.githubusercontent.com/loaykhalifa/BetterTouchToolPlugins/master/plugins/community/launcher-media-downloader/thumbnail.jpg)

A native Swift **BetterTouchTool Launcher** plugin for downloading video or extracting audio with [yt-dlp](https://github.com/yt-dlp/yt-dlp) and FFmpeg.

## Features

- Native one-page interface inside BTT Launcher
- Video and Audio modes with video presets, custom yt-dlp selectors, and MP3/M4A/WAV/Opus/FLAC output
- Thumbnail, title, channel/uploader, duration, and estimated-size preview
- Live progress, transferred size, speed, ETA, playlist count, and queue count
- Direct URLs, plain-text YouTube searches, multi-URL queues, and multi-line search lists
- Playlist folders and timestamped folders for text-list queues
- Individual Spotify track links resolved to a YouTube audio search
- Configurable destination, browser cookies, tool checks, updates, and logs
- Background downloads when the Launcher panel closes
- Open or reveal completed files

## Screenshot

![Screenshot](https://raw.githubusercontent.com/loaykhalifa/BetterTouchToolPlugins/master/plugins/community/launcher-media-downloader/thumbnail.jpg)

The repository screenshot is `thumbnail.jpg`.

## Requirements

- macOS 12 or later
- BetterTouchTool with Swift plugin support
- Apple Command Line Tools if BetterTouchTool requests them for Swift compilation
- Apple Silicon Homebrew tools at:
  - `/opt/homebrew/bin/brew`
  - `/opt/homebrew/bin/yt-dlp`
  - `/opt/homebrew/bin/ffmpeg`
  - `/opt/homebrew/bin/ffprobe`

Install dependencies with:

```bash
brew install yt-dlp ffmpeg
```

> This release targets Apple Silicon Macs. The health checker can detect `/usr/local`, but downloading and preview currently use `/opt/homebrew` paths.

## Installation

1. Download or clone this plugin folder.
2. Copy `BTTMediaDownloader.swift` to:

   ```text
   ~/Library/Application Support/BetterTouchTool/Plugins/
   ```

3. Restart BetterTouchTool or wait for its Swift plugin watcher to reload the file.
4. Open **BTT Launcher**, search for **Media Downloader**, and open the result.
5. Enter a supported URL or search, select the output options, and choose **Download**.

## Usage

The Source field accepts a single HTTP(S) URL, plain search text, multiple URLs, multiple search lines, or an individual Spotify track link.

| Key | Action |
|---|---|
| Return / Enter | Start download |
| Tab | Switch Video / Audio mode |
| Control | Cycle format |
| Shift-Control | Cycle format backward |
| Option | Cycle quality |
| Shift-Option | Cycle quality backward |

Choose browser cookies from **Settings** when a site requires authentication. Cookie access may trigger macOS or browser permission prompts.

## Output

Default folder:

```text
~/Downloads/BTT Media Downloads
```

Single items use `Video Title - Channel Name.ext`. Playlists use `Playlist Name/Video Title - Channel Name.ext`. Multi-line text queues use a timestamped `Media Playlist …` folder.

Last log:

```text
~/Library/Logs/BTTMediaDownloader.log
```

## Tool management

- **Check Tools** checks Homebrew, yt-dlp, FFmpeg, ffprobe, internet access, destination writability, and disk space.
- **Update Tools** uses an existing Homebrew installation to install or update yt-dlp and FFmpeg.
- **Copy Log** copies the latest troubleshooting log.

The updater does not install Homebrew itself.

## Security and privacy

The plugin:

- Validates HTTP(S) targets and passes them to yt-dlp after an end-of-options marker
- Converts plain text to a `ytsearch1:` target instead of executing it as shell input
- Launches yt-dlp with structured `Process` arguments
- Reads the clipboard when the surface opens and when Paste is selected
- Downloads remote thumbnail images for preview
- Contacts Spotify's oEmbed endpoint for Spotify-track resolution
- Reads browser cookies only when a browser is selected
- Writes downloads to the selected folder and logs to `~/Library/Logs/BTTMediaDownloader.log`
- Runs Homebrew only when **Update Tools** is selected
- Uses a short shell command to terminate the active process tree when Cancel is selected

Review the Swift source before installation. Swift plugins run with BetterTouchTool's permissions.

## Limitations

- Supported services and formats depend on yt-dlp and the source website.
- DRM-protected media is not supported.
- Spotify support is limited to individual tracks and searches YouTube for a likely match.
- Estimated sizes may be unavailable or differ from final merged or converted output.
- Closing BTT Launcher does not cancel an active download.
- This release targets Apple Silicon Homebrew paths.

## Troubleshooting

1. Open **Settings → Check Tools**.
2. Install missing dependencies with `brew install yt-dlp ffmpeg`, or use **Update Tools** if Homebrew is already installed.
3. Select browser cookies for authenticated sources.
4. Use **Copy Log** and inspect `~/Library/Logs/BTTMediaDownloader.log`.

## Files

- `BTTMediaDownloader.swift` — BetterTouchTool Swift Launcher plugin
- `plugin.json` — community/gallery metadata
- `README.md` — documentation
- `thumbnail.jpg` — screenshot

## Disclaimer

Only download media you own, created, or have permission to download. Respect copyright law and each platform's terms of service.

## License

MIT
