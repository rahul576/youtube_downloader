import Foundation
import Combine

enum Mode: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    var id: String { rawValue }
}

enum ItemState { case pending, downloading, done, failed, skipped }

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

/// Runs yt-dlp as a child process and publishes progress for the UI.
final class Downloader: ObservableObject {
    // Download state
    @Published var progress: Double = 0          // current item, 0...1
    @Published var status = "Ready"
    @Published var log = ""
    @Published var isRunning = false
    @Published var lastExitOK = false

    // Batch (playlist) state
    @Published var items: [PlaylistItem] = []
    @Published var overallProgress: Double = 0
    @Published var currentTitle: String?
    @Published var batchPosition = 0             // 1-based item being downloaded
    @Published var batchTotal = 0
    @Published var batchSaved = 0
    @Published var batchFailed = 0
    @Published var isBatch = false
    @Published var activeIndices: [Int] = []     // playlist items downloading right now
    @Published var etaText: String?
    /// How many playlist items download at the same time (1…8).
    @Published var parallel: Int {
        didSet { UserDefaults.standard.set(parallel, forKey: "parallel"); pumpQueue() }
    }

    // Link + selection (owned here so the view never re-triggers lookups when it redraws)
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
        playlistMode = UserDefaults.standard.bool(forKey: "playlist")
        let savedParallel = UserDefaults.standard.integer(forKey: "parallel")
        parallel = (1...8).contains(savedParallel) ? savedParallel : 4
        $url
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .sink { [weak self] link in self?.linkChanged(link) }
            .store(in: &cancellables)
    }

    static func isLink(_ s: String) -> Bool { s.hasPrefix("http://") || s.hasPrefix("https://") }
    static func hasPlaylist(_ s: String) -> Bool { s.contains("list=") || s.contains("/playlist") }

    var selectedCount: Int { items.filter(\.selected).count }
    var showingPlaylist: Bool { info?.isPlaylist == true && !items.isEmpty }

    private func linkChanged(_ link: String) {
        if Self.isLink(link) { fetchInfo(url: link) } else { clearInfo() }
    }

    /// Look the current link up again (e.g. after choosing a browser for sign-in).
    func refetch() {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLink(link) { fetchInfo(url: link, force: true) }
    }

    func setAll(selected: Bool) {
        guard !isRunning else { return }
        for i in items.indices { items[i].selected = selected }
    }

    func toggle(_ item: PlaylistItem) {
        guard !isRunning, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
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
    private var cancelled = false
    private var logLines: [String] = []

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    static let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%"#)

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
        if !isRunning { items = [] }
        infoError = nil
        needsSignIn = false
        fetching = false
    }

    func fetchInfo(url: String, force: Bool = false) {
        if !force, url == infoURL { return }      // already looked up (or looking up) this link
        guard !isRunning else { return }          // don't swap the list out mid-download
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

    // MARK: - Download

    private func formatArgs(mode: Mode, height: Int?, audioFormat: String) -> [String] {
        var args = ["--newline", "--no-mtime", "--restrict-filenames", "--no-playlist",
                    "--concurrent-fragments", "4"] + cookieArgs
        if let ff = Self.find("ffmpeg") { args += ["--ffmpeg-location", ff] }
        switch mode {
        case .video:
            let h = height.map { "[height<=\($0)]" } ?? ""
            // At the chosen height, prefer H.264 + AAC (plays on every Mac/iPhone), else best available.
            args += ["-f", "bv*\(h)+ba/b\(h)/b",
                     "-S", "res,vcodec:h264,acodec:aac,ext",
                     "--merge-output-format", "mp4",
                     "--embed-metadata"]
        case .audio:
            let fmt = audioFormat.lowercased()
            // Audio only needs the audio stream — much faster than pulling video and stripping it.
            args += ["-f", "ba/b", "-x", "--audio-format", fmt, "--audio-quality", "0", "--embed-metadata"]
            if fmt == "mp3" || fmt == "m4a" { args += ["--embed-thumbnail"] }
        }
        return args
    }

    /// Downloads the current link: the selected playlist items, or the single video.
    func download(folder: String, mode: Mode, height: Int?, audioFormat: String) {
        guard !isRunning else { return }
        guard let ytdlp = Self.find("yt-dlp") else {
            status = "yt-dlp not found — run:  brew install yt-dlp ffmpeg"
            return
        }
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = formatArgs(mode: mode, height: height, audioFormat: audioFormat)
        resetRun()

        if playlistMode && showingPlaylist {
            startBatch(ytdlp: ytdlp, folder: folder, baseArgs: base)
        } else {
            isBatch = false
            isRunning = true
            status = "Starting download…"
            let args = base + ["-P", folder, "-o", "%(title)s [%(id)s].%(ext)s", link]
            launch(ytdlp, args, item: nil) { [weak self] code in
                guard let self else { return }
                self.isRunning = false
                self.lastExitOK = code == 0 && !self.cancelled
                if self.cancelled { self.status = "Cancelled" }
                else if code == 0 { self.status = "Download complete"; self.progress = 1; self.overallProgress = 1 }
                else if !self.needsSignIn { self.status = "Failed (code \(code)) — see details. Try “Update engine”." }
            }
        }
    }

    // Playlist batch: a pool of up to `parallel` yt-dlp processes working through the queue.
    private var queue: [Int] = []
    private var batchArgs: [String] = []
    private var batchFolder = ""
    private var batchTool = ""
    private var batchStart = Date()

    private static func safeFolderName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return cleaned.isEmpty ? "Playlist" : String(cleaned.prefix(80))
    }

    private func startBatch(ytdlp: String, folder: String, baseArgs: [String]) {
        let selected = items.indices.filter { items[$0].selected }
        guard !selected.isEmpty else { status = "Select at least one video"; return }
        for i in items.indices {
            items[i].state = items[i].selected ? .pending : .skipped
            items[i].progress = 0
        }
        queue = selected
        batchTotal = selected.count
        batchSaved = 0
        batchFailed = 0
        batchPosition = 0
        batchTool = ytdlp
        batchArgs = baseArgs
        batchStart = Date()
        etaText = nil
        batchFolder = (folder as NSString).appendingPathComponent(Self.safeFolderName(info?.title ?? "Playlist"))
        try? FileManager.default.createDirectory(atPath: batchFolder, withIntermediateDirectories: true)
        isBatch = true
        isRunning = true
        status = "Starting \(min(parallel, batchTotal)) downloads at once…"
        pumpQueue()
    }

    /// Starts queued items until `parallel` are running.
    private func pumpQueue() {
        guard isBatch, isRunning, !cancelled else { return }
        while activeIndices.count < parallel, !queue.isEmpty {
            startItem(queue.removeFirst())
        }
    }

    private func startItem(_ i: Int) {
        activeIndices.append(i)
        batchPosition += 1
        items[i].state = .downloading
        items[i].progress = 0
        currentTitle = items[i].title
        appendLog("── start #\(items[i].index): \(items[i].title)")

        let name = String(format: "%03d", items[i].index) + " - %(title)s.%(ext)s"
        let args = batchArgs + ["-P", batchFolder, "-o", name, items[i].url]
        launch(batchTool, args, item: i) { [weak self] code in
            guard let self else { return }
            self.activeIndices.removeAll { $0 == i }
            if code == 0 && !self.cancelled {
                self.items[i].state = .done
                self.items[i].progress = 1
                self.batchSaved += 1
            } else if self.cancelled {
                self.items[i].state = .pending
                self.items[i].progress = 0
            } else {
                self.items[i].state = .failed
                self.batchFailed += 1
                self.appendLog("✗ failed #\(self.items[i].index): \(self.items[i].title)")
            }
            self.updateOverall()
            if self.activeIndices.isEmpty && (self.queue.isEmpty || self.cancelled) {
                self.finishBatch()
            } else {
                self.pumpQueue()
            }
        }
    }

    private func updateOverall() {
        let finished = Double(batchSaved + batchFailed)
        let partial = activeIndices.reduce(0.0) { $0 + items[$1].progress }
        let total = Double(max(batchTotal, 1))
        overallProgress = min((finished + partial) / total, 1)
        progress = activeIndices.isEmpty ? (finished > 0 ? 1 : 0) : partial / Double(activeIndices.count)
        currentTitle = activeIndices.first.map { items[$0].title }

        let elapsed = Date().timeIntervalSince(batchStart)
        if overallProgress > 0.01 && elapsed > 5 {
            let remaining = elapsed / overallProgress * (1 - overallProgress)
            etaText = "about " + Self.formatETA(remaining) + " left"
        }
        if isRunning {
            status = "\(activeIndices.count) downloading at once · \(batchSaved + batchFailed) of \(batchTotal) done"
        }
    }

    static func formatETA(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(max(t, 1)) sec" }
        if t < 3600 { return "\(t / 60) min" }
        return "\(t / 3600) h \((t % 3600) / 60) min"
    }

    private func finishBatch() {
        guard isRunning else { return }
        isRunning = false
        activeIndices.removeAll()
        currentTitle = nil
        etaText = nil
        let folderName = (batchFolder as NSString).lastPathComponent
        let took = Self.formatETA(Date().timeIntervalSince(batchStart))
        if cancelled {
            status = "Cancelled — \(batchSaved) of \(batchTotal) saved"
        } else if batchFailed == 0 {
            status = "All \(batchSaved) saved to “\(folderName)” in \(took)"
            progress = 1
            overallProgress = 1
        } else {
            status = "Saved \(batchSaved), \(batchFailed) failed — see details"
        }
        lastExitOK = !cancelled && batchSaved > 0
    }

    /// Folder the last download went into (playlist subfolder, or the chosen folder).
    func outputFolder(default folder: String) -> String {
        isBatch && !batchFolder.isEmpty ? batchFolder : folder
    }

    /// Updates yt-dlp through Homebrew — YouTube changes often, so this fixes most failures.
    func updateYtDlp() {
        guard !isRunning else { return }
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            status = "Homebrew not found — install it from brew.sh"
            return
        }
        resetRun()
        isBatch = false
        isRunning = true
        status = "Updating yt-dlp…"
        launch(brew, ["upgrade", "yt-dlp"], item: nil) { [weak self] code in
            guard let self else { return }
            self.isRunning = false
            self.lastExitOK = code == 0
            self.status = code == 0 ? "yt-dlp is up to date" : "Update failed — see details"
            if code == 0 { self.progress = 1 }
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        queue.removeAll()
        status = "Stopping…"
        for job in jobs.values where job.process.isRunning {
            let p = job.process
            p.interrupt()                                  // SIGINT lets yt-dlp clean up
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
        }
    }

    // MARK: - Process plumbing

    /// One running yt-dlp process and its partial output line.
    private final class Job {
        let process: Process
        let item: Int?
        var buffer = ""
        init(process: Process, item: Int?) { self.process = process; self.item = item }
    }
    private var jobs: [ObjectIdentifier: Job] = [:]

    private func resetRun() {
        cancelled = false
        lastExitOK = false
        needsSignIn = false
        progress = 0
        overallProgress = 0
        activeIndices.removeAll()
        etaText = nil
        logLines.removeAll()
        log = ""
    }

    private func launch(_ executable: String, _ arguments: [String], item: Int?,
                        onExit: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = Self.environment()
        p.standardInput = FileHandle.nullDevice
        let job = Job(process: p, item: item)
        let key = ObjectIdentifier(job)

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s, job: job) }
        }

        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                if !job.buffer.trimmingCharacters(in: .whitespaces).isEmpty { self.handle(job.buffer, job: job) }
                job.buffer = ""
                self.jobs[key] = nil
                onExit(code)
            }
        }

        if item == nil {
            appendLog("$ \(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " "))")
        }
        jobs[key] = job
        do {
            try p.run()
        } catch {
            jobs[key] = nil
            appendLog("Couldn't start: \(error.localizedDescription)")
            DispatchQueue.main.async { onExit(-1) }
        }
    }

    private func consume(_ chunk: String, job: Job) {
        job.buffer += chunk
        let parts = job.buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        job.buffer = parts.last ?? ""
        for line in parts.dropLast() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            handle(line, job: job)
        }
    }

    private func handle(_ line: String, job: Job) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let tag = job.item.map { "[#\(items[$0].index)] " } ?? ""
        // Progress lines arrive many times a second: show them in the status line, not the log.
        let isProgress = trimmed.hasPrefix("[download]") && trimmed.contains("% of")
        if !isProgress { appendLog(tag + line) }

        if trimmed.hasPrefix("[download]") {
            let ns = trimmed as NSString
            if let m = Self.percentRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
               let v = Double(ns.substring(with: m.range(at: 1))) {
                let value = min(v / 100, 1)
                if let i = job.item {
                    // Throttle: with many parallel jobs, only publish visible (≥1%) changes.
                    if abs(value - items[i].progress) >= 0.01 || value >= 1 {
                        items[i].progress = value
                        updateOverall()
                    }
                } else {
                    progress = value
                    overallProgress = value
                }
            }
            if job.item == nil {
                status = trimmed.replacingOccurrences(of: "[download]", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        } else if job.item == nil && (trimmed.hasPrefix("[Merger]") || trimmed.hasPrefix("[ExtractAudio]")
                    || trimmed.hasPrefix("[VideoConvertor]")) {
            status = trimmed.hasPrefix("[ExtractAudio]") ? "Converting to audio…" : "Finishing up with ffmpeg…"
        } else if trimmed.hasPrefix("ERROR") {
            if Self.isBotCheck(trimmed) {
                needsSignIn = true
                status = "YouTube wants a sign-in check — choose your browser under “YouTube sign-in”."
            } else if job.item == nil {
                status = trimmed
            }
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        log = logLines.joined(separator: "\n")
    }
}
