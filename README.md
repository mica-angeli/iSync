# iSync

A small macOS app that puts music on your iPhone's built-in **Music** app — no Finder sync, no
Music-app library needed.

Drag songs or whole folders onto the window. iSync:

1. reads every file (any format FFmpeg understands — FLAC, ALAC, WAV, AIFF, MP3, AAC, Ogg Vorbis,
   Opus, WMA, APE, WavPack, DSD …),
2. checks whether the connected iPhone already has each song and skips the ones it does,
3. converts the rest to a format the iPhone plays —
   - **lossless → Apple Lossless (ALAC) in `.m4a`**, bit-perfect, keeping 16/24-bit and the sample rate,
   - MP3, AAC and ALAC files are already compatible and are sent untouched,
   - other lossy formats (Ogg, Opus, WMA …) → 256 kbps AAC,
4. keeps **all tags and all embedded artwork** (standard iTunes atoms plus a freeform atom for every
   other tag, e.g. MusicBrainz IDs and ReplayGain; every picture, front cover first),
5. syncs the songs into the iPhone's music library with their cover art, and confirms each one
   arrived.

## Requirements

- macOS 14 or later (built with Xcode 16+ / Swift 5 language mode).
- **FFmpeg**: `brew install ffmpeg`. iSync looks in `/opt/homebrew/bin`, `/usr/local/bin`,
  `/opt/local/bin` and `PATH`. You can also drop `ffmpeg`/`ffprobe` into `iSync.app/Contents/MacOS`, or
  point to them with `defaults write app.isync.iSync ffmpegPath /path/to/ffmpeg` (and `ffprobePath`).
- An iPhone that trusts this Mac. Connect it with a USB cable, unlock it and tap **Trust** if asked.
  (A phone that Finder can see over Wi-Fi works too; USB is preferred when both are available.)
- On the iPhone, music from a computer must be allowed. If **Sync Library** (iCloud Music Library)
  is turned on in *Settings › Apps › Music*, the iPhone may refuse music from a computer; iSync tells
  you when that happens.
- No unfinished sync from Finder. If an earlier Finder sync stopped before copying all the songs, the
  iPhone keeps listing those songs without their audio and asks the next computer to supply it. iSync
  can't, and the iPhone would remove each one it isn't given, so iSync won't sync until Finder has
  finished. iSync tells you how many songs are waiting.

## Build and run

```bash
open iSync.xcodeproj          # then ⌘R
# or from the command line:
xcodebuild -project iSync.xcodeproj -scheme iSync -configuration Release build
xcodebuild -project iSync.xcodeproj -scheme iSync test
```

The app is not sandboxed (it must talk to `usbmuxd` and run FFmpeg) and is signed ad hoc for local use.

## Using it

- Drop files or folders on the window, or use **File › Add Music…** (⌘O).
- Each song shows its format plan (e.g. `FLAC → ALAC 24-bit`) and its status: *Already on iPhone*,
  *Converting…*, *Copying…*, *Synced*, or why it couldn't be synced.
- Songs dropped before an iPhone is connected wait and sync as soon as one appears.
- **Stop** cancels; **Retry Failed** tries failed songs again; **Clear Finished** tidies the list.
- **View › Show Log** (⌥⌘L) shows what's happening; the log is also written to
  `~/Library/Logs/iSync/iSync.log`.

A song counts as already on the iPhone when its title, artist and album match a song stored on the
phone (ignoring case, accents and punctuation) and the durations agree within three seconds. Songs
that are in your Apple Music or iCloud library but not downloaded don't count, so iSync syncs them.

## How it works

The Music app only plays songs registered through the iPhone's AirTraffic sync service — the same
service Finder uses. iSync speaks that protocol itself:

- **MobileDevice.framework** (Apple's private framework, loaded at run time) finds the iPhone, handles
  pairing and opens service connections; its **AFC** client copies files to and from the phone.
- iSync copies the phone's `MediaLibrary.sqlitedb` to read what's already there, writes a signed
  operation file describing the new songs, and uploads audio and artwork when the phone asks for them.

The protocol is documented by the [rustunes](https://github.com/fbiba/rustunes) project, a Linux
implementation, whose write-up iSync follows. See [docs/DESIGN.md](docs/DESIGN.md) for the details and
for why Finder's own sync engine and the AirTrafficHost framework can't be used directly by a
third-party app.

## Caveats

- **Finder sync can undo iSync.** If this iPhone is also set up to sync music from your Mac in Finder,
  the next Finder sync notices the iPhone's library changed and makes it match the Mac's Music
  library again, which removes songs iSync added. Use one or the other for music.
- iSync only adds songs. It never deletes or edits anything already on the iPhone.
- Apple can change the sync protocol in any iOS update. iSync stops and reports an error rather than
  guessing when the phone answers unexpectedly.
- Songs are matched by tags, not audio fingerprints, so a differently tagged copy of a song counts as
  a new song.
- MP3 and AAC files are registered without gapless-playback timing (the phone accepts this), so a
  gapless album in those formats may show tiny gaps between tracks. ALAC is unaffected.

## Status

Verified against a real iPhone (iOS 27.2): device discovery, lockdown sessions, Apple's AFC client
(listing, stat, reads, a 28 MB library database copy) and reading a 16,000-song library. A full sync
over USB (2026-11-06) worked end to end: a tagged FLAC with cover art was converted to ALAC, the
phone accepted the signed song list, took the audio and cover, and listed the song with its file.

That session also showed that the iPhone deletes songs left over from an unfinished Finder sync when
another computer can't supply their audio. iSync now refuses to sync in that situation; see
[docs/DESIGN.md](docs/DESIGN.md#songs-waiting-for-audio-from-another-host). Conversion, tagging and
the sync session are also covered by automated tests, including a simulated iPhone that checks every
protocol message, the signed operation file and the uploads.

## Project layout

```
iSync/App       SwiftUI app, sync engine (pipeline orchestration)
iSync/Device    MobileDevice bindings, Apple AFC client, ATC framing, Grappa signing, Wi-Fi heartbeat
iSync/Sync      Phone library snapshot, duplicate detection, operation file, ATC sync session
iSync/Media     ffprobe/ffmpeg, tag normalisation, conversion planning, MP4 tag writer, cover art
iSyncTests      Unit tests, real-FFmpeg conversion tests, and a simulated iPhone for full sync sessions
```

## Acknowledgements

Protocol knowledge, the Grappa signing calculation and its test vectors come from
[rustunes](https://github.com/fbiba/rustunes) (MIT License, © 2026 Feim Biba). iSync is not affiliated
with Apple. iPhone, Finder and Apple Music are trademarks of Apple Inc.
