# CoreModels

The Foundation-only, **zero-dependency** core of Plozz. Defines the domain
language every other module speaks.

## Reviewed tracker export

`TrackerHistoryExportSession` reads one explicitly selected server-user/library
through `TrackerServerHistorySource`, then requires selection and confirmation
for 1–50 watched titles. Adapters own exact canonical targets, complete reads,
historical/status writes and target-specific readback. Full reads are capped at
100,000 observations and indexed by identity before conservative matching;
the existing server inventory retains its 50,000-item bound. No title search,
server writes, playback reports, play-count reconstruction or ongoing enrollment
occurs. Existing tracker watches and conflicting progress are not selectable.

`TrackerHistoryListState` retains planning, watching, waiting, paused, dropped
and completed list membership without fabricating a watch, episode count or
resume position. Even a completed list state cannot authorize a server change.
Export comparisons protect matching list entries and episodes whose exactly
matched parent series is planned, paused or dropped. Derived parent states
(watching, waiting and completed) do not prevent copying other missing episodes.
A series list observation may carry a nonnegative season to protect only that
season's episodes. Season-scoped watches/counts remain invalid; list membership
does not fabricate completed-season history.
Parent matching requires explicit `Series*` IDs, rejects
contradictory namespaces, and never uses titles or ordinary inherited episode IDs.
Other series observations, including aggregate counts, do not become episode
history or parent-list protections.

All selected rows are preflighted before dispatch. Source scope, playback and
baseline plus remote evidence are checked again for each write and within the
adapter's immediate pre-dispatch authorization callback. Durable, profile/
connection/canonical-target receipts are saved after the final asynchronous
checks and before dispatch, with another receipt check at that boundary.
Cancellation or stale evidence before authorization does not create a delivery
hold; a competing session's receipt is never overwritten or removed. Any prior
attempt blocks replay, including a confirmed watch subsequently removed remotely. Only a proven
non-delivery may remove its receipt. An uncertain response requires independent
readback; presence alone does not establish who wrote it or preserve a date.
Readback failure retains the receipt and stops the batch. These are optimistic
checks, not an atomic transaction with either remote service.

## Responsibility

- Domain value types: `MediaItem`, `MediaLibrary`, `MediaServer`,
  `UserSession`, `Account`, `Profile`, `MusicTrack`, `Person`, etc.
- The dual-provider abstraction: `MediaProvider` protocol, `ProviderKind`,
  `ProviderRegistry` / `ProviderResolving`, `ResolvedAccount`.
- Cross-cutting UI state: `LoadState`, `AppError`.
- `PlaybackReadAhead` and `LivePlaybackBuffer` are independent device-local
  network/storage preferences, not profile settings. Both default to Automatic
  and are excluded from profile transfer. `EngineSessionCache` carries active
  temporary-cache usage and the engine's effective playback-safe budget.
- `PlaybackDiagnosticReport` supplies privacy-safe failure Details for on-demand
  playback, Live TV and IPTV setup. Preserve typed reasons and numeric causes,
  distinguish preparation/opening/playback, and never export raw error text.
  Non-video live responses use fixed HTML/JSON/XML/empty classifications and
  factual messages, not response snippets or inferred credential expiry.
- `PlaybackDiagnosticJournal` retains up to 256 events / 128 KiB for 48 hours.
  Optional typed quality, stage and native evidence fields preserve older
  journals; validation applies both on admission and disk restore. The explicit
  Send diagnostics action includes this local journal, without enabling
  automatic on-demand failure uploads or claiming confirmed backend delivery.
- Shared decode/encode helpers: `JSONDecoder.plozz`, `JSONEncoder.plozz`.
- `HTTPDate` shares HTTP timestamp parsing/formatting and strict `Retry-After`
  interpretation across HTTP media transports and IPTV. Consumers convert
  finite retry delays to monotonic deadlines; malformed headers remain unknown,
  not permission to retry immediately.
- Subtitle behaviour + appearance model: `SubtitleBehavior`, `SubtitleStyle`,
  plus the neutral `SubtitleColor` / `SubtitleEdgeStyle` / `SubtitleMode` primitives.
- Profiles persistence contract: `ProfilePersisting`, `ProfileStore`,
  `ProfilesModel`, plus the Plex Home-user mapping (`PlexHomeUser`).
- Local PIN proof is in-memory and bound to the current verifier and selection.
  `ProfilesModel` clears it whenever the active profile changes, including
  deletion/sync fallbacks. Manual entry to another locked profile requires fresh
  proof; opting into startup sign-in remains a separate, startup-only exception.
  Profile Lock verification keeps its full stored derivation cost off the UI
  executor; callers must recheck request, selection generation and lock afterward.
- `EpisodeCountBadgeStyle` is an independent, profile-scoped appearance preference.
  On first load, `WatchStatusIndicatorSettingsStore` preserves the legacy
  watch-mode-derived style (watched: floating, unwatched: attached), then persists
  it independently. It transfers with profile settings; watch marks do not follow it.

## Invariants

- **No SwiftUI / AVKit / UIKit imports.** This module compiles on Linux so
  pure-logic tests can run there. UI lives in `CoreUI` and feature modules.
- **Never hold secrets.** Tokens are owned by `FeatureAuth` (Keychain). Types
  here (e.g. `Account`, `Profile`) carry only non-secret metadata.
- **Provider-agnostic.** No type here may assume Jellyfin- or Plex-specific
  behavior; the only provider seam is `MediaProvider`.
- **Collections are server-defined groups, not alternate title sources.**
  Collection identity stays scoped to the owning account and item ID, even when
  two groups share a catalogue collection ID or physical server. Library
  collection discovery uses `collections(in:page:)`, advertised through
  `.libraryCollections`. Servers may return a library-filtered list or all groups
  visible to the authenticated user; the library argument does not authorize
  client-side membership reconstruction. `collectionMembers(of:page:)`
  is separate and preserves server membership/order rather than the grid's sort.
  `collections(in:page:progress:)` optionally reports incomplete discovery: its
  confirmed items are an append-only prefix of the complete ordering, while
  `checked`/`total` count candidate checks, not the final collection count.
  The ordinary page return remains authoritative. Providers without intermediate
  discovery (including the aggregate merge) retain their existing page contract.
  `MediaLibrary.isServerCollectionDirectory` identifies a synthesized server-wide
  Collections navigation entry. Keep it in library selection and navigation with
  normal account/profile identity, but not in playable-library feeds or per-library
  Home rows. Its provider owns routing; its synthetic ID is never a server parent.
  Collection directories carry optional `hasCollections` availability. The
  content-aware Home visibility predicate hides confirmed-empty tiles by default,
  while profile-scoped explicit enable choices override that automatic hiding.
  Unknown availability is not emptiness; discovery and browse retain the entry.
  `CollectionSection` separates an authored row's stable identity, source, name
  and card presentation from placement. Home stores these definitions in its
  existing profile-scoped settings, outside the preset/order selection.
  `CollectionPreviewLoader` shares bounded membership paging with Hero, validates
  page progress and identity, and never treats a selected library as inferred
  membership for returned titles.

## Public surface, at a glance

`RuntimeFeatureFlags.buildDefault` is the shared application rollout selection.
Debug and Release builds share `productionDefault`, with WeTrakr enabled,
including TestFlight and App Store builds.

The watch-mutation outbox retains WeTrakr completion keys and applied results
per viewing session. The existing live-session origin/server-user guard supplies
the boundary shared by checkpoints and final stop, while retries retain the
first completion timestamp. Ending that session allows a new rewatch key; there
is no day-wide WeTrakr suppression. Older outboxes without these fields remain
readable and retain their original retry-key derivation.

Failed server targets in the watch outbox have independent persisted retry
deadlines: 30 seconds initially, doubling to a 15-minute maximum, or longer when
the server explicitly requests it. Existing drain triggers retry once the deadline
passes; no polling timer is added. Coalescing preserves the cooldown while keeping
the latest desired state, and relaunching cannot reset it. Successful destinations
and tracker mirrors are not held behind a failed server. Cancellation is not a
server failure, and authorization is still checked before any retry. Legacy
outboxes without retry metadata remain readable and immediately eligible.

| Concept | Entry point |
| --- | --- |
| Provider abstraction | `MediaProvider`, `ProviderKind`, `ProviderRegistry` |
| Domain models | `MediaItem`, `MediaLibrary`, `MediaServer`, `UserSession` |
| Multi-account | `Account`, `ResolvedAccount`, `AggregatedLibrary` |
| Profiles | `Profile`, `ProfileStore`, `ProfilesModel`, `PlexHomeUser` |
| UI state | `LoadState`, `AppError` |
| Subtitles | `SubtitleBehavior`, `SubtitleStyle` (rendered by `FeaturePlayback`) |

## Content-rating presentation

`ContentRatingPresentation` shortens known classification descriptions, not ages.
Country prefixes identify the rating system independently of the app's language.
Existing codes, native scripts, meaningful slashes (India's `U/A`, Portugal's
`M/12`, Belgium's `AL/TOUS`), and unrecognized qualifiers remain intact.
French `avec avertissement` is an additional warning: show `TP` or the age
restriction with a warning indicator, never silently drop it or invent a US rating.
`MediaItem.officialRating` and the badge's accessibility text retain the original.
Unknown descriptions remain provider content; presentation bounds their width.

References used for display aliases:
[CNC classification and warnings](https://www.cnc.fr/cinema/actualites/proteger-sans-censurer--la-classification-des-oeuvres-cinematographiques_1924881),
[FSK age labels](https://www.fsk.de/altersstufen/),
[regional classification overview](https://en.wikipedia.org/wiki/Motion_picture_content_rating_system),
and [Jellyfin's regional input tokens](https://github.com/jellyfin/jellyfin/tree/master/Emby.Server.Implementations/Localization/Ratings).
Jellyfin's numeric parental-control scores are **not** display equivalences;
for example, exemptions, warning qualifiers, and age-restricted classifications
must not collapse just because they share a score. This is not a complete registry
of every custom classification a media server can supply.

`ContentRatingSettingsModel` owns one default-on, profile-scoped visibility
preference. It transfers between devices and is rebuilt on profile switches.
It changes presentation only, never parental authorization, catalog filtering,
review scores, or Common Sense Media recommendations.

## Home section editing

`HomeSectionCatalog` adapts the existing `HomeRowChoice` inventory into section
editing without creating a second identity or storage format. Global, native
server, and library row IDs remain account/library qualified; provider-authored
titles are display content, never identifiers. `LibraryHomeRowKind.available`
and `MediaProvider` retain Jellyfin, Emby, Plex, Silo and share capability
differences. Live TV remains its existing typed channel-shortcut section,
with tuning and authorization owned by the Live TV runtime.

Add/remove/reorder validate against the current editable catalog, then use
`HomeLibraryVisibility.applyRows`. This preserves unavailable IDs, merged-away
Next Up rows and their saved positions. Remove means hidden, not deleted;
re-adding appends the section and retains its other settings. No-op actions
do not turn a preset into a custom arrangement. Writes use the existing
profile-scoped store and never mutate whole-library availability.

Next Up merges into Continue Watching by default for every preset and for stored
settings without a merge preference. An explicit opt-out remains profile-scoped
and survives preset changes and reloads. Merging preserves separate rows' saved
order and visibility; hiding Continue Watching suspends the merge.

`HomeSectionCatalogModel` discovers native layout metadata and optional
recommendations with at most three concurrent catalog requests. Accounts,
credential revisions, effective server/Plex viewers, enabled libraries and the
profile model fence publications. Same-scope failures retain known choices
and expose typed errors; cancellation and stale tasks cannot publish into a
newer catalog. There is no timer, full-feed loader, playback resolution or
new provider-specific API in the editor.
`currentCatalog` supplies authorized local choices before discovery and rejects
retained results from another identity. Known sections remain editable during a
refresh; discovering additional choices does not gate all existing controls.

The root (including its inline preset selector), section and Add section pages
participate in the same identity- and preset-keyed load. Concurrent pages share its work; leaving the
last consumer cancels it. A pushed page can restart a cancelled load, and preset
selections refresh both resolved native sections and discovery errors; freezing
a preset during a row edit does not restart discovery. Library metadata changes
also invalidate the catalog even when account/library keys remain stable. Section
add/remove mutations wait for discovery. Reordering instead uses the editor's
snapshot of known sections, allowing local moves while a server is slow or offline.
Only an actual move customizes that snapshot; late discoveries remain available
to add rather than changing the rows being moved.

Hero stays in `HeroSettings`, fixed above `HomePresentationRow`; Showcase remains
a page layout. Future custom source scopes, mixed feeds, duplicate instances,
curated sections and new appearances need explicit configuration and capability
contracts before they can become templates in this editor. Do not overload an
existing `HomeRowID` to represent independent instances or change provider IDs
to make them unique in the UI.

## Profile deletion and namespace ownership

Transferable preferences use byte-stable sync values. JSON object keys and
Hero's set-valued `randomLibraryKeys` are canonicalized on capture and apply,
including legacy blobs. User-ordered arrays such as Hero sources and unknown
fields retain their meaning; native preferred-version dictionaries stay
dictionaries rather than becoming JSON data.

Any profile may be deleted while at least one remains. Both cloud adapters apply
the original/default profile's deletion and omit deleted profiles, membership and
settings from capture, allowing the existing durable sync ledger to delete their
CloudKit records. A deletion arriving before the remaining profile records holds
a persisted, non-publishing placeholder until a replacement arrives or is added;
`profilesForSync` excludes it so a restart cannot recreate the deleted record.
Live TV and media-state captures also exclude `pendingSyncedDeletionProfileIDs`,
including preserved fallback records, without erasing the temporary local data.
The revisioned household Parental PIN moves to the first surviving profile rather
than disappearing with its former anchor.

Legacy unnamespaced settings have a recorded owner. Retain that former owner's
stored ID after deletion, even though the live `rootNamespaceOwnerID` is nil.
Erasing this marker reruns migration on launch and hands the deleted profile's
settings and Live TV source storage to another profile. Survivor namespaces never
change because the roster is reordered or its first entry is deleted.

The shared CloudKit inventory repair also heals deletions missed by an older
incremental cursor. Inventory absence alone never authorizes removal: only an
explicit per-record `unknownItem` can remove an unchanged, previously synced
entry. New uploads, dirty edits, pending local deletions, and changes made during
verification are retained. Repair is fenced by engine, iCloud account, and
channel authority; it uses the normal persisted ledger and profile apply path.
Startup and foreground checks are throttled only after a complete repair, while
manual Sync Now checks the inventory without that throttle.

## Version picker facts

`MediaVersion.PickerPresentation` is the shared detail/player summary on TV and
mobile: edition/quality/size, video format, available audio languages, primary
audio codec/profile/layout, bitrate, runtime, and a separate release filename.
Language names use the caller's effective locale. Provider metadata stays scoped
to that physical file; subtitle languages never become audio languages. Unknown
facts remain absent, and these source facts do not claim a playback mode or
active output format. Optional `MediaSourceMetadata.audioLanguages` keeps older
cached payloads readable and also survives synthesized edition versions.
The playback-choice dialog reuses the detail page's per-version badges, adding
video-codec, full audio-format and localized audio-language chips. Both the hero
and picker keep the underlying codec alongside spatial audio (for example,
Dolby TrueHD and Dolby Atmos), attaching reported source-channel counts to the
codec rather than implying an Atmos height-speaker layout. Picture badges,
including the picker's video codec, precede audio formats and languages.
Language badges belong to the audio family rather than generic technical specs.
Series summaries select the audio facts from one source, never
joining another file's channel count to the winning codec. Companion text omits those badge
facts, retaining edition/source quality, size, bit depth and bitrate/runtime.
The smaller badges sit below the release filename and wrap for narrow widths
and Dynamic Type. The dialog uses native rounded rectangle buttons rather than
capsules. Every version picker shares `CoreUI.MediaVersionChoiceButton`.
Audio-language chips list reported languages, not an assertion that no other
languages exist. Providers can supplement stream language codes with explicitly
named source-description languages via `MediaSourceDisplayName.declaredAudioLanguages`.
It accepts dedicated globe-marked or Audio/Languages fields and the bridge's
compact language-flag/size header, not filenames, subtitle fields or arbitrary
country flags. `Multi` is not a language and adds no count.
These display facts never create selectable tracks or change track preferences.
The compact row highlights a reported preferred language and counts the rest
(`English | +9` in one chip) without discarding the complete language inventory.
`MediaSourceDisplayName` extracts a readable `torrent_name` from URL/query-backed
sources (including percent-encoded names) before taking a basename. It also
cleans cached locator-like names at presentation time. Only the decoded name,
not unrelated query parameters, supplies release text or edition/quality hints;
playback locators and source IDs remain unchanged.
Multiline remote-source labels can identify their release file on a folder-marked
line, including continuation lines through the file extension; presentation
extracts that filename rather than displaying the entire provider description.
Original Unicode filenames are retained and the shared card wraps them without
a line cap. Extensionless URL endpoints are not release filenames,
so opaque stream paths cannot override a readable source name. Filename extraction
never manufactures audio-track language or other technical metadata.
The separate `declaredFileSizeBytes` extractor reads unambiguous, explicitly
byte-unit quantities from descriptions. Providers decide whether that declaration
is authoritative; bitrate units and filename/locator text never become byte sizes.

Playback version prompting and series memory are independent profile settings.
`versionSelectionMode` stays unanswered until first multi-version playback or a
Settings choice; `rememberVersionPerSeries` defaults on. Legacy `rememberChoice`
decodes as `automatic`. `VersionPreferenceStore` reads the live playback policy
from its own namespace, so all existing request/detail resolvers honor the toggle
without another unscoped preference. Automatic resolution never writes a memory.

## Artwork and profile presentation

`MediaItem.artworkReferences` supplies library artwork: server URLs and local
sidecars. Known external URLs stay on the item with their provenance, but are
offered separately by `metadataArtworkURLs`. `ArtworkRouter` considers these
cached candidates only at their enabled provider's current rank. Unattributed
legacy enrichment is not a library fallback. Local selections must not relabel
an external URL's provenance, and neither artwork preference nor provider order
changes playback identity or server authentication.

`seriesArtworkReferences` excludes episode stills and tries genuine series
sidecars before remote series fallbacks, including on landscape surfaces.
Online-first presentation remains the shared renderer's responsibility.

Multi-role consumers pair their library-reference ladder with
`ArtworkRouter.artworkURL(for:placements:)` (or the ordered `MediaArtworkSource`
initializer). Only an explicit `.episodeThumbnail` placement queries episode
stills; series-only surfaces retain `seriesArtworkReferences` and use
`[.detailBackdrop, .seriesPoster]` for external lookup. A missing backdrop can
therefore fall through to a source-qualified poster without bypassing provider
order or enablement.

Recognized physical folders carry an optional `ArtworkLookupSubject` from the
catalog. It supplies artwork query identity only: the folder's ID, kind, title,
provider route, and artwork-account ownership remain unchanged. Unqualified
folders never use title-based artwork lookup. Collage candidates retain their
items alongside library references, and collage caches include current
presentation/provider policy before reusing a composed image.

New profiles and existing profiles adopting card labels inherit App default:
ordinary browsing/Home labels are on, with Showcase and series-artwork exceptions.
The legacy default-off Home flag does not become a new override; a legacy opt-in
still does. Unversioned Home-only off configurations matching the old automatic
migration reset to App default, including its original boolean format. That
ambiguous shape cannot distinguish an old default from an old manual Home-only
choice. Explicit show/hide presets and other per-view customizations, including
Mixed choices, are preserved.
`homeDefaultVersion` travels in the label payload, so subsequent Home-only opt-outs
survive reload, profile switching, and transfer.

Synced artwork/label-setting deletions consume their one-time legacy import
even for profiles not yet loaded on this device. The separate `.migrated` store
markers remain device-local and never enter profile transfer snapshots.
Once migrated, loading these stores is read-only. Subtitle appearance model
hydration likewise does not save or broadcast its loaded values: profile
activation must not re-persist unchanged preferences on the main actor.

## Device-local playback buffering

`PlaybackReadAheadStore` keeps the on-demand buffering preference on the current
device, outside `PlaybackSettings` and `ProfileSettingsTransfer`. Profile changes,
sync and transfer must not overwrite this local storage/network choice.
Missing or invalid values use `PlaybackReadAhead.default` (Automatic); invalid
persisted values are logged without their contents.

## Season request status

Season request labels distinguish approved requests awaiting a known future
season premiere from Seerr's generic processing state. `SeasonRequestPresentation`
and per-season statuses share the calendar-day policy, independent of the release
badge. Pending approval, missing dates, release-day/past premieres, failures,
declines, library coverage, and download-queue evidence never claim that release
is the only remaining wait. Seerr's existing TV detail response supplies the
premiere date; this presentation needs no additional metadata requests.
TV and touch heroes use "S1 Requested · Unreleased" to keep the confirmation and
release state in one label. Mobile detail heroes move secondary actions into
the existing overflow menu before falling back to primary buttons above a
wrapping row of the secondary icons.
That stacked layout restores direct access to the icons, keeping a menu only
for source/version selection or file browsing; the status does not gain a subtitle.

## Watch-state replay identity

New shell watch intents carry `WatchMutationServerScope`: the originating Plozz
profile and stable account/server/user identities, including the existing Plex
Home binding. It contains no credentials or process-local token revisions.
Runtime validation must also confirm that the selected Plex viewer's credential
is actually installed before resolving its provider.

The reconciler uses the existing delivery-authorization checks before dispatch.
An unavailable server viewer defers the intact mutation without consuming its
retry budget; it can resume when that viewer returns, including after relaunch.
Server-user scope separates coalescing/clocks, live-session guards and UI replay.
It does not replace the separate, deliberately non-restorable authorization
requirement used for consent-gated library-channel completion.

Scoped mutations use a version-2 ID envelope so older readers reject them rather
than ignore an unfamiliar identity field. Removing or altering that requirement
also fails decoding. Legacy unscoped mutations remain readable under their
existing behavior. They are not retroactively stamped with the current
server-user scope: their historical viewer cannot be reconstructed.

## Where to look first

- `MediaProvider.swift` — the protocol that defines every backend.
- `ProviderRegistry.swift` — how features resolve a provider from a session.
- `AppError.swift` — the single error currency used everywhere.
