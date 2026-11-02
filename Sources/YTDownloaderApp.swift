import SwiftUI
import AppKit
import Combine

@main
struct YTDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Video Saver") {
            ContentView()
                .frame(minWidth: 620, minHeight: 560)
        }
        .defaultSize(width: 680, height: 800)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Palette

extension Color {
    static let vsIndigo = Color(red: 0.36, green: 0.29, blue: 0.97)
    static let vsViolet = Color(red: 0.62, green: 0.28, blue: 0.93)
    static let vsPink   = Color(red: 0.96, green: 0.30, blue: 0.56)
    static let vsOrange = Color(red: 1.00, green: 0.56, blue: 0.27)
    static let vsTeal   = Color(red: 0.10, green: 0.72, blue: 0.66)
}

let brandGradient = LinearGradient(colors: [.vsIndigo, .vsViolet, .vsPink],
                                   startPoint: .leading, endPoint: .trailing)

/// Plain ObservableObject instead of @State (avoids needing SwiftUI macro plugins with Command Line Tools).
final class FormState: ObservableObject {
    @Published var showLog = false
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var dl = Downloader()
    @StateObject private var form = FormState()

    @AppStorage("folder") private var folder: String =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    @AppStorage("mode") private var mode: Mode = .video
    @AppStorage("audioFormat") private var audioFormat = "MP3"
    @AppStorage("cookiesBrowser") private var cookiesBrowser = ""

    private let audioFormats: [(String, String)] = [("MP3", "Plays anywhere"), ("M4A", "Apple / AAC"),
                                                    ("WAV", "Uncompressed"), ("FLAC", "Lossless")]

    private var trimmedURL: String { dl.url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlLooksValid: Bool { trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://") }
    private var playlistActive: Bool { dl.playlistMode && dl.showingPlaylist }
    private var canDownload: Bool {
        urlLooksValid && !dl.isRunning && !dl.fetching && (!playlistActive || dl.selectedCount > 0)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.vsIndigo, .vsViolet, .vsPink, .vsOrange],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    header
                    if !dl.toolsMissing.isEmpty { missingToolsBanner }
                    linkCard
                    formatCard
                    if playlistActive { playlistCard }
                    signInCard
                    folderCard
                    actionCard
                }
                .padding(20)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video Saver")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("Keep videos and music for offline")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            Spacer()
            Button { dl.updateYtDlp() } label: {
                Label("Update engine", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(dl.isRunning)
            .help("Updates yt-dlp. YouTube changes often — do this if downloads start failing.")
        }
        .padding(.bottom, 4)
    }

    private var missingToolsBanner: some View {
        Label("Missing: \(dl.toolsMissing.joined(separator: ", ")). In Terminal run:  brew install yt-dlp ffmpeg",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.9)))
            .textSelection(.enabled)
    }

    // MARK: Link

    private var linkCard: some View {
        Card("Link", icon: "link", tint: .vsIndigo) {
            HStack(spacing: 8) {
                TextField("Paste a YouTube link…", text: $dl.url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.vsIndigo.opacity(0.35), lineWidth: 1))
                    .onSubmit(startDownload)
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
                    Text("Checking available qualities…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else if let err = dl.infoError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.vsOrange)
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
                        Tag(text: "Up to \(qualityName(best))", color: .vsTeal)
                    }
                    if let d = info.duration { Tag(text: formatDuration(d), color: .vsOrange) }
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
            .disabled(dl.isRunning)
            .help("If the link is a playlist (or a video inside one), list every video so you can pick which to save")
            .padding(.top, 4)
            if dl.playlistMode && urlLooksValid && !Downloader.hasPlaylist(trimmedURL) {
                Text("This link isn’t part of a playlist — only this video will be saved.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if dl.playlistMode && dl.fetching {
                Text("Loading the playlist…").font(.system(size: 11)).foregroundStyle(.secondary)
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

    // MARK: Sign-in

    private let browsers = ["Chrome", "Safari", "Firefox", "Brave", "Edge"]

    private var signInCard: some View {
        Card("YouTube sign-in", icon: "person.badge.key.fill", tint: .vsOrange) {
            Text(dl.needsSignIn
                 ? "YouTube is asking to confirm you’re not a bot. Pick the browser where you’re signed in to YouTube — the app borrows that sign-in (macOS may ask for permission once)."
                 : "Only needed if YouTube says “confirm you’re not a bot”. Uses your browser’s YouTube sign-in.")
                .font(.system(size: 12))
                .foregroundStyle(dl.needsSignIn ? Color.vsOrange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "Off", subtitle: nil, selected: cookiesBrowser.isEmpty) {
                        cookiesBrowser = ""; dl.refetch()
                    }
                    ForEach(browsers, id: \.self) { b in
                        Chip(title: b, subtitle: nil, selected: cookiesBrowser == b) {
                            cookiesBrowser = b; dl.refetch()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.vsOrange, lineWidth: dl.needsSignIn ? 2 : 0)
        )
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
            .disabled(dl.isRunning)
            Text(dl.isRunning ? "Downloading — selection is locked." : "Click a video to include or skip it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.fill").foregroundStyle(Color.vsOrange)
                Text("Download at once").font(.system(size: 12, weight: .semibold))
                ForEach([1, 2, 4, 6, 8], id: \.self) { n in
                    Chip(title: "\(n)", subtitle: nil, selected: dl.parallel == n) { dl.parallel = n }
                }
                Spacer()
            }
            .help("How many videos download at the same time. 4 is a good balance; 8 is fastest but YouTube may ask for a sign-in check sooner.")

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 14) {
                    ForEach(dl.items) { item in
                        PlaylistTile(item: item, locked: dl.isRunning) { dl.toggle(item) }
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
                PillButton(title: "Change", icon: "folder.badge.gearshape", color: .vsTeal, action: chooseFolder)
                PillButton(title: "Open", icon: "arrow.up.forward.app", color: .vsTeal) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                }
            }
        }
    }

    // MARK: Action + progress + details

    private var actionCard: some View {
        Card(nil, icon: nil, tint: .clear) {
            if dl.isRunning {
                Button { dl.cancel() } label: {
                    Label("Cancel", systemImage: "stop.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: startDownload) {
                    Label(downloadLabel, systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(brandGradient))
                        .shadow(color: Color.vsViolet.opacity(0.4), radius: 8, y: 4)
                        .opacity(canDownload ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!canDownload)
                .keyboardShortcut(.defaultAction)
            }

            if dl.isBatch && (dl.isRunning || dl.batchTotal > 0) {
                VStack(alignment: .leading, spacing: 4) {
                    if dl.isRunning && !dl.activeIndices.isEmpty {
                        Text("Downloading now (\(dl.activeIndices.count) at once)")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        ForEach(dl.activeIndices, id: \.self) { i in
                            if i < dl.items.count {
                                let item = dl.items[i]
                                HStack(spacing: 8) {
                                    Text("#\(item.index)")
                                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                                        .foregroundStyle(Color.vsViolet)
                                        .frame(width: 38, alignment: .leading)
                                    Text(item.title)
                                        .font(.system(size: 11))
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ProgressBar(value: item.progress, done: false, height: 6)
                                        .frame(width: 160)
                                    Text("\(Int(item.progress * 100))%")
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 34, alignment: .trailing)
                                }
                            }
                        }
                    }

                    HStack {
                        Text(overallText)
                        Spacer()
                        if let eta = dl.etaText, dl.isRunning { Text(eta) }
                        Text("\(Int(dl.overallProgress * 100))%").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                    ProgressBar(value: dl.overallProgress, done: dl.lastExitOK, height: 12)
                }
                .padding(.top, 4)
            } else {
                ProgressBar(value: dl.progress, done: dl.lastExitOK, height: 10)
                    .padding(.top, 4)
            }

            HStack(alignment: .top) {
                if dl.lastExitOK && !dl.isRunning {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.vsTeal)
                }
                Text(dl.status)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                Spacer()
                if dl.lastExitOK && !dl.isRunning {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: dl.outputFolder(default: folder))) }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .semibold))
                }
            }

            Divider().padding(.vertical, 2)

            Button { form.showLog.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(form.showLog ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: form.showLog)
                    Text(form.showLog ? "Hide details" : "Show details")
                    Spacer()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if form.showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(dl.log.isEmpty ? "Nothing yet." : dl.log)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .frame(height: 150)                      // fixed: never takes over the window
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .onChange(of: dl.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }

    private var downloadLabel: String {
        if playlistActive {
            let n = dl.selectedCount
            let what = mode == .audio ? "as \(audioFormat)" : (dl.height.map(qualityName) ?? "best quality")
            return n == 0 ? "Select videos to download" : "Download \(n) \(n == 1 ? "video" : "videos") · \(what)"
        }
        switch mode {
        case .audio: return "Download \(audioFormat)"
        case .video: return "Download " + (dl.height.map(qualityName) ?? "best quality")
        }
    }

    private var overallText: String {
        var t = "Overall: \(dl.batchSaved) of \(dl.batchTotal) saved"
        if dl.batchFailed > 0 { t += " · \(dl.batchFailed) failed" }
        if dl.isRunning { t += " · \(dl.activeIndices.count) in progress" }
        return t
    }

    private var statusColor: Color {
        if dl.status.hasPrefix("ERROR") || dl.status.hasPrefix("Failed") { return .red }
        if dl.lastExitOK { return .vsTeal }
        return .secondary
    }

    // MARK: Actions & helpers

    private func startDownload() {
        guard canDownload else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        dl.download(folder: folder, mode: mode, height: dl.height, audioFormat: audioFormat)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10, weight: .medium)).opacity(0.75)
                }
            }
            .frame(minWidth: 72)
            .padding(.horizontal, 12).padding(.vertical, 8)
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
                Capsule().fill(done ? AnyShapeStyle(Color.vsTeal) : AnyShapeStyle(brandGradient))
                    .frame(width: max(0, g.size.width * min(max(value, 0), 1)))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: height)
    }
}

struct PlaylistTile: View {
    let item: PlaylistItem
    let locked: Bool
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
        .help(locked ? item.title : (item.selected ? "Click to skip" : "Click to include"))
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
                .background(Capsule().fill(Color.vsTeal))
                .foregroundStyle(.white)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
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
