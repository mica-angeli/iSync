# iSync design notes

## How music reaches the iPhone's Music app

The stock Music app only plays tracks that a host computer registered through the phone's
**AirTraffic** sync service (`com.apple.atc`). Finder does this with Apple's sync engine; iSync
does the same thing itself. The protocol details below follow the reverse-engineering write-up of
the [rustunes](https://github.com/fbiba/rustunes) project (MIT licensed).

A sync session:

1. Copy `iTunes_Control/iTunes/MediaLibrary.sqlitedb` (+ `-wal`) off the phone over AFC and read it
   locally: the Media anchor, the database and primary-playlist IDs, existing songs (to skip
   duplicates), album/artist IDs (so new songs join existing albums) and used artwork IDs.
2. Open `com.apple.atc`, send `Ping`, wait for `SyncAllowed`, send `RequestingSync` with the
   library identity from `iTunesPrefs` and a fixed Grappa request.
3. The phone answers `ReadyForSync` with a Grappa blob. Derive the signing key from it.
4. Write the operation file `iTunes_Control/Sync/Media/Sync_00000000.plist` (`update_db_info` +
   one `insert_track` per song) and its signature `Sync_00000000.plist.cig`, then send
   `FinishedSyncingMetadata`.
5. The phone replies with an `AssetManifest` naming the audio (and artwork) it wants. Upload each
   cover to `Airlock/Media/Artwork/<id>` and each audio file to `Airlock/Media/<id>.<ext>`, rename
   it to `Airlock/Media/<id>`, and send `FileComplete` with its permanent path
   (`iTunes_Control/Music/Fnn/XXXX.ext`). The phone moves the file into place.
6. Wait for `SyncFinished`, then re-read the database to confirm every song landed.

## Which Apple frameworks iSync uses, and why not more

Investigated before writing the sync layer (macOS 26, Xcode 27):

| Approach | Result |
| --- | --- |
| **Finder's own engine**: `AMPDevicesAgent` via `AMPDevicesClient` (AMPDevices.framework, XPC service `com.apple.amp.devicesd`). Has `canAcceptFiles:forDevice:`, `copyFiles:toDevice:withReply:`, sync progress and completion callbacks — exactly "drag files onto the iPhone". | **Not usable.** The agent requires the private entitlement `com.apple.amp.devices.client` (Finder has it) and rejects every other client: its log shows `entitlement test failed` and the connection is cancelled. Third-party apps can't hold Apple-private entitlements without disabling system security. |
| **AirTrafficHost.framework** (`ATHostConnectionCreateWithLibrary`, `…SendSyncRequest`, `…SendMetadataSyncFinished`, `…SendAssetCompleted`, `…ReadMessage`). Loads in-process, no entitlement needed. | **Not usable for Music.** `ATHostConnectionSendSyncRequest(conn, dataclasses, anchors, hostInfo)` always replaces `HostInfo.Grappa` with Apple's per-session request (obfuscated routine inside the framework). iOS verifies the `.cig` signature of every operation file and fails the sync otherwise, and the matching signer is not exported from any library in the shared cache (it lives inside the `AMPDevicesAgent` executable). Using the framework only for framing would bypass its session/Grappa bookkeeping and gain nothing. |
| **MobileDevice.framework** (also private, also what Finder uses): device discovery, pairing, lockdown sessions, TLS service connections **and Apple's AFC file client** (`AFCConnectionCreate`, `AFCFileRefOpen/Read/Write`, `AFCDirectory*`, `AFCRenamePath`, …). | **Used.** No entitlement needed. Verified read-only against a real iPhone (iOS 27.2) over Wi-Fi. |

So iSync implements only what no framework offers: the ATC message exchange (a small framing
layer over MobileDevice's service connection), the Grappa signature (public calculation built on
CommonCrypto), the operation file, and reading the phone's library database (SQLite).

## Conversion

FFmpeg decodes every format. Lossless sources (FLAC, WAV, AIFF, APE, WavPack, DSD, …) become ALAC
in M4A; MP3, AAC and ALAC M4A files are already playable and are sent untouched; other lossy formats
(Ogg Vorbis, Opus, WMA, …) become 256 kbps AAC. FFmpeg's MP4 muxer drops tags it doesn't know, so
iSync writes `moov/udta/meta/ilst` itself: all standard iTunes atoms, a freeform atom for every
other tag and every embedded picture (front cover first).
