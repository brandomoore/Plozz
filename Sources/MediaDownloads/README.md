# MediaDownloads

The profile-scoped download registry owns saved media, resumable transfer state,
and pinned metadata. `RegistryOfflinePlaybackResolver` resolves completed local
files for playback without contacting the source server.

## Downloaded-only browsing

### Rollout and rollback

`RuntimeFeatureFlag.offlineMode` is enabled in
`Sources/CoreModels/RuntimeFeatureFlags.swift`'s `productionDefault`, shared by
Debug and Release. To disable the feature in a subsequent build, remove
`.offlineMode` from that enabled set. This is a build-controlled flag, not a
remote kill switch.

A disabled build ignores a saved Offline Mode preference before constructing
providers or starting network work, hides the picker/settings entry points and
status notice, and excludes Offline Mode from settings search. It also disables
device-local Plex sign-in fallback on both platforms. Downloads, credentials,
local progress, and the saved preference are retained; existing Downloads
playback and ordinary online/LAN routing remain available. Reenabling the flag
restores the saved preference.

The initial rollout still has known gaps: offline library filter controls are
not exposed, reconstructed series lack full parent metadata, and a downloaded
series can disappear from Watchlist after profile/mode transitions. The
Discover/Live TV placeholder chrome and Search introduction also need follow-up.
These are not a completed verification of the full offline experience.

### Behavior

On iOS/iPadOS, explicit Offline Mode replaces the normal providers with
`OfflineMediaProvider`; it does not replace the app with a Downloads-only screen.
Home, libraries, search, watchlist, detail, and playback keep their ordinary
presentation and use the local provider contract. Online-only destinations are
unavailable until the mode is turned off. This preference belongs to the device,
not the synced profile.

Only completed files that still exist and belong to the authorized profile and
server user enter the catalog. Series and season containers are reconstructed
from their downloaded episodes; absent episodes and non-downloaded versions are
not advertised. Artwork and subtitle references must be local. No online provider
is used as a fallback, even when the local catalog is empty.

Downloads pin both landscape artwork and a separate movie/series poster in their
own folder. Home, Watchlist, search, and detail reuse those local files; episodes
retain their landscape image while portrait cards use the owning show's poster.
Any authorized downloaded episode or version can supply a missing parent poster.
Existing downloads repair missing or damaged images when Plozz is active, online,
and the download network policy permits it. Offline Mode never fetches artwork;
previously unsaved posters need an allowed online opportunity before going offline.
Artwork repair and quality replacement preserve downloaded media and both image
roles across registry reloads.

`PinnedMediaSnapshot.sourceUserID` captures the source identity when downloading.
Older snapshots must first be revalidated against the currently authorized
provider online; they are not silently attributed to a different server user.
The source identity, profile, account selection, and mode generation are checked
again after asynchronous work. Metadata repair preserves pinned artwork and is
separate from download transfer state. This small, authenticated metadata lookup
can run on cellular even when media and artwork downloads are Wi-Fi-only.

Playback progress updates the local snapshot. Watch mutations remain in the
existing durable outbox and are delivered through its ordinary identity checks
after normal operation resumes; offline completion is not a server acknowledgement.
Entering the mode pauses transfers, cloud synchronization, scanning, and HTTP
work. An internet outage alone does not select this mode: a reachable LAN server
can still be browsed with a previously authenticated identity.

Offline Mode is available from the profile picker's More menu and from
Settings → Downloads. A missing network path displays a separate status without
enabling downloaded-only browsing; a connected path does not prove that the
internet or a particular server is reachable. The dismissible status uses the
same adaptive placement as guide progress, yielding to guide and action messages.
Dismissal persists across pages until the mode or connectivity episode changes;
it never disables the mode.

Download settings use short control labels. Background-speed and converted-quality
limitations remain beside the relevant choices, without an About Downloads section.
Download selection shows quality-specific track guidance and automatic text-subtitle
saving before confirmation; Original-only sources identify that restriction there,
not in global settings. Automatic downloads still honor Ask Each Time being off.
The notification toggle is labeled **Season or Show Complete**. Active system download
Live Activities include **Cancel to pause** beside their progress, since the system's
Cancel action pauses rather than deletes downloads.

## Download quality and tracks

Track inclusion is automatic, not a universal pair of settings. Original saves
the existing file unchanged, retaining its embedded audio and subtitle tracks.
New reduced Plex, Emby and Silo downloads retain all reported audio tracks
automatically. Playback applies the existing preferred-language policy to the
local tracks, without changing the server's saved soundtrack selection.

Plex prepares one H.264/AAC MP4 through its native download queue. Its offline
client profile enables `DirectPlayStreamSelection`; no individual audio selection
is sent and no extra video conversion or original-file transfer is needed.
Before completion, Plozz checks the actual languages, audio count, requested
resolution and end-of-file samples. Older single-audio requests retain their
existing behavior on retry; already saved files are not changed.

Emby converts video once to H.264
MP4 and each additional soundtrack separately to stereo AAC at 192 kbps. Native
AVFoundation packaging copies those compressed samples into one MP4 with mutually
exclusive audio choices; it does not encode the video again. This needs temporary
space for the downloaded inputs and the finished file.

Reduced Silo downloads require a native artifact whose audio inventory matches
the exact catalog file. Missing, incomplete or changed inventories fail rather
than silently dropping languages; the downloaded file's audio count is checked
along with its languages, resolution and end samples. Server-advertised quality presets still determine whether reduced downloads
are available. Original-only Silo servers are not treated as conversion-capable.

Jellyfin's tested audio-only endpoint ignores the requested index, so Jellyfin
retains its existing HLS behavior and may include only one audio track. Use
Original to retain every embedded track on Jellyfin. Network shares remain Original-only.
Existing reduced Emby downloads retain their original HLS behavior on retry.
Silent Emby videos also retain that transport rather than requiring an audio package.

`OfflineAudioDownload` persists credential-free source fingerprints, track plans
and completed-artifact receipts. A failed extra soundtrack does not re-download
completed video. Source changes fail closed, each artifact is checked for its
expected streams and complete duration, authorization is rechecked across
asynchronous work, and the final MP4 is published atomically. Per-track server
preparation references survive retries. Packaging preserves compressed content;
it is not a full-original download fallback.

External text subtitles are saved beside new downloads, for both Original and reduced
quality. Plex and Jellyfin/Emby discovery uses the exact downloaded media source, not
the first version of the title, and never starts another playback/transcode session.
Network shares save exact-stem sidecars from the video's folder or its Subs/Subtitles
folder. Silo retains its native download manifest, permissions, and asset endpoint.
SRT, WebVTT, ASS, and SSA delivery is supported; image subtitles and unavailable or
unreadable files are not advertised as saved. Jellyfin/Emby retain their existing
subtitle delivery format (SRT for SubRip, WebVTT for other text formats).

A video is marked complete before optional subtitle saving starts, so cancelling
that work cannot hide it offline or restart the video transfer. An interrupted initial
save can be retried with **Update Subtitles**, including after restarting the app.
A subtitle failure does not invalidate a successfully downloaded video. Warnings
persist until the authorized profile is foregrounded and the existing in-app toast
is free; delivered warnings are acknowledged individually, without replacing an
active toast. **Retry Subtitles** in the movie/episode download
menu retries only sidecars. **Update Subtitles** also allows older downloads to acquire
sidecars without downloading the video again. There is no automatic legacy backfill.
These operations respect profile/server-user authorization, Offline Mode and download
network policy. The shared loader saves successful tracks even if another file fails.
Provider discovery or native Silo asset-batch failures retain the previous saved set,
as do incomplete refreshes. Language, title, forced and hearing-impaired
metadata persist with the local files, never token-bearing URLs. Removal and quality
replacement use the video's existing folder lifecycle. Downloads cap each subtitle at
16 MiB and the saved set (including retained files) at 64 MiB/64 tracks, and validate
playable text before publishing. Retrying repairs malformed indexes; cancelled or
backgrounded subtitle updates leave the completed video and its previous status intact.
Cancelling or expiring a Live Activity also cancels its tracked subtitle work without
changing completed videos back to paused. Normal activity completion keeps its
background execution grant until the tracked downloads' subtitle saving finishes,
including the last video and downloads added while completion is pending. This waits
for the actual work, not a fixed delay; subtitle failures remain nonfatal.

The request builder opts new reduced Plex, Emby and Silo downloads into all-audio
delivery; `ManagedHTTPDownloadSource` keeps its legacy decoding defaults.
Available text subtitles remain enabled. The retired global track flags are ignored
when decoding `DownloadNetworkPolicy`; they cannot invisibly block new Plex/Silo
downloads or disable subtitles. Existing per-download flags remain decodable and
are preserved when retrying, including explicit unsupported-track errors. Saved
files are not rewritten. There is no full-original fallback for reduced quality,
custom server requirement, or dependency upgrade. Progressive Emby packages use
the existing HTTP speed limit; Jellyfin and legacy Emby HLS still require Full Speed.
