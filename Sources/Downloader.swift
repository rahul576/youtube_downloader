import Foundation
import Combine

enum Mode: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    var id: String { rawValue }
}

enum ItemState { case pending, queued, downloading, done, failed, skipped }

/// One video inside a playlist.
struct PlaylistItem: Identifiable {
    let id: String           // unique row id
    let videoID: String
    let index: Int           // 1-based position in the playlist
    let title: String
    let duration: Double?
    let thumbnail: URL?
    let url: String
    var selected = true
    var state: ItemState = .pending
    var progress: Double = 0
}

/// What we learn about a link before downloading it.
struct VideoInfo {
    var title: String
    var uploader: String?
    var duration: Double?
    var thumbnail: URL?
    var heights: [Int]              // available video heights, highest first
    var sizes: [Int: Int64]         // approx. total bytes (video + audio) per height
    var isPlaylist: Bool
    var count: Int?
    var entries: [PlaylistItem] = []
}

enum TaskState: Equatable { case waiting, downloading, done, failed, cancelled }

/// One file in the download queue (a single video, or one item of a playlist).
struct DownloadTask: Identifiable {
    let id = UUID()
    let groupTitle: String       // playlist name, or "Single video"
    let title: String
    let url: String
    let thumbnail: URL?
    let folder: String
    let template: String         // yt-dlp -o output template
    let formatArgs: [String]     // quality / audio options chosen when it was queued
    let kindLabel: String        // e.g. "MP3" or "1080p"
    let sourceLink: String       // the link it was added from (to light up playlist tiles)
    let rowID: String?           // playlist tile id, if any
    var state: TaskState = .waiting
    var progress: Double = 0
    var speed: Double = 0        // bytes per second while downloading
    var attempts = 0             // runs started so far
    var retryAt: Date? = nil
    var lastError: String? = nil

    var dedupeKey: String { url + "|" + folder + "|" + formatArgs.joined(separator: " ") }
}

/// Only finished outcomes go in the activity log.
struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let ok: Bool
    let title: String
    let detail: String?
}

struct QueueStats: Equatable {
    var waiting = 0, retrying = 0, active = 0, done = 0, failed = 0, cancelled = 0
    var total: Int { waiting + active + done + failed }
    var finished: Int { done + failed }
}

/// Runs yt-dlp as child processes: inspects links and works through a download queue.
final class Downloader: ObservableObject {
    static let shared = Downloader()

    // MARK: Queue state
    @Published var tasks: [DownloadTask] = []
    @Published var stats = QueueStats()
    @Published var paused = false
    @Published var pausedForDisk = false
    @Published var totalSpeed: Double = 0        // bytes/s across all running downloads
    @Published var overallProgress: Double = 0
    @Published var etaText: String?
    @Published var status = "Ready"
    @Published var entries: [LogEntry] = []
    @Published var lastFolder: String?
    @Published var updatingEngine = false

    // MARK: Settings (persisted)
    /// How many files download at the same time (1…8).
    @Published var parallel: Int {
        didSet { UserDefaults.standard.set(parallel, forKey: "parallel"); pump() }
    }
    /// How many times a failed download is retried automatically.
    @Published var maxRetries: Int {
        didSet { UserDefaults.standard.set(maxRetries, forKey: "retries") }
    }
    /// Pause the queue when free space drops below this many GB (0 = never).
    @Published var minFreeGB: Int {
        didSet { UserDefaults.standard.set(minFreeGB, forKey: "minFreeGB"); refreshDisk() }
    }

    // MARK: Disk space
    @Published var freeBytes: Int64?
    @Published var totalBytes: Int64?
    /// Folder whose volume we watch (the "Save to" folder).
    var diskFolder: String = NSHomeDirectory() {
        didSet { if diskFolder != oldValue { refreshDisk() } }
    }
    var lowDisk: Bool {
        guard minFreeGB > 0, let f = freeBytes else { return false }
        return f < Int64(minFreeGB) * 1_000_000_000
    }

    // MARK: Link + selection
    @Published var items: [PlaylistItem] = []
    @Published var url = ""
    @Published var height: Int? = nil            // nil = best available
    @Published var playlistMode: Bool {
        didSet {
            UserDefaults.standard.set(playlistMode, forKey: "playlist")
            if oldValue != playlistMode && !suppressRefetch { refetch() }
        }
    }
    private var suppressRefetch = false

    // Link-inspection state
    @Published var info: VideoInfo?
    @Published var fetching = false
    @Published var infoError: String?
    @Published var needsSignIn = false
    private var infoURL: String?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let d = UserDefaults.standard
        playlistMode = d.bool(forKey: "playlist")
        let savedParallel = d.integer(forKey: "parallel")
        parallel = (1...8).contains(savedParallel) ? savedParallel : 4
        maxRetries = d.object(forKey: "retries") == nil ? 3 : max(0, min(10, d.integer(forKey: "retries")))
        minFreeGB = d.object(forKey: "minFreeGB") == nil ? 2 : max(0, d.integer(forKey: "minFreeGB"))

        $url
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .sink { [weak self] link in self?.linkChanged(link) }
            .store(in: &cancellables)

        // Free space is checked every 5 seconds.
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshDisk() }
            .store(in: &cancellables)
        refreshDisk()
    }

    static func isLink(_ s: String) -> Bool { s.hasPrefix("http://") || s.hasPrefix("https://") }
    static func hasPlaylist(_ s: String) -> Bool { s.contains("list=") || s.contains("/playlist") }

    var selectedCount: Int { items.filter(\.selected).count }
    var showingPlaylist: Bool { info?.isPlaylist == true && !items.isEmpty }
    /// Something is downloading, or waiting to download and not paused.
    var isBusy: Bool { stats.active > 0 || (!paused && stats.waiting > 0) }

    private func linkChanged(_ link: String) {
        if Self.isLink(link) { fetchInfo(url: link) } else { clearInfo() }
    }

    /// Look the current link up again (e.g. after choosing a browser for sign-in).
    func refetch() {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLink(link) { fetchInfo(url: link, force: true) }
    }

    func setAll(selected: Bool) {
        for i in items.indices { items[i].selected = selected }
    }

    func toggle(_ item: PlaylistItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].selected.toggle()
    }

    /// Browser whose YouTube sign-in yt-dlp should use ("" = none).
    var cookiesBrowser: String { UserDefaults.standard.string(forKey: "cookiesBrowser") ?? "" }
    private var cookieArgs: [String] {
        cookiesBrowser.isEmpty ? [] : ["--cookies-from-browser", cookiesBrowser.lowercased()]
    }

    static func isBotCheck(_ text: String) -> Bool {
        text.contains("not a bot") || text.contains("Sign in to confirm") || text.contains("cookies")
    }

    private var infoProcess: Process?
    private var infoToken = 0

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    static let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%"#)
    static let speedRegex = try! NSRegularExpression(pattern: #"at\s+~?\s*([\d.]+)\s*([KMGT]?i?B)/s"#)

    /// Looks for a tool bundled inside the app first, then in the usual Homebrew locations.
    static func find(_ tool: String) -> String? {
        if let p = Bundle.main.path(forResource: tool, ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in searchPaths {
            let p = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    var toolsMissing: [String] {
        ["yt-dlp", "ffmpeg"].filter { Self.find($0) == nil }
    }

    // MARK: - Inspect a link (available qualities, title, thumbnail, playlist entries)

    func clearInfo() {
        infoToken += 1
        infoProcess?.terminate()
        infoProcess = nil
        infoURL = nil
        info = nil
        items = []
        infoError = nil
        needsSignIn = false
        fetching = false
    }

    func fetchInfo(url: String, force: Bool = false) {
        if !force, url == infoURL { return }      // already looked up (or looking up) this link
        clearInfo()
        infoURL = url
        guard let ytdlp = Self.find("yt-dlp") else {
            infoError = "yt-dlp not found — run:  brew install yt-dlp ffmpeg"
            return
        }
        let token = infoToken
        fetching = true

        // Write output to temp files rather than pipes: yt-dlp's helper processes can keep a pipe
        // open after yt-dlp itself exits, which would leave us waiting forever for end-of-file.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("vs-info-\(token).json")
        let errURL = tmp.appendingPathComponent("vs-info-\(token).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outH = try? FileHandle(forWritingTo: outURL),
              let errH = try? FileHandle(forWritingTo: errURL) else {
            fetching = false
            infoError = "Couldn't create a temporary file."
            return
        }

        let wantPlaylist = playlistMode && Self.hasPlaylist(url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = ["-J", "--flat-playlist", wantPlaylist ? "--yes-playlist" : "--no-playlist",
                       "--no-warnings", "--socket-timeout", "20"] + cookieArgs + [url]
        p.environment = Self.environment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outH
        p.standardError = errH
        infoProcess = p

        let finish: (Bool) -> Void = { [weak self] timedOut in
            try? outH.close()
            try? errH.close()
            let data = (try? Data(contentsOf: outURL)) ?? Data()
            let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            let parsed = Self.parseInfo(data)
            DispatchQueue.main.async {
                guard let self, token == self.infoToken else { return }   // a newer link replaced this one
                self.fetching = false
                self.infoProcess = nil
                if let parsed {
                    self.info = parsed
                    self.items = parsed.entries
                    self.syncTilesFromQueue()
                    self.height = parsed.isPlaylist ? nil : parsed.heights.first   // auto-select highest
                    if parsed.isPlaylist && !self.playlistMode {
                        self.suppressRefetch = true
                        self.playlistMode = true
                        self.suppressRefetch = false
                    }
                } else if Self.isBotCheck(errText) {
                    self.needsSignIn = true
                    self.infoError = self.cookiesBrowser.isEmpty
                        ? "YouTube wants to confirm you’re not a bot. Choose the browser you’re signed in to YouTube with, below."
                        : "YouTube still wants a sign-in. Make sure you’re signed in to YouTube in \(self.cookiesBrowser), or try another browser."
                } else if timedOut {
                    self.infoError = "Timed out reading this link. You can still download with “Best”."
                } else {
                    let line = errText.split(separator: "\n").last(where: { $0.hasPrefix("ERROR") })
                    self.infoError = line.map { String($0).replacingOccurrences(of: "ERROR: ", with: "") }
                        ?? "Couldn't read this link. Check it, or try “Update engine”."
                }
            }
        }

        var done = false
        let lock = NSLock()
        p.terminationHandler = { _ in
            lock.lock(); let first = !done; done = true; lock.unlock()
            if first { finish(false) }
        }
        do { try p.run() } catch {
            fetching = false
            infoError = "Couldn't start yt-dlp: \(error.localizedDescription)"
            return
        }
        // Safety net: never spin forever (playlists get longer).
        DispatchQueue.global().asyncAfter(deadline: .now() + (wantPlaylist ? 120 : 60)) {
            lock.lock(); let first = !done; done = true; lock.unlock()
            if first {
                if p.isRunning { p.terminate() }
                finish(true)
            }
        }
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    static func parseInfo(_ data: Data) -> VideoInfo? {
        guard !data.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let title = obj["title"] as? String ?? "Untitled"
        let uploader = obj["uploader"] as? String ?? obj["channel"] as? String
        var thumb = (obj["thumbnail"] as? String).flatMap(URL.init(string:))
        if thumb == nil, let ts = obj["thumbnails"] as? [[String: Any]],
           let u = ts.last?["url"] as? String { thumb = URL(string: u) }

        if (obj["_type"] as? String) == "playlist" {
            let raw = (obj["entries"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            var items: [PlaylistItem] = []
            var seen = Set<String>()
            for (n, e) in raw.enumerated() {
                guard let vid = e["id"] as? String else { continue }
                let rowID = seen.contains(vid) ? "\(vid)-\(n)" : vid
                seen.insert(vid)
                let isYouTube = (e["ie_key"] as? String)?.lowercased() == "youtube"
                    || ((e["url"] as? String)?.contains("youtu") ?? false)
                var t: URL? = isYouTube ? URL(string: "https://i.ytimg.com/vi/\(vid)/mqdefault.jpg") : nil
                if t == nil, let ts = e["thumbnails"] as? [[String: Any]],
                   let u = ts.last?["url"] as? String { t = URL(string: u) }
                let link = isYouTube ? "https://www.youtube.com/watch?v=\(vid)"
                                     : (e["url"] as? String ?? e["webpage_url"] as? String ?? vid)
                let entryTitle = e["title"] as? String ?? "Video \(n + 1)"
                if entryTitle == "[Private video]" || entryTitle == "[Deleted video]" { continue }
                items.append(PlaylistItem(id: rowID, videoID: vid, index: n + 1, title: entryTitle,
                                          duration: num(e["duration"]), thumbnail: t, url: link))
            }
            if thumb == nil { thumb = items.first?.thumbnail }
            return VideoInfo(title: title, uploader: uploader, duration: nil, thumbnail: thumb,
                             heights: [], sizes: [:], isPlaylist: true, count: items.count, entries: items)
        }

        func size(_ f: [String: Any]) -> Int64 {
            Int64(num(f["filesize"]) ?? num(f["filesize_approx"]) ?? 0)
        }

        let formats = obj["formats"] as? [[String: Any]] ?? []
        var bestAudio: Int64 = 0
        for f in formats where (f["vcodec"] as? String) == "none" && (f["acodec"] as? String ?? "none") != "none" {
            bestAudio = max(bestAudio, size(f))
        }

        var heights = Set<Int>()
        var sizes: [Int: Int64] = [:]
        for f in formats {
            if (f["vcodec"] as? String) == "none" { continue }               // audio-only / storyboards
            guard let h = num(f["height"]).map({ Int($0) }), h > 0 else { continue }
            heights.insert(h)
            let s = size(f)
            if s > 0 {
                let hasAudio = (f["acodec"] as? String ?? "none") != "none"
                let total = hasAudio ? s : s + bestAudio
                sizes[h] = sizes[h].map { min($0, total) } ?? total
            }
        }
        if heights.isEmpty, let h = num(obj["height"]).map({ Int($0) }), h > 0 { heights.insert(h) }

        return VideoInfo(title: title, uploader: uploader, duration: num(obj["duration"]), thumbnail: thumb,
                         heights: heights.sorted(by: >), sizes: sizes, isPlaylist: false, count: nil)
    }

    // MARK: - Disk space

    /// Reads free/total space of the save folder's disk (no side effects).
    private func readDisk() {
        var url = URL(fileURLWithPath: diskFolder)
        // Walk up to the nearest folder that exists (the save folder may not be created yet).
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
            url.deleteLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return }
        if let free = v.volumeAvailableCapacityForImportantUsage, freeBytes != free { freeBytes = free }
        if let total = v.volumeTotalCapacity.map({ Int64($0) }), totalBytes != total { totalBytes = total }
    }

    /// Reads disk space, pausing the queue when it runs low and resuming when space comes back.
    func refreshDisk() {
        readDisk()
        if lowDisk && stats.waiting > 0 && !paused {
            paused = true
            pausedForDisk = true
            status = "Paused: less than \(minFreeGB) GB free. Free up space, then press Resume."
            updateStats()
        } else if pausedForDisk && !lowDisk {
            // Space came back (or the limit was lowered): carry on by itself.
            resume()
        }
    }

    // MARK: - Queue

    private func formatArgs(mode: Mode, height: Int?, audioFormat: String) -> [String] {
        switch mode {
        case .video:
            let h = height.map { "[height<=\($0)]" } ?? ""
            // At the chosen height, prefer H.264 + AAC (plays on every Mac/iPhone), else best available.
            return ["-f", "bv*\(h)+ba/b\(h)/b",
                    "-S", "res,vcodec:h264,acodec:aac,ext",
                    "--merge-output-format", "mp4",
                    "--embed-metadata"]
        case .audio:
            let fmt = audioFormat.lowercased()
            // Audio only needs the audio stream: much faster than pulling video and stripping it.
            var a = ["-f", "ba/b", "-x", "--audio-format", fmt, "--audio-quality", "0", "--embed-metadata"]
            if fmt == "mp3" || fmt == "m4a" { a += ["--embed-thumbnail"] }
            return a
        }
    }

    private static func safeFolderName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return cleaned.isEmpty ? "Playlist" : String(cleaned.prefix(80))
    }

    /// Adds the current link (selected playlist videos, or the single video) to the queue.
    /// Returns how many files were added.
    @discardableResult
    func enqueueCurrent(folder: String, mode: Mode, height: Int?, audioFormat: String) -> Int {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isLink(link) else { return 0 }
        let fArgs = formatArgs(mode: mode, height: height, audioFormat: audioFormat)
        let kind = mode == .audio ? audioFormat : (height.map { "\($0)p" } ?? "Best")
        let existing = Set(tasks.filter { $0.state == .waiting || $0.state == .downloading }.map(\.dedupeKey))
        var new: [DownloadTask] = []

        if playlistMode && showingPlaylist {
            let name = info?.title ?? "Playlist"
            let sub = (folder as NSString).appendingPathComponent(Self.safeFolderName(name))
            for i in items.indices where items[i].selected {
                let it = items[i]
                let t = DownloadTask(groupTitle: name, title: it.title, url: it.url, thumbnail: it.thumbnail,
                                     folder: sub,
                                     template: String(format: "%03d", it.index) + " - %(title)s.%(ext)s",
                                     formatArgs: fArgs, kindLabel: kind, sourceLink: infoURL ?? link, rowID: it.id)
                if existing.contains(t.dedupeKey) { continue }
                new.append(t)
                items[i].state = .queued
                items[i].progress = 0
            }
        } else {
            let t = DownloadTask(groupTitle: "Single video", title: info?.title ?? link, url: link,
                                 thumbnail: info?.thumbnail, folder: folder,
                                 template: "%(title)s [%(id)s].%(ext)s",
                                 formatArgs: fArgs, kindLabel: kind, sourceLink: link, rowID: nil)
            if !existing.contains(t.dedupeKey) { new.append(t) }
        }

        guard !new.isEmpty else {
            status = "Already in the queue"
            return 0
        }
        if !isBusy { queueStart = Date(); finishedSinceStart = 0 }
        tasks.append(contentsOf: new)
        status = new.count == 1 ? "Added “\(new[0].title)” to the queue"
                                : "Added \(new.count) files to the queue"
        updateStats()
        pump()
        return new.count
    }

    func pause() {
        paused = true
        pausedForDisk = false
        status = "Paused. Downloads in progress will finish; nothing new starts."
        updateStats()
    }

    func resume() {
        readDisk()
        if lowDisk && stats.waiting > 0 {
            status = "Still less than \(minFreeGB) GB free. Free up space or lower the limit in Settings."
            pausedForDisk = true
            return
        }
        paused = false
        pausedForDisk = false
        if !isBusy || stats.active == 0 { queueStart = Date(); finishedSinceStart = 0 }
        pump()
    }

    /// Stops everything: running downloads are interrupted and waiting ones cancelled.
    func stopAll() {
        for i in tasks.indices where tasks[i].state == .waiting {
            tasks[i].state = .cancelled
            syncTile(tasks[i])
        }
        for job in jobs.values {
            guard let id = job.taskID else { continue }
            stopping.insert(id)
            let p = job.process
            if p.isRunning {
                p.interrupt()                              // SIGINT lets yt-dlp clean up
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
            }
        }
        status = "Stopped"
        updateStats()
    }

    /// Puts every failed (and stopped) item back in the queue with a fresh retry count.
    func retryFailed() {
        var n = 0
        for i in tasks.indices where tasks[i].state == .failed || tasks[i].state == .cancelled {
            tasks[i].state = .waiting
            tasks[i].attempts = 0
            tasks[i].progress = 0
            tasks[i].retryAt = nil
            tasks[i].lastError = nil
            syncTile(tasks[i])
            n += 1
        }
        guard n > 0 else { return }
        paused = false
        if stats.active == 0 { queueStart = Date(); finishedSinceStart = 0 }
        status = "Retrying \(n) \(n == 1 ? "file" : "files")"
        updateStats()
        pump()
    }

    /// Removes saved, failed and stopped items from the list.
    func clearFinished() {
        tasks.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
        updateStats()
    }

    func remove(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].state == .waiting else { return }
        tasks[i].state = .cancelled
        syncTile(tasks[i])
        tasks.remove(at: i)
        updateStats()
    }

    func clearLog() { entries.removeAll() }

    /// Called when the app quits: don't leave yt-dlp running in the background.
    func terminateAll() {
        for job in jobs.values where job.process.isRunning { job.process.terminate() }
    }

    // MARK: - Queue engine

    private struct Job {
        let process: Process
        let taskID: UUID?
    }
    private final class LineBuffer { var text = "" }
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var stopping = Set<UUID>()
    private var queueStart = Date()
    private var finishedSinceStart = 0
    private var retryTimerPending = false
    private var sleepActivity: NSObjectProtocol?

    private func index(of id: UUID) -> Int? { tasks.firstIndex { $0.id == id } }

    /// Starts waiting downloads until `parallel` are running.
    func pump() {
        guard !paused else { updateStats(); return }
        if lowDisk && stats.waiting > 0 {
            paused = true
            pausedForDisk = true
            status = "Paused: less than \(minFreeGB) GB free. Free up space, then press Resume."
            updateStats()
            return
        }
        guard let ytdlp = Self.find("yt-dlp") else {
            status = "yt-dlp not found. Run:  brew install yt-dlp ffmpeg"
            return
        }
        let now = Date()
        var running = jobs.values.filter { $0.taskID != nil }.count
        var nextRetry: Date?
        for i in tasks.indices where running < parallel && tasks[i].state == .waiting {
            if let at = tasks[i].retryAt, at > now {
                nextRetry = min(nextRetry ?? at, at)
                continue
            }
            start(i, ytdlp: ytdlp)
            running += 1
        }
        // Wake up again when the earliest pending retry is due.
        if let at = nextRetry, !retryTimerPending {
            retryTimerPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, at.timeIntervalSinceNow)) { [weak self] in
                self?.retryTimerPending = false
                self?.pump()
            }
        }
        updateStats()
    }

    private func start(_ i: Int, ytdlp: String) {
        tasks[i].state = .downloading
        tasks[i].attempts += 1
        tasks[i].progress = 0
        tasks[i].speed = 0
        tasks[i].retryAt = nil
        let t = tasks[i]
        syncTile(t)
        try? FileManager.default.createDirectory(atPath: t.folder, withIntermediateDirectories: true)

        var args = ["--newline", "--no-mtime", "--restrict-filenames", "--no-playlist",
                    "--concurrent-fragments", "4"] + cookieArgs
        if let ff = Self.find("ffmpeg") { args += ["--ffmpeg-location", ff] }
        args += t.formatArgs + ["-P", t.folder, "-o", t.template, t.url]

        let id = t.id
        launch(ytdlp, args, taskID: id) { [weak self] code in self?.finished(id, code: code) }
    }

    private func finished(_ id: UUID, code: Int32) {
        let wasStopped = stopping.remove(id) != nil
        guard let i = index(of: id) else { pump(); return }
        tasks[i].speed = 0

        if code == 0 && !wasStopped {
            tasks[i].state = .done
            tasks[i].progress = 1
            finishedSinceStart += 1
            lastFolder = tasks[i].folder
            entries.append(LogEntry(date: Date(), ok: true, title: tasks[i].title,
                                    detail: tasks[i].groupTitle == "Single video" ? nil : tasks[i].groupTitle))
        } else if wasStopped {
            tasks[i].state = .cancelled
            tasks[i].progress = 0
        } else if tasks[i].attempts <= maxRetries {
            // Automatic retry, with a growing pause: 5 s, 10 s, 15 s…
            tasks[i].state = .waiting
            tasks[i].progress = 0
            tasks[i].retryAt = Date().addingTimeInterval(Double(5 * tasks[i].attempts))
        } else {
            tasks[i].state = .failed
            finishedSinceStart += 1
            let tries = tasks[i].attempts
            let reason = tasks[i].lastError ?? "yt-dlp exited with code \(code)"
            entries.append(LogEntry(date: Date(), ok: false, title: tasks[i].title,
                                    detail: reason + (tries > 1 ? " (tried \(tries) times)" : "")))
        }
        if entries.count > 5000 { entries.removeFirst(entries.count - 5000) }
        syncTile(tasks[i])
        pump()
        if stats.active == 0 && stats.waiting == 0 { allDone() }
    }

    private func allDone() {
        let s = stats
        if s.failed == 0 && s.done > 0 {
            status = "All \(s.done) saved"
        } else if s.done + s.failed > 0 {
            status = "Saved \(s.done) · \(s.failed) failed. Press Retry failed to try them again."
        }
        etaText = nil
    }

    private func updateStats() {
        var s = QueueStats()
        var partial = 0.0
        var speed = 0.0
        for t in tasks {
            switch t.state {
            case .waiting:
                s.waiting += 1
                if t.attempts > 0 { s.retrying += 1 }
            case .downloading:
                s.active += 1
                partial += t.progress
                speed += t.speed
            case .done: s.done += 1
            case .failed: s.failed += 1
            case .cancelled: s.cancelled += 1
            }
        }
        if stats != s { stats = s }
        if abs(totalSpeed - speed) > 1 { totalSpeed = speed }
        let total = Double(max(s.total, 1))
        let overall = min((Double(s.finished) + partial) / total, 1)
        if abs(overall - overallProgress) > 0.0005 || overall == 0 || overall == 1 { overallProgress = overall }

        // ETA from how fast files have been finishing since the queue started.
        let elapsed = Date().timeIntervalSince(queueStart)
        let doneEquivalent = Double(finishedSinceStart) + partial
        let remaining = Double(s.waiting + s.active) - partial
        if s.active > 0, doneEquivalent > 0.05, elapsed > 5, remaining > 0 {
            etaText = "about " + Self.formatETA(elapsed / doneEquivalent * remaining) + " left"
        } else if s.active == 0 {
            etaText = nil
        }

        // Keep the Mac awake while the queue is working.
        if isBusy && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Downloading videos")
        } else if !isBusy, let a = sleepActivity {
            ProcessInfo.processInfo.endActivity(a)
            sleepActivity = nil
        }
    }

    static func formatETA(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(max(t, 1)) sec" }
        if t < 3600 { return "\(t / 60) min" }
        return "\(t / 3600) h \((t % 3600) / 60) min"
    }

    /// Mirrors a queue item's state onto its playlist tile, if that playlist is on screen.
    private func syncTile(_ t: DownloadTask) {
        guard let row = t.rowID, t.sourceLink == infoURL,
              let i = items.firstIndex(where: { $0.id == row }) else { return }
        let st: ItemState
        switch t.state {
        case .waiting: st = .queued
        case .downloading: st = .downloading
        case .done: st = .done
        case .failed: st = .failed
        case .cancelled: st = .pending
        }
        if items[i].state != st || abs(items[i].progress - t.progress) >= 0.01 {
            items[i].state = st
            items[i].progress = t.progress
        }
    }

    /// After a playlist is (re)loaded, show which of its videos are already queued or saved.
    private func syncTilesFromQueue() {
        for t in tasks where t.rowID != nil { syncTile(t) }
    }

    /// Updates yt-dlp through Homebrew. YouTube changes often, so this fixes most failures.
    func updateYtDlp() {
        guard !updatingEngine, stats.active == 0 else { return }
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            status = "Homebrew not found. Install it from brew.sh"
            return
        }
        updatingEngine = true
        status = "Updating yt-dlp…"
        launch(brew, ["upgrade", "yt-dlp"], taskID: nil) { [weak self] code in
            guard let self else { return }
            self.updatingEngine = false
            self.status = code == 0 ? "yt-dlp is up to date" : "Update failed. Try in Terminal: brew upgrade yt-dlp"
        }
    }

    // MARK: - Process plumbing

    private func launch(_ executable: String, _ arguments: [String], taskID: UUID?,
                        onExit: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = Self.environment()
        p.standardInput = FileHandle.nullDevice
        let key = ObjectIdentifier(p)
        let buffer = LineBuffer()

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s, buffer: buffer, taskID: taskID) }
        }

        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                if !buffer.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.handle(buffer.text, taskID: taskID)
                }
                buffer.text = ""
                self.jobs[key] = nil
                onExit(code)
            }
        }

        jobs[key] = Job(process: p, taskID: taskID)
        do {
            try p.run()
        } catch {
            jobs[key] = nil
            if let id = taskID, let i = index(of: id) { tasks[i].lastError = "Couldn't start yt-dlp: \(error.localizedDescription)" }
            DispatchQueue.main.async { onExit(-1) }
        }
    }

    private func consume(_ chunk: String, buffer: LineBuffer, taskID: UUID?) {
        buffer.text += chunk
        let parts = buffer.text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        buffer.text = parts.last ?? ""
        for line in parts.dropLast() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            handle(line, taskID: taskID)
        }
    }

    private static func speedBytes(_ value: Double, _ unit: String) -> Double {
        switch unit.uppercased().first {
        case "K": return value * 1024
        case "M": return value * 1024 * 1024
        case "G": return value * 1024 * 1024 * 1024
        case "T": return value * 1024 * 1024 * 1024 * 1024
        default: return value
        }
    }

    private func handle(_ line: String, taskID: UUID?) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let id = taskID else {
            // Engine update output: only surface errors.
            if trimmed.hasPrefix("Error") || trimmed.hasPrefix("ERROR") { status = trimmed }
            return
        }
        guard let i = index(of: id) else { return }

        if trimmed.hasPrefix("[download]") {
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            var changed = false
            if let m = Self.percentRegex.firstMatch(in: trimmed, range: range),
               let v = Double(ns.substring(with: m.range(at: 1))) {
                let value = min(v / 100, 1)
                // Throttle: with many parallel jobs, only publish visible (≥1%) changes.
                if abs(value - tasks[i].progress) >= 0.01 || value >= 1 {
                    tasks[i].progress = value
                    changed = true
                }
            }
            if let m = Self.speedRegex.firstMatch(in: trimmed, range: range),
               let v = Double(ns.substring(with: m.range(at: 1))) {
                let bps = Self.speedBytes(v, ns.substring(with: m.range(at: 2)))
                if changed || abs(bps - tasks[i].speed) > tasks[i].speed * 0.2 {
                    tasks[i].speed = bps
                    changed = true
                }
            }
            if changed {
                syncTile(tasks[i])
                updateStats()
            }
        } else if trimmed.hasPrefix("[ExtractAudio]") || trimmed.hasPrefix("[Merger]")
                    || trimmed.hasPrefix("[VideoConvertor]") || trimmed.hasPrefix("[EmbedThumbnail]") {
            if tasks[i].speed != 0 {
                tasks[i].speed = 0
                updateStats()
            }
        } else if trimmed.hasPrefix("ERROR") {
            var msg = trimmed.replacingOccurrences(of: "ERROR: ", with: "")
            // "[youtube] abc123: Video unavailable" -> "Video unavailable"
            if msg.hasPrefix("["), let r = msg.range(of: ": ") { msg = String(msg[r.upperBound...]) }
            tasks[i].lastError = String(msg.prefix(200))
            if Self.isBotCheck(trimmed) {
                needsSignIn = true
                tasks[i].lastError = "YouTube asked to confirm you’re not a bot. Choose your browser in Settings → YouTube sign-in."
            }
        }
    }
}
