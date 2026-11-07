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
limitations remain beside the relevant choices; the collapsed **About Downloads**
section retains provider, audio/subtitle, Live Activity, and batch-notification help.
