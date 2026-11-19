# Changelog

## 2.0.0 (2026-11-20)

### New
- **Download queue.** Add single videos and playlists at any time, even while downloads run. Each item keeps its own format, quality and folder. Duplicates are skipped. Waiting items can be removed. The list can be filtered by All, Waiting, Downloading, Saved or Failed, and finished items can be cleared.
- **Automatic retries.** Failed downloads are retried automatically: 3 times by default, adjustable from 0 to 5 in Settings. The pause between tries grows: 5 s, 10 s, 15 s and so on.
- **Retry failed** button, which puts every failed or stopped download back in the queue.
- **Progress panel pinned to the top.** It shows overall progress and the total download speed across all parallel downloads, plus time remaining. Below that are Saved, Failed, Downloading, Waiting and Retrying counts, a row per active download (speed and percentage), and Pause, Resume and Stop all buttons.
- **Free disk space tracking.**
  - Free space is shown in the header, and a usage bar appears under *Save to*.
  - The queue pauses automatically when free space drops below a limit (2 GB by default, set in Settings), then resumes by itself once space is freed.
- **Settings panel**: retries, downloads at once, the low-space limit and YouTube sign-in.
- **Activity log** shows only saved and failed downloads, with the failure reason and number of tries. It can be filtered and copied to the clipboard.
- The Mac stays awake while the queue is working, and quitting the app stops any running downloads.
- `build.sh --dist` builds a universal (Apple Silicon + Intel) app and zips it for release.

### Changed
- Success and failure messages are white text on solid dark green or amber, instead of teal text that was hard to read on the gradient.
- Playlist selection is no longer locked while downloading. Tiles show *Queued*, live percentage, *Saved* or *Failed*.
- "Download at once" and YouTube sign-in moved into Settings. The sign-in banner appears on the main screen only when YouTube asks for it.
- The version number is shown in the header.

## 1.0.0 (2026-11-02)

First release.
- Single video download with per-video quality detection (only the resolutions that video has, with sizes), H.264/AAC MP4 preferred.
- Audio only: MP3, M4A, WAV or FLAC.
- Playlist picker with thumbnails, select all or none, and folders named after the playlist.
- Parallel playlist downloads (1–8 at once) with per-item and overall progress.
- YouTube sign-in helper, Update engine button, one-command build and install script.
