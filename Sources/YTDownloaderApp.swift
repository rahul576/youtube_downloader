import SwiftUI
import AppKit
import Combine

@main
struct YTDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Video Saver") {
            ContentView()
                .frame(minWidth: 660, minHeight: 620)
        }
        .defaultSize(width: 740, height: 900)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Downloader.shared.terminateAll() }
}

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"

// MARK: - Palette

extension Color {
    static let vsIndigo = Color(red: 0.36, green: 0.29, blue: 0.97)
    static let vsViolet = Color(red: 0.62, green: 0.28, blue: 0.93)
    static let vsPink   = Color(red: 0.96, green: 0.30, blue: 0.56)
    static let vsOrange = Color(red: 1.00, green: 0.56, blue: 0.27)
    static let vsTeal   = Color(red: 0.10, green: 0.72, blue: 0.66)
    /// Dark green with enough contrast for white text on it, or as text on the light cards.
    static let vsGreen  = Color(red: 0.02, green: 0.48, blue: 0.27)
    static let vsRed    = Color(red: 0.82, green: 0.13, blue: 0.18)
    static let vsAmber  = Color(red: 0.80, green: 0.40, blue: 0.00)
}

let brandGradient = LinearGradient(colors: [.vsIndigo, .vsViolet, .vsPink],
                                   startPoint: .leading, endPoint: .trailing)

enum QueueFilter: String, CaseIterable, Identifiable {
    case all = "All", waiting = "Waiting", active = "Downloading", saved = "Saved", failed = "Failed"
    var id: String { rawValue }
}

/// Plain ObservableObject instead of @State (avoids needing SwiftUI macro plugins with Command Line Tools).
final class FormState: ObservableObject {
    @Published var showSettings = false
    @Published var queueFilter: QueueFilter = .all
    @Published var logFilter = 0          // 0 all, 1 saved, 2 failed
}

func formatSpeed(_ bps: Double) -> String {
    guard bps > 0 else { return "—" }
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: Int64(bps)) + "/s"
}

func formatDisk(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useGB, .useTB]
    return f.string(fromByteCount: b)
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var dl = Downloader.shared
    @StateObject private var form = FormState()

    @AppStorage("folder") private var folder: String =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    @AppStorage("mode") private var mode: Mode = .video
    @AppStorage("audioFormat") private var audioFormat = "MP3"

    private let audioFormats: [(String, String)] = [("MP3", "Plays anywhere"), ("M4A", "Apple / AAC"),
                                                    ("WAV", "Uncompressed"), ("FLAC", "Lossless")]

    private var trimmedURL: String { dl.url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlLooksValid: Bool { trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://") }
    private var playlistActive: Bool { dl.playlistMode && dl.showingPlaylist }
    private var canAdd: Bool {
        urlLooksValid && !dl.fetching && (!playlistActive || dl.selectedCount > 0)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.vsIndigo, .vsViolet, .vsPink, .vsOrange],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Pinned at the top: header + live progress.
                VStack(spacing: 12) {
                    header
                    if !dl.tasks.isEmpty { progressPanel }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 14) {
                        if !dl.toolsMissing.isEmpty { missingToolsBanner }
                        if dl.needsSignIn { signInBanner }
                        linkCard
                        formatCard
                        if playlistActive { playlistCard }
                        folderCard
                        addButton
                        if !dl.tasks.isEmpty { queueCard }
                        if !dl.entries.isEmpty { logCard }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $form.showSettings) {
            SettingsView(dl: dl) { form.showSettings = false }
        }
        .onAppear { dl.diskFolder = folder }
        .onChange(of: folder) { newValue in dl.diskFolder = newValue }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Video Saver")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                    Text("v\(appVersion)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.22)))
                }
                Text("Keep videos and music for offline")
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            Spacer()
            DiskPill(free: dl.freeBytes, total: dl.totalBytes, low: dl.lowDisk, limitGB: dl.minFreeGB)
            HeaderButton(title: dl.updatingEngine ? "Updating…" : "Update engine",
                         icon: "arrow.triangle.2.circlepath") { dl.updateYtDlp() }
                .disabled(dl.updatingEngine || dl.stats.active > 0)
                .help("Updates yt-dlp. YouTube changes often, so do this if downloads start failing.")
            HeaderButton(title: "Settings", icon: "gearshape.fill") { form.showSettings = true }
        }
    }

    private var missingToolsBanner: some View {
        Label("Missing: \(dl.toolsMissing.joined(separator: ", ")). In Terminal run:  brew install yt-dlp ffmpeg",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.vsAmber))
            .textSelection(.enabled)
    }

    private var signInBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key.fill")
            Text("YouTube asked to confirm you’re not a bot. Open Settings and choose the browser you’re signed in to YouTube with.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Settings") { form.showSettings = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.25)))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.vsAmber))
    }

    // MARK: Progress panel (pinned)

    private var progressHeadline: String {
        let s = dl.stats
        let progress = "\(s.finished) of \(s.total) done"
        if s.active > 0 { return (dl.paused ? "Finishing current downloads · " : "Downloading · ") + progress }
        if dl.paused && s.waiting > 0 { return "Paused · " + progress }
        if s.waiting > 0 { return "Waiting to retry · " + progress }
        return "Finished · " + progress
    }

    private var progressPanel: some View {
        let s = dl.stats
        let finishedAll = s.active == 0 && s.waiting == 0
        return Card(nil, icon: nil, tint: .clear) {
            HStack(alignment: .firstTextBaseline) {
                Text(progressHeadline)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                if s.active > 0 {
                    Label(formatSpeed(dl.totalSpeed), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.vsIndigo)
                        .help("Total download speed across all \(s.active) running downloads")
                }
                if let eta = dl.etaText {
                    Text(eta).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text("\(Int(dl.overallProgress * 100))%")
                    .font(.system(size: 13, weight: .heavy).monospacedDigit())
            }
            ProgressBar(value: dl.overallProgress, done: finishedAll && s.failed == 0 && s.done > 0, height: 14)

            HStack(spacing: 6) {
                StatChip(label: "Saved", value: s.done, color: .vsGreen)
                StatChip(label: "Failed", value: s.failed, color: .vsRed)
                StatChip(label: "Downloading", value: s.active, color: .vsIndigo)
                StatChip(label: "Waiting", value: s.waiting - s.retrying, color: .secondary)
                if s.retrying > 0 { StatChip(label: "Retrying", value: s.retrying, color: .vsAmber) }
                Spacer()
            }

            // Running downloads, each with its own bar and speed.
            let running = dl.tasks.filter { $0.state == .downloading }
            if !running.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(running) { t in
                            HStack(spacing: 8) {
                                Text(t.title)
                                    .font(.system(size: 11))
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if t.attempts > 1 {
                                    Text("retry \(t.attempts - 1)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.vsAmber)
                                }
                                Text(formatSpeed(t.speed))
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 74, alignment: .trailing)
                                ProgressBar(value: t.progress, done: false, height: 6)
                                    .frame(width: 140)
                                Text("\(Int(t.progress * 100))%")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(running.count), 4) * 20)
            }

            if finishedAll && s.finished > 0 {
                ResultBanner(saved: s.done, failed: s.failed)
            } else if dl.pausedForDisk {
                Label(dl.status, systemImage: "externaldrive.fill.badge.exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.vsRed))
            }

            HStack(spacing: 8) {
                if s.active > 0 || s.waiting > 0 {
                    if dl.paused {
                        ActionButton(title: "Resume", icon: "play.fill", color: .vsGreen) { dl.resume() }
                    } else {
                        ActionButton(title: "Pause", icon: "pause.fill", color: .vsIndigo) { dl.pause() }
                    }
                    ActionButton(title: "Stop all", icon: "stop.fill", color: .vsRed) { dl.stopAll() }
                }
                if s.failed + s.cancelled > 0 {
                    ActionButton(title: "Retry failed (\(s.failed + s.cancelled))",
                                 icon: "arrow.clockwise", color: .vsAmber) { dl.retryFailed() }
                }
                Spacer()
                if let f = dl.lastFolder {
                    PillButton(title: "Show in Finder", icon: "folder", color: .vsGreen) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: f))
                    }
                }
                if s.finished + s.cancelled > 0 {
                    PillButton(title: "Clear finished", icon: "trash", color: .secondary) { dl.clearFinished() }
                }
            }
        }
    }

    // MARK: Link

    private var linkCard: some View {
        Card("Link", icon: "link", tint: .vsIndigo) {
            HStack(spacing: 8) {
                TextField("Paste a YouTube video or playlist link…", text: $dl.url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.vsIndigo.opacity(0.35), lineWidth: 1))
                    .onSubmit(addToQueue)
                PillButton(title: "Paste", icon: "doc.on.clipboard", color: .vsIndigo) {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        dl.url = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if !dl.url.isEmpty {
                    Button { dl.url = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }

            if dl.fetching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(dl.playlistMode && Downloader.hasPlaylist(trimmedURL)
                         ? "Loading the playlist…" : "Checking available qualities…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else if let err = dl.infoError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.vsAmber)
                    .lineLimit(3)
            } else if let info = dl.info {
                preview(info)
            }
        }
    }

    private func preview(_ info: VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: info.thumbnail) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    LinearGradient(colors: [.vsIndigo.opacity(0.3), .vsPink.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: info.isPlaylist ? "list.bullet.rectangle" : "play.rectangle.fill")
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 136, height: 77)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(info.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if info.isPlaylist {
                        Tag(text: "Playlist" + (info.count.map { " · \($0) videos" } ?? ""), color: .vsViolet)
                    } else if let best = info.heights.first {
                        Tag(text: "Up to \(qualityName(best))", color: .vsGreen)
                    }
                    if let d = info.duration { Tag(text: formatDuration(d), color: .vsAmber) }
                }
                if let u = info.uploader {
                    Text(u).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: Format

    private var formatCard: some View {
        Card("Format", icon: "slider.horizontal.3", tint: .vsPink) {
            HStack(spacing: 10) {
                ModeTile(title: "Video", subtitle: "MP4", icon: "film.fill",
                         colors: [.vsIndigo, .vsViolet], selected: mode == .video) { mode = .video }
                ModeTile(title: "Audio only", subtitle: audioFormat, icon: "music.note",
                         colors: [.vsPink, .vsOrange], selected: mode == .audio) { mode = .audio }
            }

            Text(mode == .video ? "Quality" : "Audio format")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if mode == .video { videoChips } else { audioChips }
                }
                .padding(.vertical, 2)
            }

            Toggle(isOn: $dl.playlistMode) {
                Text("Download the whole playlist").font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .tint(.vsViolet)
            .help("If the link is a playlist (or a video inside one), list every video so you can pick which to save")
            .padding(.top, 4)
            if dl.playlistMode && urlLooksValid && !Downloader.hasPlaylist(trimmedURL) {
                Text("This link isn’t part of a playlist, so only this video will be saved.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var videoChips: some View {
        if let info = dl.info, !info.isPlaylist, !info.heights.isEmpty {
            ForEach(info.heights, id: \.self) { h in
                Chip(title: qualityName(h),
                     subtitle: info.sizes[h].map { "~" + formatBytes($0) } ?? resolutionBadge(for: h),
                     selected: dl.height == h) { dl.height = h }
            }
        } else if dl.fetching {
            Text("Waiting for link details…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
        } else {
            Chip(title: "Best", subtitle: "Highest available", selected: dl.height == nil) { dl.height = nil }
            ForEach([2160, 1440, 1080, 720, 480], id: \.self) { h in
                Chip(title: qualityName(h), subtitle: "max", selected: dl.height == h) { dl.height = h }
            }
        }
    }

    @ViewBuilder private var audioChips: some View {
        ForEach(audioFormats, id: \.0) { fmt in
            Chip(title: fmt.0, subtitle: fmt.1, selected: audioFormat == fmt.0) { audioFormat = fmt.0 }
        }
    }

    // MARK: Playlist

    private var playlistCard: some View {
        Card("Playlist", icon: "list.bullet.rectangle.portrait.fill", tint: .vsViolet) {
            HStack(spacing: 8) {
                Text("\(dl.selectedCount) of \(dl.items.count) selected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                PillButton(title: "Select all", icon: "checkmark.circle", color: .vsViolet) { dl.setAll(selected: true) }
                PillButton(title: "Select none", icon: "circle", color: .vsViolet) { dl.setAll(selected: false) }
            }
            Text("Click a video to include or skip it. You can add more videos or other links while downloads run.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 14) {
                    ForEach(dl.items) { item in
                        PlaylistTile(item: item) { dl.toggle(item) }
                    }
                }
                .padding(4)
            }
            .frame(height: min(440, CGFloat((dl.items.count + 3) / 4) * 150 + 20))
        }
    }

    // MARK: Folder

    private var folderCard: some View {
        Card("Save to", icon: "folder.fill", tint: .vsTeal) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(LinearGradient(colors: [.vsTeal, .vsIndigo],
                                                    startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: folder).lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                    Text(displayPath(folder))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .help(folder)
                Spacer()
                PillButton(title: "Change", icon: "folder.badge.gearshape", color: .vsIndigo, action: chooseFolder)
                PillButton(title: "Open", icon: "arrow.up.forward.app", color: .vsIndigo) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                }
            }
            if let free = dl.freeBytes, let total = dl.totalBytes, total > 0 {
                DiskBar(free: free, total: total, low: dl.lowDisk, limitGB: dl.minFreeGB)
            }
        }
    }

    // MARK: Add to queue

    private var addButton: some View {
        VStack(spacing: 6) {
            Button(action: addToQueue) {
                Label(addLabel, systemImage: dl.isBusy ? "text.badge.plus" : "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(brandGradient))
                    .shadow(color: Color.vsViolet.opacity(0.4), radius: 8, y: 4)
                    .opacity(canAdd ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .keyboardShortcut(.defaultAction)

            if !dl.status.isEmpty && dl.status != "Ready" && !dl.pausedForDisk {
                Text(dl.status)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.28)))
            }
        }
    }

    private var addLabel: String {
        let what = mode == .audio ? "\(audioFormat)" : (dl.height.map(qualityName) ?? "best quality")
        let verb = dl.isBusy || dl.paused ? "Add" : "Download"
        if playlistActive {
            let n = dl.selectedCount
            if n == 0 { return "Select videos to download" }
            let noun = n == 1 ? "video" : "videos"
            return dl.isBusy || dl.paused ? "Add \(n) \(noun) to queue · \(what)" : "Download \(n) \(noun) · \(what)"
        }
        return dl.isBusy || dl.paused ? "\(verb) to queue · \(what)" : "\(verb) · \(what)"
    }

    // MARK: Queue list

    private var filteredTasks: [DownloadTask] {
        switch form.queueFilter {
        case .all: return dl.tasks
        case .waiting: return dl.tasks.filter { $0.state == .waiting }
        case .active: return dl.tasks.filter { $0.state == .downloading }
        case .saved: return dl.tasks.filter { $0.state == .done }
        case .failed: return dl.tasks.filter { $0.state == .failed || $0.state == .cancelled }
        }
    }

    private var queueCard: some View {
        Card("Queue", icon: "list.number", tint: .vsIndigo) {
            HStack(spacing: 6) {
                ForEach(QueueFilter.allCases) { f in
                    Chip(title: f.rawValue, subtitle: nil, selected: form.queueFilter == f) { form.queueFilter = f }
                }
                Spacer()
            }
            let list = filteredTasks
            if list.isEmpty {
                Text("Nothing here.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(list) { t in
                            QueueRow(task: t, maxRetries: dl.maxRetries) { dl.remove(t.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(CGFloat(list.count) * 50, 300))
            }
        }
    }

    // MARK: Activity log (saved + failed only)

    private var logCard: some View {
        let saved = dl.entries.filter(\.ok).count
        let failed = dl.entries.count - saved
        let shown = dl.entries.reversed().filter { form.logFilter == 0 || (form.logFilter == 1) == $0.ok }
        return Card("Activity log", icon: "doc.text.magnifyingglass", tint: .vsGreen) {
            HStack(spacing: 6) {
                Chip(title: "All \(dl.entries.count)", subtitle: nil, selected: form.logFilter == 0) { form.logFilter = 0 }
                Chip(title: "Saved \(saved)", subtitle: nil, selected: form.logFilter == 1) { form.logFilter = 1 }
                Chip(title: "Failed \(failed)", subtitle: nil, selected: form.logFilter == 2) { form.logFilter = 2 }
                Spacer()
                PillButton(title: "Copy", icon: "doc.on.doc", color: .vsIndigo) { copyLog() }
                PillButton(title: "Clear", icon: "trash", color: .secondary) { dl.clearLog() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { e in LogRow(entry: e) }
                }
                .padding(8)
            }
            .frame(height: min(CGFloat(shown.count) * 30 + 16, 220))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    private func copyLog() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = dl.entries.map { e in
            "\(df.string(from: e.date))  \(e.ok ? "SAVED " : "FAILED")  \(e.title)" + (e.detail.map { "  (\($0))" } ?? "")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Actions & helpers

    private func addToQueue() {
        guard canAdd else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        dl.enqueueCurrent(folder: folder, mode: mode, height: dl.height, audioFormat: audioFormat)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let u = panel.url { folder = u.path }
    }

    private func displayPath(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var dl: Downloader
    let close: () -> Void
    @AppStorage("cookiesBrowser") private var cookiesBrowser = ""
    private let browsers = ["Chrome", "Safari", "Firefox", "Brave", "Edge"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 18, weight: .heavy))
                Spacer()
                Text("Video Saver v\(appVersion)").font(.caption).foregroundStyle(.secondary)
            }

            setting("Retry failed downloads",
                    "If a download fails, try it again automatically this many times (waiting a few seconds longer each time).") {
                ForEach([0, 1, 2, 3, 5], id: \.self) { n in
                    Chip(title: n == 0 ? "Off" : "\(n)", subtitle: nil, selected: dl.maxRetries == n, compact: true) { dl.maxRetries = n }
                }
            }

            setting("Download at once",
                    "How many files download at the same time. 4 is a good balance; 8 is fastest, but YouTube may ask for a sign-in check sooner.") {
                ForEach([1, 2, 4, 6, 8], id: \.self) { n in
                    Chip(title: "\(n)", subtitle: nil, selected: dl.parallel == n, compact: true) { dl.parallel = n }
                }
            }

            setting("Pause when free space is low",
                    "The queue pauses by itself when the disk you save to has less free space than this, and carries on when space is freed.") {
                ForEach([0, 1, 2, 5, 10, 20], id: \.self) { n in
                    Chip(title: n == 0 ? "Never" : "\(n) GB", subtitle: nil, selected: dl.minFreeGB == n, compact: true) { dl.minFreeGB = n }
                }
            }

            setting("YouTube sign-in",
                    "Only needed if YouTube says “confirm you’re not a bot”. The app borrows your browser’s YouTube sign-in (macOS may ask permission once).") {
                Chip(title: "Off", subtitle: nil, selected: cookiesBrowser.isEmpty, compact: true) { cookiesBrowser = ""; dl.refetch() }
                ForEach(browsers, id: \.self) { b in
                    Chip(title: b, subtitle: nil, selected: cookiesBrowser == b, compact: true) { cookiesBrowser = b; dl.refetch() }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func setting<C: View>(_ title: String, _ help: String, @ViewBuilder _ chips: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .bold))
            Text(help).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) { chips() }
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Small components for v2

struct HeaderButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.18)))
                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct DiskPill: View {
    let free: Int64?
    let total: Int64?
    let low: Bool
    let limitGB: Int
    var body: some View {
        if let free {
            Label(formatDisk(free) + " free", systemImage: low ? "externaldrive.fill.badge.exclamationmark" : "internaldrive.fill")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Capsule().fill(low ? Color.vsRed : Color.black.opacity(0.22)))
                .help(total.map { "Free space on the disk you save to: \(formatDisk(free)) of \(formatDisk($0))" } ?? "")
        }
    }
}

struct DiskBar: View {
    let free: Int64
    let total: Int64
    let low: Bool
    let limitGB: Int
    var body: some View {
        let used = Double(total - free) / Double(total)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(low ? Color.vsRed : (used > 0.9 ? Color.vsAmber : Color.vsIndigo))
                        .frame(width: g.size.width * min(max(used, 0), 1))
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(formatDisk(free)) free of \(formatDisk(total))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(low ? Color.vsRed : Color.secondary)
                Spacer()
                Text(limitGB > 0 ? "Queue pauses below \(limitGB) GB" : "Low-space pause is off")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}

struct StatChip: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)").font(.system(size: 12, weight: .heavy).monospacedDigit())
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(value > 0 ? Color.white : Color.secondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(value > 0 ? AnyShapeStyle(color) : AnyShapeStyle(Color.primary.opacity(0.06))))
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Solid, high-contrast summary of a finished queue (white text on dark green / amber).
struct ResultBanner: View {
    let saved: Int
    let failed: Int
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(failed == 0
                 ? "All \(saved) saved"
                 : "Saved \(saved) · \(failed) failed. Press Retry failed to try them again.")
            Spacer(minLength: 0)
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(failed == 0 ? Color.vsGreen : Color.vsAmber))
    }
}

struct QueueRow: View {
    let task: DownloadTask
    let maxRetries: Int
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: task.thumbnail) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.primary.opacity(0.08)
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(task.groupTitle).lineLimit(1)
                    Text("·")
                    Text(task.kindLabel)
                    if task.state == .failed, let e = task.lastError {
                        Text("·")
                        Text(e).foregroundStyle(Color.vsRed).lineLimit(1)
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                if task.state == .downloading {
                    ProgressBar(value: task.progress, done: false, height: 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            badge
            if task.state == .waiting {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .help(task.lastError ?? task.title)
    }

    @ViewBuilder private var badge: some View {
        switch task.state {
        case .waiting:
            if task.attempts > 0 {
                pill("Retry \(task.attempts) of \(maxRetries)", .vsAmber)
            } else {
                pill("Waiting", .gray)
            }
        case .downloading:
            pill("\(Int(task.progress * 100))% · \(formatSpeed(task.speed))", .vsIndigo)
        case .done: pill("Saved", .vsGreen)
        case .failed: pill("Failed", .vsRed)
        case .cancelled: pill("Stopped", .gray)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color))
    }
}

struct LogRow: View {
    let entry: LogEntry
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(entry.ok ? Color.vsGreen : Color.vsRed)
            Text(Self.time.string(from: entry.date))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let d = entry.detail {
                    Text(d).font(.system(size: 10))
                        .foregroundStyle(entry.ok ? Color.secondary : Color.vsRed)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }
}

// MARK: - Formatting

func qualityName(_ h: Int) -> String { "\(h)p" }

func resolutionBadge(for h: Int) -> String {
    switch h {
    case 4320...: return "8K"
    case 2160..<4320: return "4K"
    case 1440..<2160: return "2K"
    case 720..<1440: return "HD"
    default: return "SD"
    }
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useMB, .useGB]
    return f.string(fromByteCount: b)
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

// MARK: - Components

struct Card<Content: View>: View {
    let title: String?
    let icon: String?
    let tint: Color
    let content: Content

    init(_ title: String?, icon: String?, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tint))
                    }
                    Text(title).font(.system(size: 13, weight: .bold))
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
    }
}

struct Chip: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10, weight: .medium)).opacity(0.75)
                }
            }
            .frame(minWidth: compact ? 40 : 72)
            .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? AnyShapeStyle(brandGradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ModeTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(selected ? Color.white.opacity(0.25)
                                                       : colors[0].opacity(0.15)))
                    .foregroundStyle(selected ? Color.white : colors[0])
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .bold))
                    Text(subtitle).font(.system(size: 11)).opacity(0.75)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 16)) }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading,
                                                                  endPoint: .bottomTrailing))
                                   : AnyShapeStyle(Color.primary.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(color)
                .background(Capsule().fill(color.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct ProgressBar: View {
    let value: Double
    let done: Bool
    let height: CGFloat

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(done ? AnyShapeStyle(Color.vsGreen) : AnyShapeStyle(brandGradient))
                    .frame(width: max(0, g.size.width * min(max(value, 0), 1)))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: height)
    }
}

struct PlaylistTile: View {
    let item: PlaylistItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    AsyncImage(url: item.thumbnail) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        LinearGradient(colors: [.vsIndigo.opacity(0.35), .vsPink.opacity(0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: 96)
                    .clipped()
                    .saturation(item.selected ? 1 : 0)

                    // badges
                    VStack {
                        HStack {
                            Text("\(item.index)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                                .foregroundStyle(.white)
                            Spacer()
                            selectionBadge
                        }
                        Spacer()
                        HStack {
                            stateBadge
                            Spacer()
                            if let d = item.duration {
                                Text(formatDuration(d))
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(6)

                    if item.state == .downloading {
                        VStack {
                            Spacer()
                            ProgressBar(value: item.progress, done: false, height: 5)
                                .padding(.horizontal, 6).padding(.bottom, 3)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(item.selected ? Color.vsViolet : Color.clear, lineWidth: 2.5)
                )

                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
            }
            .opacity(item.selected ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.selected ? "Click to skip" : "Click to include")
    }

    private var selectionBadge: some View {
        Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color.white)
            .background(Circle().fill(item.selected ? Color.vsViolet : Color.black.opacity(0.35)).padding(1))
    }

    @ViewBuilder private var stateBadge: some View {
        switch item.state {
        case .done:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.vsGreen))
                .foregroundStyle(.white)
        case .queued:
            Label("Queued", systemImage: "clock.fill")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .foregroundStyle(.white)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.vsRed))
                .foregroundStyle(.white)
        case .downloading:
            Text("\(Int(item.progress * 100))%")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.vsViolet))
                .foregroundStyle(.white)
        default:
            EmptyView()
        }
    }
}
