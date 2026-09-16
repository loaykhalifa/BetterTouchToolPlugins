// BTT-Plugin-Name: Media Downloader
// BTT-Plugin-Identifier: com.loay.btt.media-downloader
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: arrow.down.circle.fill
//
// BetterTouchTool Swift Source Launcher Plugin
// Media Downloader for BTT Launcher.
// Download video or audio from YouTube, Facebook, Instagram, TikTok and many
// other yt-dlp supported sites using a minimal one-page UI.
//
// Requirements:
// - BetterTouchTool with Swift plugins enabled
// - Homebrew at /opt/homebrew/bin/brew
// - yt-dlp, ffmpeg and ffprobe at /opt/homebrew/bin/
//
// The plugin includes an Update button that can install/update yt-dlp and FFmpeg
// through Homebrew. Only download media you own or have permission to download.

import AppKit
import Foundation
import SwiftUI
import Combine

final class VideoDownloader: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private static let backgroundTaskLock = NSLock()
    private static var backgroundTasks: [Process] = []

    private static func retainBackgroundTask(_ task: Process) {
        backgroundTaskLock.lock()
        backgroundTasks.append(task)
        backgroundTaskLock.unlock()
    }

    private static func releaseBackgroundTask(_ task: Process) {
        backgroundTaskLock.lock()
        backgroundTasks.removeAll { $0 === task }
        backgroundTaskLock.unlock()
    }

    private static func hasRunningBackgroundTasks() -> Bool {
        backgroundTaskLock.lock()
        let hasRunning = backgroundTasks.contains { $0.isRunning }
        backgroundTaskLock.unlock()
        return hasRunning
    }

    func hasRunningBackgroundDownloads() -> Bool {
        VideoDownloader.hasRunningBackgroundTasks()
    }

    func killProcessTree(_ process: Process?) {
        guard let process else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/bin/zsh")
        killer.arguments = ["-lc", "pkill -TERM -P \(pid) 2>/dev/null; kill -TERM \(pid) 2>/dev/null; sleep 0.7; pkill -KILL -P \(pid) 2>/dev/null; kill -KILL \(pid) 2>/dev/null; true"]
        try? killer.run()

        if process.isRunning {
            process.terminate()
        }
    }

    let ytDLP = "/opt/homebrew/bin/yt-dlp"
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    let ffprobe = "/opt/homebrew/bin/ffprobe"
    let brew = "/opt/homebrew/bin/brew"
    let ffmpegLocation = "/opt/homebrew/bin"

    func preferredBrewPath() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func launcherPluginName() -> String { "Media Downloader" }
    static func launcherPluginDescription() -> String { "YouTube, Facebook, Instagram, TikTok and more downloader." }
    static func launcherPluginIcon() -> String { "arrow.down.circle.fill" }
    static func configurationFormItems() -> BTTPluginFormItem? { nil }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = "media-downloader-dashboard"
        result.title = "Media Downloader"
        result.subtitle = firstURL(in: context.query ?? "") == nil ? "YouTube, Facebook, Instagram, TikTok and more downloader" : "URL detected — open media downloader"
        result.systemImageName = "arrow.down.circle.fill"
        result.surfaceIdentifier = "media-downloader-dashboard-surface"
        result.trailingHint = "Open"
        result.keywords = ["youtube", "yt-dlp", "download", "video", "audio", "mp3", "mp4", "media"]
        if firstURL(in: context.query ?? "") != nil { result.searchMatchPriority = NSNumber(value: 95) }
        return [result]
    }

    func launcherSurface(forItemIdentifier itemIdentifier: String, surfaceIdentifier: String?, context: BTTLauncherPluginContext) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard (surfaceIdentifier ?? itemIdentifier) == "media-downloader-dashboard-surface" else { return nil }
        return VideoDownloaderDashboardSurface(plugin: self, context: context)
    }

    func performAction(forItemIdentifier itemIdentifier: String, actionIdentifier: String?, context: BTTLauncherPluginContext) -> BTTLauncherPluginActionResult? {
        let result = BTTLauncherPluginActionResult()
        result.success = true
        result.closeLauncher = false
        result.message = "Open the Media Downloader surface."
        return result
    }

    func suggestedURL(for context: BTTLauncherPluginContext) -> String {
        firstURL(in: context.query ?? "") ?? firstURL(in: NSPasteboard.general.string(forType: .string) ?? "") ?? ""
    }

    func defaultDownloadDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("BTT Media Downloads", isDirectory: true)
    }

    func lastLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BTTMediaDownloader.log")
    }

    func prepareLogFile() -> URL {
        let logURL = lastLogURL()
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { _ = FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        return logURL
    }

    func openDownloadFolder() {
        let folder = defaultDownloadDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func copyLastLog() -> Bool {
        let log = (try? String(contentsOf: lastLogURL(), encoding: .utf8)) ?? "No log found."
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(log, forType: .string)
    }

    func openDownloadedFile(at path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: trimmed))
    }

    @discardableResult
    func startToolCheck(folderPath: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let safeFolder = shellSingleQuote(folderPath)
        let script = """
        set +e
        export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        BREW=""
        [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
        [ -z "$BREW" ] && [ -x /usr/local/bin/brew ] && BREW=/usr/local/bin/brew
        YTDLP="$(command -v yt-dlp)"
        FFMPEG="$(command -v ffmpeg)"
        FFPROBE="$(command -v ffprobe)"
        [ -z "$YTDLP" ] && [ -x /opt/homebrew/bin/yt-dlp ] && YTDLP=/opt/homebrew/bin/yt-dlp
        [ -z "$YTDLP" ] && [ -x /usr/local/bin/yt-dlp ] && YTDLP=/usr/local/bin/yt-dlp
        [ -z "$FFMPEG" ] && [ -x /opt/homebrew/bin/ffmpeg ] && FFMPEG=/opt/homebrew/bin/ffmpeg
        [ -z "$FFMPEG" ] && [ -x /usr/local/bin/ffmpeg ] && FFMPEG=/usr/local/bin/ffmpeg
        [ -z "$FFPROBE" ] && [ -x /opt/homebrew/bin/ffprobe ] && FFPROBE=/opt/homebrew/bin/ffprobe
        [ -z "$FFPROBE" ] && [ -x /usr/local/bin/ffprobe ] && FFPROBE=/usr/local/bin/ffprobe

        echo "Health check"
        if [ -n "$BREW" ]; then echo "✅ Homebrew: $($BREW --version | head -n 1)"; else echo "❌ Homebrew: missing"; fi
        if [ -n "$YTDLP" ]; then echo "✅ yt-dlp: $($YTDLP --version)"; else echo "❌ yt-dlp: missing"; fi
        if [ -n "$FFMPEG" ]; then echo "✅ ffmpeg: $($FFMPEG -version | head -n 1 | sed 's/^ffmpeg version //')"; else echo "❌ ffmpeg: missing"; fi
        if [ -n "$FFPROBE" ]; then echo "✅ ffprobe: installed"; else echo "❌ ffprobe: missing"; fi
        if /usr/bin/curl -Is --max-time 5 https://github.com >/dev/null 2>&1; then echo "✅ Internet: OK"; else echo "⚠️ Internet: could not verify"; fi
        mkdir -p \(safeFolder) 2>/dev/null
        if [ -w \(safeFolder) ]; then echo "✅ Folder: writable"; else echo "❌ Folder: not writable"; fi
        FREE_KB=$(df -k \(safeFolder) 2>/dev/null | tail -1 | awk '{print $4}')
        if [ -n "$FREE_KB" ]; then awk -v kb="$FREE_KB" 'BEGIN { printf "✅ Disk free: %.1f GB\\n", kb/1024/1024 }'; else echo "⚠️ Disk free: unknown"; fi
        [ -n "$YTDLP" ] && [ -n "$FFMPEG" ] && [ -n "$FFPROBE" ] && [ -w \(safeFolder) ]
        """
        return runShell(script: script, progress: progress, completion: completion)
    }

    @discardableResult
    func startToolUpdate(progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let script = """
        set -euo pipefail
        export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        BREW=""
        [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
        [ -z "$BREW" ] && [ -x /usr/local/bin/brew ] && BREW=/usr/local/bin/brew
        if [ -z "$BREW" ]; then
          echo "Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew"
          exit 1
        fi
        "$BREW" update
        "$BREW" list yt-dlp >/dev/null 2>&1 || "$BREW" install yt-dlp
        "$BREW" list ffmpeg >/dev/null 2>&1 || "$BREW" install ffmpeg
        "$BREW" upgrade yt-dlp ffmpeg
        command -v yt-dlp >/dev/null
        command -v ffmpeg >/dev/null
        command -v ffprobe >/dev/null
        """
        return runShell(script: script, progress: progress, completion: completion)
    }

    func fetchThumbnail(for videoURL: String, completion: @escaping (NSImage?) -> Void) {
        guard let validatedURL = validatedHTTPURLString(videoURL),
              FileManager.default.isExecutableFile(atPath: ytDLP) else { completion(nil); return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytDLP)
        task.arguments = [
            "--ignore-config",
            "--no-warnings",
            "--skip-download",
            "--playlist-items", "1",
            "--print", "thumbnail",
            "--", validatedURL
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        var output = Data()
        var didComplete = false
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            if output.count < 64_000 { output.append(data) }
        }

        task.terminationHandler = { process in
            handle.readabilityHandler = nil
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                guard process.terminationStatus == 0,
                      let text = String(data: output, encoding: .utf8),
                      let firstLine = text.components(separatedBy: .newlines)
                        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                        .first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }),
                      let imageURL = URL(string: firstLine) else {
                    completion(nil)
                    return
                }
                URLSession.shared.dataTask(with: imageURL) { data, _, _ in
                    let image = data.flatMap { NSImage(data: $0) }
                    DispatchQueue.main.async { completion(image) }
                }.resume()
            }
        }

        do {
            try task.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) {
                if task.isRunning { task.terminate() }
            }
        } catch {
            handle.readabilityHandler = nil
            completion(nil)
        }
    }

    func fetchMediaMetadata(for mediaURL: String, completion: @escaping (String?, String?, String?) -> Void) {
        guard let validatedURL = validatedHTTPURLString(mediaURL),
              FileManager.default.isExecutableFile(atPath: ytDLP) else {
            completion(nil, nil, nil)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytDLP)
        task.arguments = ["--ignore-config", "--no-warnings", "--skip-download", "--playlist-items", "1", "--dump-single-json", "--", validatedURL]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var title: String?
            var source: String?
            var durationText: String?
            if process.terminationStatus == 0,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                title = object["title"] as? String
                source = (object["channel"] as? String) ?? (object["uploader"] as? String) ?? (object["extractor_key"] as? String)
                if let seconds = (object["duration"] as? NSNumber)?.intValue, seconds > 0 {
                    if seconds >= 3600 {
                        durationText = String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
                    } else {
                        durationText = String(format: "%d:%02d", seconds / 60, seconds % 60)
                    }
                }
            }
            DispatchQueue.main.async { completion(title, source, durationText) }
        }
        do {
            try task.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) {
                if task.isRunning { task.terminate() }
            }
        } catch {
            completion(nil, nil, nil)
        }
    }

    func makeDownloadArguments(mode: DownloadMode, url: String, videoPreset: String, customFormat: String, audioFormat: String, audioQuality: String, cookiesBrowser: String, folder: URL) -> [String]? {
        guard let downloadTarget = normalizedDownloadTarget(url) else { return nil }
        let isPlaylist = validatedHTTPURLString(downloadTarget).map { shouldDownloadPlaylist($0) } ?? false
        let fileNameTemplate = "%(title).180B - %(channel,uploader,creator|Unknown Channel).80B.%(ext)s"
        let outputTemplate = isPlaylist
            ? "%(playlist_title).180B/" + fileNameTemplate
            : fileNameTemplate

        var args = [
            "--ignore-config",
            "--newline",
            "--no-color",
            "--no-warnings",
            "--no-simulate",
            "--progress",
            "--progress-template", "download:download:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes_estimate)s",
            "--print", "after_move:filepath",
            "--ffmpeg-location", ffmpegLocation,
            "-P", folder.path,
            "-o", outputTemplate,
            isPlaylist ? "--yes-playlist" : "--no-playlist"
        ]

        if let browser = cookiesBrowserArgument(cookiesBrowser) {
            args += ["--cookies-from-browser", browser]
        }

        switch mode {
        case .video:
            let format = videoFormatSelector(preset: videoPreset, customFormat: customFormat)
            args += ["-f", format.selector]
            if let merge = format.mergeFormat { args += ["--merge-output-format", merge] }
        case .audio:
            let formatMap = ["MP3": "mp3", "M4A": "m4a", "WAV": "wav", "Opus": "opus", "FLAC": "flac"]
            args += ["-x", "--audio-format", formatMap[audioFormat] ?? "mp3", "--add-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg"]
            if audioFormat != "WAV" && audioFormat != "FLAC" {
                let qualityMap = ["Best": "0", "320 kbps": "320K", "256 kbps": "256K", "192 kbps": "192K", "128 kbps": "128K"]
                args += ["--audio-quality", qualityMap[audioQuality] ?? "0"]
            }
        }
        args += ["--", downloadTarget]
        return args
    }

    func estimateDownloadSize(mode: DownloadMode, url: String, videoPreset: String, customFormat: String, audioFormat: String, cookiesBrowser: String = "None", completion: @escaping (Int64?, Int?) -> Void) -> Process? {
        guard let validatedURL = validatedHTTPURLString(url), FileManager.default.isExecutableFile(atPath: ytDLP) else {
            completion(nil, nil)
            return nil
        }

        var args = [
            "--ignore-config",
            "--no-warnings",
            "--skip-download",
            "--dump-single-json",
            "--ffmpeg-location", ffmpegLocation,
            shouldDownloadPlaylist(validatedURL) ? "--yes-playlist" : "--no-playlist"
        ]

        if let browser = cookiesBrowserArgument(cookiesBrowser) {
            args += ["--cookies-from-browser", browser]
        }

        switch mode {
        case .video:
            args += ["-f", videoFormatSelector(preset: videoPreset, customFormat: customFormat).selector]
        case .audio:
            args += ["-f", "bestaudio/best"]
        }
        args += ["--", validatedURL]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytDLP)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        var output = Data()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            if output.count < 8_000_000 { output.append(data) }
        }

        task.terminationHandler = { process in
            handle.readabilityHandler = nil
            let size: Int64?
            let playlistCount: Int?
            if process.terminationStatus == 0,
               let object = try? JSONSerialization.jsonObject(with: output) {
                size = self.estimatedBytes(from: object)
                playlistCount = self.playlistItemCount(from: object)
            } else {
                size = nil
                playlistCount = nil
            }
            DispatchQueue.main.async { completion(size, playlistCount) }
        }

        do {
            try task.run()
            return task
        } catch {
            handle.readabilityHandler = nil
            completion(nil, nil)
            return nil
        }
    }

    private func playlistItemCount(from object: Any) -> Int? {
        guard let dictionary = object as? [String: Any], let entries = dictionary["entries"] as? [Any] else { return nil }
        let count = entries.filter { !($0 is NSNull) }.count
        return count > 1 ? count : nil
    }

    private func estimatedBytes(from object: Any) -> Int64? {
        if let dictionary = object as? [String: Any] {
            if let entries = dictionary["entries"] as? [Any] {
                let values = entries.compactMap { estimatedBytes(from: $0) }
                return values.isEmpty ? nil : values.reduce(0, +)
            }
            if let requested = dictionary["requested_formats"] as? [Any] {
                let values = requested.compactMap { estimatedBytes(from: $0) }
                return values.isEmpty ? directFileSize(from: dictionary) : values.reduce(0, +)
            }
            return directFileSize(from: dictionary)
        }
        return nil
    }

    private func directFileSize(from dictionary: [String: Any]) -> Int64? {
        for key in ["filesize", "filesize_approx"] {
            if let number = dictionary[key] as? NSNumber, number.int64Value > 0 { return number.int64Value }
            if let int = dictionary[key] as? Int64, int > 0 { return int }
            if let double = dictionary[key] as? Double, double > 0 { return Int64(double) }
        }
        return nil
    }

    func runYTDLP(arguments: [String], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let missing = [ytDLP, ffmpeg, ffprobe].filter { !FileManager.default.isExecutableFile(atPath: $0) }
        guard missing.isEmpty else {
            progress("Missing tools: " + missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
            completion(false)
            return nil
        }
        return runProcess(executable: ytDLP, arguments: arguments, progress: progress, completion: completion)
    }

    @discardableResult
    private func runShell(script: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        runProcess(executable: "/bin/zsh", arguments: ["-lc", script], progress: progress, completion: completion)
    }

    private func runProcess(executable: String, arguments: [String], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let logURL = prepareLogFile()
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let file = try? FileHandle(forWritingTo: logURL) {
                try? file.seekToEnd()
                if let d = text.data(using: .utf8) { try? file.write(contentsOf: d) }
                try? file.close()
            }
            DispatchQueue.main.async { progress(text) }
        }
        task.terminationHandler = { process in
            handle.readabilityHandler = nil
            VideoDownloader.releaseBackgroundTask(process)
            DispatchQueue.main.async { completion(process.terminationStatus == 0) }
        }
        do {
            try task.run()
            VideoDownloader.retainBackgroundTask(task)
            return task
        } catch {
            progress("Could not start: \(error.localizedDescription)")
            completion(false)
            return nil
        }
    }

    private func videoFormatSelector(preset: String, customFormat: String) -> (selector: String, mergeFormat: String?) {
        if preset == "Custom yt-dlp selector" { return (customFormat.isEmpty ? "bestvideo+bestaudio/best" : customFormat, nil) }
        let components = preset.components(separatedBy: " | ")
        let quality = components.first ?? "1080p"
        let container = components.count > 1 ? components[1] : "MP4"
        let heights = ["2160p / 4K": 2160, "1440p / 2K": 1440, "1080p": 1080, "720p": 720, "480p": 480, "360p": 360]
        let cap = heights[quality].map { "[height<=\($0)]" } ?? ""
        switch container {
        case "MP4": return ("bestvideo\(cap)[ext=mp4]+bestaudio[ext=m4a]/best\(cap)[ext=mp4]/best\(cap)", "mp4")
        case "MKV": return ("bestvideo\(cap)+bestaudio/best\(cap)/best", "mkv")
        case "WebM": return ("bestvideo\(cap)[ext=webm]+bestaudio[ext=webm]/best\(cap)[ext=webm]/best\(cap)", "webm")
        default: return ("bestvideo\(cap)+bestaudio/best\(cap)/best", nil)
        }
    }

    func willDownloadPlaylist(_ url: String) -> Bool {
        guard let validatedURL = validatedHTTPURLString(url) else { return false }
        return shouldDownloadPlaylist(validatedURL)
    }

    func isSpotifyURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased() else { return false }
        return host == "open.spotify.com" || host.hasSuffix(".spotify.com")
    }

    func spotifyURLKind(_ raw: String) -> String? {
        guard isSpotifyURL(raw),
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        return parts.first?.lowercased()
    }

    func normalizedDownloadTarget(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("ytsearch") { return trimmed }
        if let url = validatedHTTPURLString(trimmed) { return url }
        // Plain text search support: let yt-dlp search YouTube and download the best first match.
        // This allows typing e.g. "daft punk around the world" instead of pasting a URL.
        return "ytsearch1:\(trimmed)"
    }

    func resolveSpotifyToYouTubeSearch(_ spotifyURL: String, completion: @escaping (String?) -> Void) {
        let trimmed = spotifyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSpotifyURL(trimmed),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://open.spotify.com/oembed?url=\(encoded)") else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            var query: String?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = object["title"] as? String {
                query = title
                    .replacingOccurrences(of: " - song and lyrics by ", with: " ", options: [.caseInsensitive])
                    .replacingOccurrences(of: " song and lyrics by ", with: " ", options: [.caseInsensitive])
                    .replacingOccurrences(of: " | Spotify", with: "", options: [.caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let query, !query.isEmpty {
                completion("ytsearch1:\(query) audio")
            } else {
                completion(nil)
            }
        }.resume()
    }

    func validatedHTTPURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty,
              let url = components.url else { return nil }
        return url.absoluteString
    }

    private func shellSingleQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func cookiesBrowserArgument(_ browser: String) -> String? {
        switch browser.lowercased() {
        case "safari": return "safari"
        case "chrome": return "chrome"
        case "edge": return "edge"
        case "firefox": return "firefox"
        case "brave": return "brave"
        default: return nil
        }
    }

    private func shouldDownloadPlaylist(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let items = components.queryItems else { return false }
        return items.contains { $0.name.lowercased() == "list" && !($0.value ?? "").isEmpty }
    }

    private func firstURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'"))
            if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") { return String(cleaned) }
        }
        return nil
    }
}

enum DownloadMode: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    var id: String { rawValue }
}

final class VideoDownloaderDashboardSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private weak var plugin: VideoDownloader?
    private let context: BTTLauncherPluginContext
    private var model: VideoDownloaderViewModel?
    private var controlKeyWasDown = false
    private var optionKeyWasDown = false
    private var modifierEventMonitor: Any?

    init(plugin: VideoDownloader, context: BTTLauncherPluginContext) {
        self.plugin = plugin
        self.context = context
        super.init()
    }

    func makeLauncherSurfaceView() -> NSView {
        let model = VideoDownloaderViewModel(plugin: plugin, context: context)
        self.model = model
        return NSHostingView(rootView: VideoDownloaderDashboardView(model: model))
    }

    func launcherSurfaceDidAppear() {
        model?.loadURLFromClipboardIfNeeded()
        modifierEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            _ = self?.handleModifierFlags(event)
            return event
        }
    }

    func launcherSurfaceWillDisappear() {
        if let modifierEventMonitor {
            NSEvent.removeMonitor(modifierEventMonitor)
            self.modifierEventMonitor = nil
        }
        controlKeyWasDown = false
        optionKeyWasDown = false
        // Do not cancel downloads here. Closing the launcher with Escape should let yt-dlp continue in the background.
    }

    private func handleModifierFlags(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let controlIsDown = flags.contains(.control)
        let optionIsDown = flags.contains(.option)

        if controlIsDown && !controlKeyWasDown {
            controlKeyWasDown = true
            model?.cycleFormat(backwards: flags.contains(.shift))
            return true
        }

        if optionIsDown && !optionKeyWasDown {
            optionKeyWasDown = true
            model?.cycleQuality(backwards: flags.contains(.shift))
            return true
        }

        controlKeyWasDown = controlIsDown
        optionKeyWasDown = optionIsDown
        return false
    }

    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            return handleModifierFlags(event)
        }

        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 36, 76: // Return / Enter
            model?.start()
            return true
        case 48: // Tab switches mode reliably inside BTT Launcher
            model?.toggleMode()
            return true
        default:
            return false
        }
    }

    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Let the launcher's text input keep normal cursor movement/editing.
        // This prevents the surface from stealing arrow-key navigation while editing pasted/search text.
        switch event.keyCode {
        case 123, 124, 125, 126: // Left, Right, Down, Up
            return true
        default:
            return false
        }
    }

    func launcherSurfaceQueryDidChange(_ query: String?) {
        model?.updateURLFromLauncherQuery(query)
    }

    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 850, height: 450) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 760, height: 420) }
    func launcherSurfacePlaceholderText() -> String? { "Paste URL, search text, or multi-line song list" }
    func launcherSurfaceFooterHint() -> String? { nil }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
}

final class VideoDownloaderViewModel: ObservableObject {
    @Published var mode: DownloadMode = .video
    @Published var url: String
    @Published var videoPreset = "Best available | Original"
    @Published var customFormat = "bestvideo+bestaudio/best"
    @Published var audioFormat = "MP3"
    @Published var audioQuality = "Best"
    @Published var cookiesBrowser = "None"
    @Published var folderPath: String
    @Published var recentFolders: [String] = []
    @Published var status = "Ready"
    @Published var detail = "Paste a URL and choose a format."
    @Published var progress: Double = 0
    @Published var overallProgress: Double = 0
    @Published var speed = "—"
    @Published var eta = "—"
    @Published var isRunning = false
    @Published var thumbnail: NSImage?
    @Published var sizeEstimate = "Size: —"
    @Published var playlistCounter = ""
    @Published var queueStatus = ""
    @Published var healthStatus = ""
    @Published var lastDownloadedFile = ""
    @Published var transferredBytes: Int64?
    @Published var totalBytes: Int64?
    @Published var jobSummary = ""
    @Published var technicalDetails = ""
    @Published var mediaTitle = ""
    @Published var mediaSource = ""
    @Published var mediaDuration = ""

    let videoPresets = ["Best available | Original", "2160p / 4K", "1440p / 2K", "1080p", "720p", "480p", "360p", "1080p | MKV", "720p | WebM", "Custom yt-dlp selector"]
    let audioFormats = ["MP3", "M4A", "WAV", "Opus", "FLAC"]
    let audioQualities = ["Best", "320 kbps", "256 kbps", "192 kbps", "128 kbps"]
    let cookiesBrowsers = ["None", "Safari", "Chrome", "Edge", "Firefox", "Brave"]
    let chooseFolderMenuValue = "__choose_folder__"

    private static let backgroundModelLock = NSLock()
    private static var backgroundModels: [ObjectIdentifier: VideoDownloaderViewModel] = [:]

    private func retainForBackgroundDownload() {
        let id = ObjectIdentifier(self)
        Self.backgroundModelLock.lock()
        Self.backgroundModels[id] = self
        Self.backgroundModelLock.unlock()
    }

    private func releaseFromBackgroundDownload() {
        let id = ObjectIdentifier(self)
        Self.backgroundModelLock.lock()
        Self.backgroundModels.removeValue(forKey: id)
        Self.backgroundModelLock.unlock()
    }

    private weak var plugin: VideoDownloader?
    private let defaults = UserDefaults.standard
    private enum DefaultsKey {
        static let mode = "MediaDownloader.mode"
        static let videoPreset = "MediaDownloader.videoPreset"
        static let customFormat = "MediaDownloader.customFormat"
        static let audioFormat = "MediaDownloader.audioFormat"
        static let audioQuality = "MediaDownloader.audioQuality"
        static let cookiesBrowser = "MediaDownloader.cookiesBrowser"
        static let lastDownloadedFile = "MediaDownloader.lastDownloadedFile"
        static let folderPath = "MediaDownloader.folderPath"
        static let recentFolders = "MediaDownloader.recentFolders"
    }
    private var task: Process?
    private var estimateTask: Process?
    private var progressTimer: Timer?
    private var backgroundLogPollingTimer: Timer?
    private var cancellationRequested = false
    private var playlistCurrentItem = 0
    private var playlistTotalItems = 0
    private var queuedURLs: [String] = []
    private var queueCompleted = 0
    private var queueTotal = 0
    private var queueSubfolderName: String?
    private var lastThumbnailURL = ""
    private var lastEstimateKey = ""

    init(plugin: VideoDownloader?, context: BTTLauncherPluginContext) {
        self.plugin = plugin
        self.url = plugin?.suggestedURL(for: context) ?? ""

        let defaultFolder = plugin?.defaultDownloadDirectory().path ?? ""
        self.folderPath = defaults.string(forKey: DefaultsKey.folderPath) ?? defaultFolder
        self.mode = DownloadMode(rawValue: defaults.string(forKey: DefaultsKey.mode) ?? "") ?? .video

        let savedVideoPreset = defaults.string(forKey: DefaultsKey.videoPreset)
        if let savedVideoPreset, videoPresets.contains(savedVideoPreset) { self.videoPreset = savedVideoPreset }
        self.customFormat = defaults.string(forKey: DefaultsKey.customFormat) ?? self.customFormat

        let savedAudioFormat = defaults.string(forKey: DefaultsKey.audioFormat)
        if let savedAudioFormat, audioFormats.contains(savedAudioFormat) { self.audioFormat = savedAudioFormat }

        let savedAudioQuality = defaults.string(forKey: DefaultsKey.audioQuality)
        if let savedAudioQuality, audioQualities.contains(savedAudioQuality) { self.audioQuality = savedAudioQuality }

        let savedCookiesBrowser = defaults.string(forKey: DefaultsKey.cookiesBrowser)
        if let savedCookiesBrowser, cookiesBrowsers.contains(savedCookiesBrowser) { self.cookiesBrowser = savedCookiesBrowser }
        self.lastDownloadedFile = defaults.string(forKey: DefaultsKey.lastDownloadedFile) ?? ""

        let savedFolders = defaults.stringArray(forKey: DefaultsKey.recentFolders) ?? []
        self.recentFolders = normalizedRecentFolders([self.folderPath] + savedFolders + [defaultFolder])
        saveSettings()
        refreshThumbnailIfNeeded()
        refreshSizeEstimateIfNeeded()
        restoreBackgroundDownloadIfNeeded()
    }

    func updateURLFromLauncherQuery(_ query: String?) {
        guard let plugin else { return }
        let rawQuery = query ?? ""
        let urls = allURLCandidates(in: rawQuery)
        if urls.count > 1 {
            queuedURLs = urls
            queueCompleted = 0
            queueTotal = urls.count
            queueSubfolderName = nil
            queueStatus = "0 of \(urls.count)"
            url = urls[0]
            status = "Queue ready"
            detail = "\(urls.count) URLs loaded. Press Enter to start queue."
            refreshThumbnailIfNeeded()
            refreshSizeEstimateIfNeeded()
            return
        }

        let searches = allSearchCandidates(in: rawQuery)
        if urls.isEmpty, searches.count > 1 {
            queuedURLs = searches
            queueCompleted = 0
            queueTotal = searches.count
            queueSubfolderName = textPlaylistFolderName(from: searches)
            queueStatus = "0 of \(searches.count)"
            url = searches[0]
            status = "Text playlist ready"
            detail = "\(searches.count) search lines loaded. Press Enter to download them in order."
            thumbnail = nil
            refreshSizeEstimateIfNeeded()
            return
        }
        let candidate = urls.first ?? ""
        if !candidate.isEmpty, plugin.validatedHTTPURLString(candidate) != nil, candidate != url {
            queuedURLs = []
            queueCompleted = 0
            queueTotal = 0
            queueStatus = ""
            url = candidate
            status = "URL ready"
            detail = "URL taken from launcher input."
            refreshThumbnailIfNeeded()
            refreshSizeEstimateIfNeeded()
            return
        }

        let searchText = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty, plugin.normalizedDownloadTarget(searchText) != nil, searchText != url else { return }
        queuedURLs = []
        queueCompleted = 0
        queueTotal = 0
        queueSubfolderName = nil
        queueStatus = ""
        url = searchText
        status = "Search ready"
        detail = "Press Enter to search YouTube and download the first result."
        thumbnail = nil
        refreshSizeEstimateIfNeeded()
    }

    func loadURLFromClipboardIfNeeded() {
        guard let plugin else { return }
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        let urls = allURLCandidates(in: clipboardText)

        // Always prefer a multi-URL clipboard, even if a previous single URL is already loaded.
        // This makes copying a batch and reopening/pressing Enter reliably switch to queue mode.
        if urls.count > 1 {
            queuedURLs = urls
            queueCompleted = 0
            queueTotal = urls.count
            queueSubfolderName = nil
            queueStatus = "0 of \(urls.count)"
            url = urls[0]
            status = "Clipboard queue ready"
            detail = "\(urls.count) clipboard URLs loaded. Press Enter to start queue."
            refreshThumbnailIfNeeded()
            refreshSizeEstimateIfNeeded()
            return
        }

        let searches = allSearchCandidates(in: clipboardText)
        if urls.isEmpty, searches.count > 1 {
            queuedURLs = searches
            queueCompleted = 0
            queueTotal = searches.count
            queueSubfolderName = textPlaylistFolderName(from: searches)
            queueStatus = "0 of \(searches.count)"
            url = searches[0]
            status = "Clipboard text playlist ready"
            detail = "\(searches.count) search lines loaded. Press Enter to download them in order."
            thumbnail = nil
            refreshSizeEstimateIfNeeded()
            return
        }

        let current = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if plugin.validatedHTTPURLString(current) != nil {
            status = queuedURLs.count > 1 ? "Queue ready" : "URL ready"
            detail = queuedURLs.count > 1 ? "\(queuedURLs.count) URLs loaded. Press Enter to start queue." : "URL loaded. Press Enter to download."
            return
        }

        guard let firstURL = urls.first else { return }
        url = firstURL
        queuedURLs = []
        queueCompleted = 0
        queueTotal = 0
        queueSubfolderName = nil
        queueStatus = ""
        status = "Clipboard URL ready"
        detail = "URL was loaded from clipboard. Press Enter to download."
        refreshThumbnailIfNeeded()
        refreshSizeEstimateIfNeeded()
    }

    private func allURLCandidates(in text: String) -> [String] {
        guard let plugin else { return [] }
        var seen = Set<String>()
        var results: [String] = []
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]{}\"']+"#, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            var candidate = String(text[range])
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>'\""))
            guard plugin.validatedHTTPURLString(candidate) != nil, !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            results.append(candidate)
        }
        return results
    }

    private func allSearchCandidates(in text: String) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            guard cleaned.count >= 2 else { continue }
            guard plugin?.validatedHTTPURLString(cleaned) == nil else { continue }
            guard !cleaned.lowercased().hasPrefix("http://"), !cleaned.lowercased().hasPrefix("https://") else { continue }
            guard !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            results.append(cleaned)
        }
        return results
    }

    private func textPlaylistFolderName(from searches: [String]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Media Playlist \(formatter.string(from: Date()))"
    }

    private func bestURLCandidate(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if plugin?.validatedHTTPURLString(trimmed) != nil { return trimmed }
        for token in trimmed.split(whereSeparator: { $0.isWhitespace }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\\\"'"))
            if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") { return String(cleaned) }
        }
        return ""
    }

    func refreshThumbnailIfNeeded() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastThumbnailURL, !trimmed.isEmpty else { return }
        lastThumbnailURL = trimmed
        mediaTitle = ""
        mediaSource = ""
        mediaDuration = ""
        plugin?.fetchThumbnail(for: trimmed) { [weak self] image in self?.thumbnail = image }
        plugin?.fetchMediaMetadata(for: trimmed) { [weak self] title, source, duration in
            guard let self, self.lastThumbnailURL == trimmed else { return }
            self.mediaTitle = title ?? ""
            self.mediaSource = source ?? ""
            self.mediaDuration = duration ?? ""
        }
    }

    func refreshSizeEstimateIfNeeded() {
        guard let plugin else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = [trimmed, mode.rawValue, videoPreset, customFormat, audioFormat, audioQuality, cookiesBrowser].joined(separator: "|")
        guard key != lastEstimateKey else { return }
        lastEstimateKey = key

        guard plugin.validatedHTTPURLString(trimmed) != nil else {
            estimateTask?.terminate()
            estimateTask = nil
            if plugin.isSpotifyURL(trimmed) {
                let kind = plugin.spotifyURLKind(trimmed) ?? "link"
                sizeEstimate = kind == "track" ? "Spotify track → YouTube" : "Spotify \(kind) not supported"
            } else if plugin.normalizedDownloadTarget(trimmed)?.lowercased().hasPrefix("ytsearch") == true {
                sizeEstimate = "YouTube search → first result"
            } else {
                sizeEstimate = "Size: —"
            }
            playlistCounter = ""
            return
        }

        estimateTask?.terminate()
        sizeEstimate = "Estimating size…"
        estimateTask = plugin.estimateDownloadSize(mode: mode, url: trimmed, videoPreset: videoPreset, customFormat: customFormat, audioFormat: audioFormat, cookiesBrowser: cookiesBrowser) { [weak self] bytes, playlistCount in
            guard let self, self.lastEstimateKey == key else { return }
            if let playlistCount, playlistCount > 1 {
                self.playlistCounter = "0 of \(playlistCount)"
            } else if !self.isRunning {
                self.playlistCounter = ""
            }
            if let bytes, bytes > 0 {
                let approx = self.mode == .audio ? "Approx. audio size" : "Approx. size"
                self.sizeEstimate = "\(approx): \(self.formatBytes(bytes))"
            } else {
                self.sizeEstimate = "Size: unknown"
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 { return String(format: "%.2f GB", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return "\(bytes) B"
    }

    func start() {
        guard !isRunning else { return }
        if queuedURLs.count > 1 {
            startQueue()
            return
        }
        startSingleDownload(url.trimmingCharacters(in: .whitespacesAndNewlines), queueMode: false, completion: nil)
    }

    private func startQueue() {
        guard !queuedURLs.isEmpty else { return }
        retainForBackgroundDownload()
        cancellationRequested = false
        queueCompleted = 0
        queueTotal = queuedURLs.count
        queueStatus = "0 of \(queueTotal)"
        overallProgress = 0
        isRunning = true
        startNextQueueItem()
    }

    private func startNextQueueItem() {
        guard !cancellationRequested else { finishQueue(cancelled: true); return }
        guard queueCompleted < queuedURLs.count else { finishQueue(cancelled: false); return }
        let currentURL = queuedURLs[queueCompleted]
        url = currentURL
        queueStatus = "\(queueCompleted) of \(queueTotal)"
        status = "Queue item \(queueCompleted + 1) of \(queueTotal)"
        startSingleDownload(currentURL, queueMode: true) { [weak self] success in
            guard let self else { return }
            if self.cancellationRequested { self.finishQueue(cancelled: true); return }
            self.queueCompleted += 1
            self.queueStatus = "\(self.queueCompleted) of \(self.queueTotal)"
            self.overallProgress = Double(self.queueCompleted) / Double(max(self.queueTotal, 1))
            if !success {
                self.detail = "One queue item failed; continuing with next URL."
            }
            self.startNextQueueItem()
        }
    }

    private func finishQueue(cancelled: Bool) {
        isRunning = false
        stopLiveProgress()
        stopBackgroundLogPolling()
        releaseFromBackgroundDownload()
        if cancelled {
            status = "Queue cancelled"
            detail = "Stopped at \(queueCompleted) of \(queueTotal)."
        } else {
            progress = 1
            overallProgress = 1
            status = "Queue finished"
            detail = "Downloaded \(queueCompleted) of \(queueTotal) queued URLs."
            queueStatus = "\(queueCompleted) of \(queueTotal)"
        }
    }

    private func startSingleDownload(_ downloadURL: String, queueMode: Bool, completion: ((Bool) -> Void)?) {
        guard let plugin else { fail("Plugin not available."); completion?(false); return }
        let trimmed = downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if plugin.isSpotifyURL(trimmed) {
            let kind = plugin.spotifyURLKind(trimmed) ?? ""
            guard kind == "track" else {
                let label = kind.isEmpty ? "Spotify link" : "Spotify \(kind)"
                fail("\(label.capitalized) is not supported for auto YouTube matching yet. Paste individual Spotify track links, normal media URLs, or an exported artist/title list.")
                completion?(false)
                return
            }
            status = "Resolving Spotify track…"
            detail = "Using Spotify track metadata to search YouTube for a matching audio result."
            plugin.resolveSpotifyToYouTubeSearch(trimmed) { [weak self] target in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let target else {
                        self.fail("Could not resolve Spotify metadata. Paste artist + song title or use a normal media URL.")
                        completion?(false)
                        return
                    }
                    self.startSingleDownload(target, queueMode: queueMode, completion: completion)
                }
            }
            return
        }
        guard plugin.normalizedDownloadTarget(trimmed) != nil else { fail("Paste a URL, Spotify track, or type search text."); completion?(false); return }
        url = trimmed
        refreshThumbnailIfNeeded()
        refreshSizeEstimateIfNeeded()
        let baseFolder = URL(fileURLWithPath: folderPath.isEmpty ? plugin.defaultDownloadDirectory().path : folderPath, isDirectory: true)
        let folder = queueMode && queueSubfolderName != nil
            ? baseFolder.appendingPathComponent(queueSubfolderName ?? "Text Playlist", isDirectory: true)
            : baseFolder
        rememberFolder(baseFolder.path)
        saveSettings()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let args = plugin.makeDownloadArguments(mode: mode, url: trimmed, videoPreset: videoPreset, customFormat: customFormat, audioFormat: audioFormat, audioQuality: audioQuality, cookiesBrowser: cookiesBrowser, folder: folder) else {
            fail("Please paste a valid http(s) URL.")
            completion?(false)
            return
        }

        if !queueMode {
            retainForBackgroundDownload()
        }

        progress = 0
        playlistCurrentItem = 0
        playlistTotalItems = 0
        speed = "—"
        eta = "—"
        transferredBytes = nil
        totalBytes = nil
        technicalDetails = ""
        let selectedFormat = mode == .video ? videoPreset : audioFormat
        let selectedQuality = mode == .video ? videoPreset : ((audioFormat == "WAV" || audioFormat == "FLAC") ? "Lossless conversion" : audioQuality)
        jobSummary = "\(mode.rawValue) • \(selectedFormat) • \(selectedQuality) • \(baseFolder.lastPathComponent)"
        playlistCounter = queueMode ? playlistCounter : ""
        cancellationRequested = false
        isRunning = true
        beginLiveProgress()
        status = queueMode ? "Queue item \(queueCompleted + 1) of \(queueTotal)" : (mode == .video ? "Downloading video…" : "Downloading audio…")
        detail = plugin.normalizedDownloadTarget(trimmed)?.lowercased().hasPrefix("ytsearch") == true ? "Searching YouTube for best matching result." : (plugin.willDownloadPlaylist(trimmed) ? "Starting playlist download into its own folder." : "Starting yt-dlp.")
        task = plugin.runYTDLP(arguments: args, progress: { [weak self] text in self?.consumeOutput(text) }, completion: { [weak self] success in
            guard let self else { return }
            self.stopLiveProgress()
            self.stopBackgroundLogPolling()
            if self.cancellationRequested {
                if queueMode { completion?(false); return }
                self.isRunning = false
                self.status = "Cancelled"
                self.detail = "The active operation was stopped."
                self.cancellationRequested = false
                self.releaseFromBackgroundDownload()
                return
            }
            self.progress = success ? 1 : self.progress
            self.updateOverallProgressFromCurrentItem()
            if queueMode {
                completion?(success)
            } else {
                self.isRunning = false
                self.overallProgress = success ? 1 : self.overallProgress
                self.status = success ? "Completed" : "Failed"
                self.detail = success ? "File is ready." : "Download failed. Open details or copy the log, then retry."
                self.releaseFromBackgroundDownload()
            }
        })
    }

    func cancel() {
        cancellationRequested = true
        queuedURLs.removeAll()
        queueSubfolderName = nil
        status = queueTotal > 1 ? "Cancelling queue…" : "Cancelling…"
        detail = queueTotal > 1 ? "Killing the active queue and child processes." : "Killing the active process and child processes."

        if let task {
            plugin?.killProcessTree(task)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.cancellationRequested else { return }
            self.task = nil
            self.isRunning = false
            self.stopLiveProgress()
            self.stopBackgroundLogPolling()
            self.status = "Cancelled"
            self.detail = "Process was killed."
            self.cancellationRequested = false
            self.releaseFromBackgroundDownload()
        }
    }

    func checkTools() {
        guard !isRunning else { return }
        guard let plugin else { fail("Plugin not available."); return }
        cancellationRequested = false
        isRunning = true
        progress = 0
        overallProgress = 0
        beginLiveProgress()
        status = "Checking tools…"
        detail = "Checking Homebrew, yt-dlp, FFmpeg, internet, folder and disk space."
        healthStatus = "Checking…"
        let path = folderPath.isEmpty ? plugin.defaultDownloadDirectory().path : folderPath
        task = plugin.startToolCheck(folderPath: path, progress: { [weak self] text in
            self?.healthStatus = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(6).joined(separator: " • ")
            self?.consumeOutput(text)
        }, completion: { [weak self] success in
            guard let self else { return }
            self.isRunning = false
            self.stopLiveProgress()
            self.stopBackgroundLogPolling()
            self.progress = success ? 1 : 0
            self.overallProgress = success ? 1 : 0
            self.status = success ? "Health OK" : "Needs attention"
            self.detail = success ? "All required downloader tools look ready." : "Something is missing or not writable. See status / Log."
        })
    }

    func updateTools() {
        guard !isRunning else { return }
        guard let plugin else { fail("Plugin not available."); return }
        cancellationRequested = false
        isRunning = true
        progress = 0
        beginLiveProgress()
        status = "Updating tools…"
        detail = "Homebrew is installing/updating yt-dlp and FFmpeg."
        task = plugin.startToolUpdate(progress: { [weak self] text in self?.consumeOutput(text) }, completion: { [weak self] success in
            guard let self else { return }
            self.isRunning = false
            self.stopLiveProgress()
            self.stopBackgroundLogPolling()
            if self.cancellationRequested {
                self.status = "Cancelled"
                self.detail = "The update was stopped."
                self.cancellationRequested = false
                return
            }
            self.progress = success ? 1 : 0
            self.overallProgress = success ? 1 : 0
            self.status = success ? "Tools updated" : "Tool update failed"
            self.detail = success ? "yt-dlp and FFmpeg are ready." : "Copy Last Log for details."
            if success { self.checkTools() }
        })
    }

    func folderSelectionChanged() {
        if folderPath == chooseFolderMenuValue {
            folderPath = recentFolders.first ?? plugin?.defaultDownloadDirectory().path ?? ""
            chooseFolder()
        } else {
            rememberFolder(folderPath)
            saveSettings()
        }
    }

    func openCurrentFolder() {
        let path = folderPath.isEmpty ? plugin?.defaultDownloadDirectory().path ?? "" : folderPath
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            rememberFolder(url.path)
            saveSettings()
        }
    }

    func toggleMode() {
        mode = mode == .video ? .audio : .video
        saveSettings()
    }

    func cycleFormat(backwards: Bool = false) {
        if mode == .video {
            guard let current = videoPresets.firstIndex(of: videoPreset) else {
                videoPreset = videoPresets.first ?? videoPreset
                return
            }
            let next = backwards
                ? (current - 1 + videoPresets.count) % videoPresets.count
                : (current + 1) % videoPresets.count
            videoPreset = videoPresets[next]
            saveSettings()
        } else {
            guard let current = audioFormats.firstIndex(of: audioFormat) else {
                audioFormat = audioFormats.first ?? audioFormat
                return
            }
            let next = backwards
                ? (current - 1 + audioFormats.count) % audioFormats.count
                : (current + 1) % audioFormats.count
            audioFormat = audioFormats[next]
            saveSettings()
        }
    }

    func cycleQuality(backwards: Bool = false) {
        if mode == .video {
            let videoQualityPresets = ["Best available | Original", "2160p / 4K", "1440p / 2K", "1080p", "720p", "480p", "360p"]
            let currentPreset = videoQualityPresets.contains(videoPreset) ? videoPreset : "Best available | Original"
            guard let current = videoQualityPresets.firstIndex(of: currentPreset) else { return }
            let next = backwards
                ? (current - 1 + videoQualityPresets.count) % videoQualityPresets.count
                : (current + 1) % videoQualityPresets.count
            videoPreset = videoQualityPresets[next]
        } else {
            guard let current = audioQualities.firstIndex(of: audioQuality) else {
                audioQuality = audioQualities.first ?? audioQuality
                return
            }
            let next = backwards
                ? (current - 1 + audioQualities.count) % audioQualities.count
                : (current + 1) % audioQualities.count
            audioQuality = audioQualities[next]
        }
        saveSettings()
    }

    func saveSettings() {
        defaults.set(mode.rawValue, forKey: DefaultsKey.mode)
        defaults.set(videoPreset, forKey: DefaultsKey.videoPreset)
        defaults.set(customFormat, forKey: DefaultsKey.customFormat)
        defaults.set(audioFormat, forKey: DefaultsKey.audioFormat)
        defaults.set(audioQuality, forKey: DefaultsKey.audioQuality)
        defaults.set(cookiesBrowser, forKey: DefaultsKey.cookiesBrowser)
        defaults.set(lastDownloadedFile, forKey: DefaultsKey.lastDownloadedFile)
        defaults.set(folderPath, forKey: DefaultsKey.folderPath)
        defaults.set(recentFolders, forKey: DefaultsKey.recentFolders)
    }

    private func rememberFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folderPath = trimmed
        recentFolders = normalizedRecentFolders([trimmed] + recentFolders)
    }

    private func normalizedRecentFolders(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for folder in folders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
            if result.count == 3 { break }
        }
        return result
    }

    func copyLog() {
        if plugin?.copyLastLog() == true {
            status = "Log copied"
            detail = "The last log is now on your clipboard."
        } else { fail("Could not copy the log.") }
    }

    func openLastFile() {
        if plugin?.openDownloadedFile(at: lastDownloadedFile) == true {
            status = "Opened file"
            detail = URL(fileURLWithPath: lastDownloadedFile).lastPathComponent
        } else {
            fail("No completed file found yet.")
        }
    }

    private func consumeOutput(_ text: String) {
        noteActivity()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("download:") {
                let payload = String(line.dropFirst("download:".count))
                let parts = payload.components(separatedBy: "|")
                if parts.count >= 3 {
                    let downloaded = parts.count > 3 ? Int64(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                    let total = parts.count > 4 ? Int64(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                    updateProgress(percent: parts[0], speedText: parts[1], etaText: parts[2], downloadedBytes: downloaded, totalBytes: total)
                }
            } else if updatePlaylistCounter(from: line) {
                continue
            } else if let percentRange = line.range(of: #"\d+(?:\.\d+)?%"#, options: .regularExpression) {
                let percentText = String(line[percentRange])
                let speedText = firstMatch(in: line, pattern: #"at\s+([^\s]+/s)"#) ?? speed
                let etaText = firstMatch(in: line, pattern: #"ETA\s+([^\s]+)"#) ?? eta
                updateProgress(percent: percentText, speedText: speedText, etaText: etaText, downloadedBytes: nil, totalBytes: nil)
            } else if line.hasPrefix("/") || line.contains(".mp4") || line.contains(".webm") || line.contains(".mp3") || line.contains(".m4a") || line.contains(".mkv") || line.contains(".opus") || line.contains(".flac") || line.contains(".wav") {
                detail = line
                if line.hasPrefix("/") {
                    lastDownloadedFile = line
                    saveSettings()
                }
            }
        }
    }

    private func updatePlaylistCounter(from line: String) -> Bool {
        let patterns = [
            #"Downloading item\s+(\d+)\s+of\s+(\d+)"#,
            #"Downloading video\s+(\d+)\s+of\s+(\d+)"#,
            #"\[download\]\s+Downloading item\s+(\d+)\s+of\s+(\d+)"#,
            #"\[download\]\s+Downloading video\s+(\d+)\s+of\s+(\d+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 3,
                  let currentRange = Range(match.range(at: 1), in: line),
                  let totalRange = Range(match.range(at: 2), in: line) else { continue }
            let current = String(line[currentRange])
            let total = String(line[totalRange])
            playlistCurrentItem = Int(current) ?? playlistCurrentItem
            playlistTotalItems = Int(total) ?? playlistTotalItems
            playlistCounter = "\(current) of \(total)"
            status = "Downloading item \(current) of \(total)"
            updateOverallProgressFromCurrentItem()
            return true
        }
        return false
    }

    private func updateProgress(percent: String, speedText: String, etaText: String, downloadedBytes: Int64?, totalBytes: Int64?) {
        let cleanedPercent = percent.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let p = Double(cleanedPercent) { progress = min(max(p / 100.0, 0), 1) }
        if let downloadedBytes, downloadedBytes > 0 { transferredBytes = downloadedBytes }
        if let totalBytes, totalBytes > 0 { self.totalBytes = totalBytes }
        updateOverallProgressFromCurrentItem()
        let cleanSpeed = speedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanETA = etaText.trimmingCharacters(in: .whitespacesAndNewlines)
        speed = cleanSpeed.isEmpty || cleanSpeed.uppercased() == "NA" ? "—" : cleanSpeed
        eta = cleanETA.isEmpty || cleanETA.uppercased() == "NA" ? "—" : cleanETA
        if progress >= 1 {
            status = "Processing"
            detail = "Finalizing, merging, or converting media."
        } else {
            status = playlistTotalItems > 1 ? "Downloading item \(max(playlistCurrentItem, 1)) of \(playlistTotalItems)" : "Downloading"
            let overallText = playlistTotalItems > 1 ? " • Total \(Int(overallProgress * 100))%" : ""
            detail = "\(Int(progress * 100))% current item\(overallText)"
        }
    }

    private func updateOverallProgressFromCurrentItem() {
        let itemProgress: Double
        if playlistTotalItems > 1, playlistCurrentItem > 0 {
            let completedItems = max(0, playlistCurrentItem - 1)
            itemProgress = (Double(completedItems) + min(max(progress, 0), 1)) / Double(playlistTotalItems)
        } else {
            itemProgress = progress
        }

        if queueTotal > 1 {
            let combined = (Double(queueCompleted) + min(max(itemProgress, 0), 1)) / Double(queueTotal)
            overallProgress = min(max(combined, overallProgress), 1)
        } else {
            overallProgress = min(max(itemProgress, overallProgress), 1)
        }
    }

    private func beginLiveProgress() {
        // Progress and phase changes come only from real yt-dlp output.
        // In particular, do not show Processing until download progress reaches 100%.
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func stopLiveProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func restoreBackgroundDownloadIfNeeded() {
        guard let plugin, plugin.hasRunningBackgroundDownloads() else { return }
        isRunning = true
        cancellationRequested = false
        status = "Downloading in background"
        detail = "A previous download is still running. Reading progress from the log."
        playlistCounter = ""
        beginLiveProgress()
        beginBackgroundLogPolling()
    }

    private func beginBackgroundLogPolling() {
        backgroundLogPollingTimer?.invalidate()
        backgroundLogPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let plugin = self.plugin else {
                self.stopBackgroundLogPolling()
                return
            }

            if let logText = try? String(contentsOf: plugin.lastLogURL(), encoding: .utf8), !logText.isEmpty {
                let lines = logText.components(separatedBy: .newlines)
                let tail = lines.suffix(80).joined(separator: "\\n")
                self.consumeOutput(tail)
            }

            if !plugin.hasRunningBackgroundDownloads() {
                self.isRunning = false
                self.stopLiveProgress()
                self.stopBackgroundLogPolling()
                self.progress = max(self.progress, 1)
                self.overallProgress = max(self.overallProgress, 1)
                self.status = "Completed"
                self.detail = "Background download completed. The file is ready."
            }
        }
    }

    private func stopBackgroundLogPolling() {
        backgroundLogPollingTimer?.invalidate()
        backgroundLogPollingTimer = nil
    }

    private func noteActivity() {
        // Keep progress stable; only real yt-dlp progress should move the bars.
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    var hasValidOutputFile: Bool {
        let path = lastDownloadedFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    func revealLastFile() {
        guard hasValidOutputFile else {
            fail("No completed file is available to reveal.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastDownloadedFile)])
    }

    func retry() {
        guard !isRunning else { return }
        start()
    }

    private func fail(_ message: String) {
        status = "Failed"
        detail = message
        technicalDetails = message
    }
}

struct VideoDownloaderDashboardView: View {
    @ObservedObject var model: VideoDownloaderViewModel

    private let panelWidth: CGFloat = 806
    private let panelHeight: CGFloat = 350
    private let rightWidth: CGFloat = 245
    private let accent = Color.accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            leftColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            rightColumn
                .frame(width: rightWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(width: panelWidth, height: panelHeight, alignment: .top)
        .background(Color.clear)
        .onChange(of: model.url, perform: sourceChanged)
        .onChange(of: model.mode, perform: settingsChanged)
        .onChange(of: model.videoPreset, perform: settingsChanged)
        .onChange(of: model.customFormat, perform: settingsChanged)
        .onChange(of: model.audioFormat, perform: settingsChanged)
        .onChange(of: model.audioQuality, perform: settingsChanged)
        .onChange(of: model.cookiesBrowser, perform: settingsChanged)
        .onChange(of: model.folderPath, perform: folderChanged)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            sourceSection
            optionsSection
            destinationSection
            Spacer(minLength: 0)
            hintsBar
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            previewCard
            statusCard
            settingsCard
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(accent.opacity(0.14))
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 36, height: 36)
            .accessibilityLabel("Media Downloader")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Media Downloader")
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    statusPill
                }
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.12), in: Capsule())
        .accessibilityLabel("Status: \(statusLabel)")
    }

    private var sourceSection: some View {
        section("Source") {
            HStack(spacing: 6) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Paste URL, search text, or multi-line list", text: $model.url)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1)
                    .disabled(model.isRunning)
                    .accessibilityLabel("Source URL or search text")
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string), !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.updateURLFromLauncherQuery(model.url)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help("Paste from Clipboard")
                .accessibilityLabel("Paste from Clipboard")
                Button {
                    model.url = ""
                    model.queueStatus = ""
                    model.playlistCounter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning || model.url.isEmpty)
                .help("Clear Source")
                .accessibilityLabel("Clear Source")
            }
            .controlRowBackground()

            HStack(spacing: 6) {
                Image(systemName: validationIcon)
                    .foregroundStyle(validationColor)
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var optionsSection: some View {
        section("Download Options") {
            Picker("Mode", selection: $model.mode) {
                ForEach(DownloadMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .disabled(model.isRunning)

            HStack(spacing: 12) {
                if model.mode == .video {
                    compactMenu("Format", selection: $model.videoPreset, values: model.videoPresets, width: 330)
                        .disabled(model.isRunning)
                } else {
                    compactMenu("Format", selection: $model.audioFormat, values: model.audioFormats, width: 150)
                        .disabled(model.isRunning)
                    if model.audioFormat != "WAV" && model.audioFormat != "FLAC" {
                        compactMenu("Quality", selection: $model.audioQuality, values: model.audioQualities, width: 190)
                            .disabled(model.isRunning)
                    }
                }
                Spacer(minLength: 0)
            }
            if model.mode == .video && model.videoPreset == "Custom yt-dlp selector" {
                TextField("yt-dlp selector", text: $model.customFormat)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(model.isRunning)
            }
            if model.isRunning {
                Text("Current job uses the settings selected when it started.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var destinationSection: some View {
        section("Destination") {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(destinationName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.folderPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(model.folderPath)
                    Spacer(minLength: 0)
                    Button("Choose") { model.chooseFolder() }
                        .controlSize(.small)
                        .disabled(model.isRunning)
                        .help("Choose Download Folder")
                    Button {
                        model.openCurrentFolder()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Open Destination Folder")
                    .accessibilityLabel("Open Destination Folder")
                }
                .controlRowBackground()
                .frame(maxWidth: .infinity)
                .frame(height: 46)

                Group {
                    if model.isRunning {
                        Button(role: .cancel) {
                            model.cancel()
                        } label: {
                            Text("Cancel")
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .help("Stop the active download")
                    } else {
                        Button {
                            model.start()
                        } label: {
                            Text("Download")
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .disabled(model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                        .help("Start download")
                    }
                }
                .frame(width: 132, height: 46)
                .controlSize(.regular)
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                if let image = model.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: rightWidth, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: model.isRunning ? "arrow.down.circle" : "play.rectangle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(model.isRunning ? "Downloading…" : "Preview")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: rightWidth, height: 112)
            .clipped()

            Text(previewTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(previewSubtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !model.mediaDuration.isEmpty {
                    Text("•")
                    Text(model.mediaDuration)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: statusSystemImage)
                    .foregroundStyle(statusColor)
                Text(model.status)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(model.sizeEstimate.replacingOccurrences(of: "Approx. ", with: ""))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(model.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(model.isRunning ? 1 : 2)
                .truncationMode(.tail)
            if model.isRunning {
                ProgressView(value: model.overallProgress > 0 ? model.overallProgress : nil)
                    .progressViewStyle(.linear)
                    .tint(accent)
                HStack(spacing: 8) {
                    if let downloaded = model.transferredBytes {
                        Text(byteProgress(downloaded: downloaded, total: model.totalBytes))
                    }
                    if cleanMetric(model.speed) != "—" {
                        Text(cleanMetric(model.speed))
                    }
                    if cleanMetric(model.eta) != "—" {
                        Text(cleanETA(model.eta))
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            let counterText = model.queueStatus.isEmpty ? model.playlistCounter : model.queueStatus
            if !counterText.isEmpty {
                Text(counterText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if !model.healthStatus.isEmpty {
                DisclosureGroup("Technical details") {
                    Text(model.healthStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .font(.caption2)
            }
        }
        .padding(9)
        .frame(height: 112, alignment: .topLeading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var settingsCard: some View {
        HStack(spacing: 7) {
            Menu {
                Picker("Cookies", selection: $model.cookiesBrowser) {
                    ForEach(model.cookiesBrowsers, id: \.self) { Text($0).tag($0) }
                }
                Divider()
                Button("Check Tools") { model.checkTools() }.disabled(model.isRunning)
                Button("Update Tools") { model.updateTools() }.disabled(model.isRunning)
                Button("Copy Log") { model.copyLog() }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .help("Cookies, health check, updates, and logs")

            Spacer()
            if model.isRunning {
                Text("Background safe")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hintsBar: some View {
        HStack(spacing: 10) {
            Label("Download", systemImage: "return")
            Label("Mode", systemImage: "arrow.right.to.line.compact")
            Label("Format", systemImage: "control")
            Label("Quality", systemImage: "option")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
    }

    private func compactMenu(_ title: String, selection: Binding<String>, values: [String], width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(width: width, alignment: .leading)
    }

    private func sourceChanged(_ value: String) {
        model.refreshThumbnailIfNeeded()
        model.refreshSizeEstimateIfNeeded()
    }

    private func settingsChanged<T>(_ value: T) {
        model.saveSettings()
        model.refreshSizeEstimateIfNeeded()
    }

    private func folderChanged(_ value: String) {
        model.folderSelectionChanged()
    }

    private var headerSubtitle: String {
        model.isRunning ? "Working in background if this panel closes." : "Paste, search, or download media with yt-dlp."
    }

    private var validationMessage: String {
        let trimmed = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Waiting for a URL or search text." }
        if trimmed.contains("\n") { return "Multi-line list will download in order." }
        if trimmed.lowercased().hasPrefix("http") { return "URL detected." }
        return "Search text will use the first YouTube result."
    }

    private var validationIcon: String {
        model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "circle" : "checkmark.circle.fill"
    }

    private var validationColor: Color {
        model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .green
    }

    private var sourceIcon: String {
        model.url.contains("\n") ? "music.note.list" : (model.url.lowercased().hasPrefix("http") ? "link" : "magnifyingglass")
    }

    private var destinationName: String {
        let trimmed = model.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Default Downloads Folder" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private var previewTitle: String {
        if !model.mediaTitle.isEmpty { return model.mediaTitle }
        let trimmed = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No source selected" }
        if trimmed.contains("\n") { return "Text playlist" }
        if let host = URLComponents(string: trimmed)?.host { return host.replacingOccurrences(of: "www.", with: "") }
        return trimmed
    }

    private var previewSubtitle: String {
        if !model.mediaSource.isEmpty { return model.mediaSource }
        let trimmed = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Paste a URL or search text to begin." }
        return URLComponents(string: trimmed)?.host?.replacingOccurrences(of: "www.", with: "") ?? "YouTube search"
    }

    private var statusLabel: String {
        if model.isRunning { return "Active" }
        if model.status.lowercased().contains("fail") || model.status.lowercased().contains("attention") { return "Issue" }
        if model.status.lowercased().contains("finish") || model.status.lowercased().contains("updated") || model.status.lowercased().contains("ok") { return "Ready" }
        return "Idle"
    }

    private var statusColor: Color {
        if model.isRunning { return accent }
        if model.status.lowercased().contains("fail") || model.status.lowercased().contains("attention") { return .red }
        if model.status.lowercased().contains("finish") || model.status.lowercased().contains("updated") || model.status.lowercased().contains("ok") { return .green }
        return .secondary
    }

    private var statusSystemImage: String {
        if model.isRunning { return "arrow.down.circle" }
        if model.status.lowercased().contains("fail") || model.status.lowercased().contains("attention") { return "exclamationmark.triangle" }
        if model.status.lowercased().contains("finish") || model.status.lowercased().contains("updated") || model.status.lowercased().contains("ok") { return "checkmark.circle" }
        return "circle"
    }

    private func byteProgress(downloaded: Int64, total: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let current = formatter.string(fromByteCount: downloaded)
        guard let total, total > 0 else { return current }
        return "\(current) / \(formatter.string(fromByteCount: total))"
    }

    private func cleanMetric(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "NA" ? "—" : trimmed
    }

    private func cleanETA(_ value: String) -> String {
        let trimmed = cleanMetric(value)
        return trimmed == "—" ? "ETA —" : "ETA \(trimmed)"
    }
}

private extension View {
    func controlRowBackground() -> some View {
        self
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            )
    }
}
