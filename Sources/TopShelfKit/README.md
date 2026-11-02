# TopShelfKit

Publishes the tvOS **Top Shelf** snapshot (poster rows or full-screen artwork on
the Apple TV Home Screen) from the app's domain models into the shared App Group
container, where the Top Shelf extension reads it.

## Responsibility

- `TopShelfSnapshot` — the on-disk Codable snapshot shape (sections,
  display titles, item ids, artwork URLs and optional full-screen metadata).
  The **extension** compiles this type, `TopShelfStore` and
  `TopShelfContentBuilder` directly, keeping `CoreModels` out of its memory budget.
- `TopShelfStore` — read/write helper around the shared App Group
  container. Used by both the app (to write) and the extension (to read).
- `TopShelfContentBuilder` — native sectioned/carousel content mapping, shared
  by the extension and its package tests without the app's model stack.
- `TopShelfPublisher` — app-side mapping from `[MediaItem]`
  Continue-Watching + Latest rows onto a `TopShelfSnapshot`, with empty-row
  pruning. Always writes (even empty) so a freshly-signed-out state clears
  the shelf.

Top Shelf preferences are device-local and shared by Plozz profiles. Settings →
Everyone → Top Shelf explains the Apple TV Home Screen placement, offers a
default-on **Show Top Shelf** switch with its explanation beneath the label, and
exposes independent Continue Watching and Recently Added
counts, each defaulting to 4 with a 1–20 range. The app applies the limits before
resolving artwork, without changing provider order, content identity, library
visibility, or the active profile's artwork policy. Editing either count
republishes current Home content, cancels superseded artwork work, and notifies
tvOS after a successful snapshot write. Short feeds are not padded.
Turning Top Shelf off writes an empty snapshot immediately, including without a
loaded Home model, and hides layout/count controls without erasing their values.
Publication commits and settings changes are serialized on the main actor;
generation checks reject suspended artwork from before a settings change or a
newer publication, including a quick off/on cycle. Disabled publication does not
resolve artwork. The extension returns no media for the empty snapshot.

Artwork selection remains on the main actor, but `TopShelfArtworkEncoder`
serializes PNG poster and JPEG backdrop compression on its own actor so an
export cannot block Home navigation. Cancellation skips queued compression and
discards a result cancelled during encoding; publication generation checks still
reject superseded work. The encoder retains no images or credentialed URLs.

**Posters** remains the default. **Full Screen** publishes the same limited feeds
as a native `TVTopShelfCarouselContent` with `.details`: Continue Watching first,
then Recently Added, deduplicated by account-qualified identity. tvOS owns the
Home Screen presentation and swipe-up expansion; Plozz does not force fullscreen.
The carousel exposes **Play** using the existing account-scoped route and
**More Info** using `action=details`, which opens the existing title/series page
without starting playback. Poster selection keeps its existing Play behavior.
Both actions wait for app admission and resolve only the named active account;
only legacy accountless links search across active accounts. A newer request or
cancelled identity scope cannot consume an older async result. Failures surface
through the app's normal error copy. No video autoplay is added.

Full Screen exports the synopsis, up to three genres, known release date, full
runtime, and supported native format badges (HD/4K, HDR/Dolby Vision, Atmos,
closed captions and SDH when reported). A production year without a release
date stays in the context line rather than inventing a calendar date. Episode
headlines include the series name and retain season/episode numbering.
tvOS allows four named attributes: available remaining time, content rating,
cast and directors take priority, then studio and ratings fill unused slots.
Unknown fields are omitted; surround channels alone do not imply Atmos, and
badges never combine unrelated versions. Remaining time uses current Home watch
state while native duration remains the total runtime.

The app fetches provider detail only for the limited full-screen selection,
once per account-qualified item per publication. Poster and disabled modes do
not add metadata requests. These optional fetches use active providers, do not
fetch playback URLs, and log failures before retaining known Home metadata.
Cancellation discards the publication. The extension still does no provider I/O.

Full-screen art uses the active profile's Top Shelf artwork policy and bounded
hero resolution. Episodes resolve series artwork, not episode stills. The app
writes 1920x1080 JPEGs; portrait fallbacks are fitted without cropping and missing
art gets a neutral background. Episode titles, summaries and guest cast respect
spoiler protection. Protected summaries show only the series name and season/episode
number instead of leaving the native full-screen text area blank; missing
identifiers fall back to the safe episode label, never the
real episode title or synopsis. Ratings also honor the independent hide-until-watched
preference, using Home watch state rather than provider detail state.
Only the selected style's artwork is resolved. Preview cards in
Settings are schematic illustrations, never a second copy of profile media.
Old settings and snapshots without a layout flag keep their poster presentation.

## Invariants

- **App Group container is the only side-channel.** No network, no
  keychain.
- **No secrets in the snapshot.** Item ids and artwork URLs only — tokens
  for token-protected art are scoped to a refresh strategy outside this
  module.
- **`CoreModels` only imported by the app, not the extension.** The snapshot
  and store stay independent of domain models and UI; the store uses OSLog
  only to report write failures.
- **Idempotent.** Republishing the same snapshot is cheap and side-effect
  free.

## Where to look first

- `TopShelfPublisher.swift` — domain → snapshot mapping.
- `TopShelfSnapshot.swift` — on-disk shape.
- `TopShelfStore.swift` — shared-container I/O.
- `TopShelfContentBuilder.swift` — native poster/carousel mapping, compiled directly
  into the extension and exercised by package tests.
- `TopShelfBackdropComposer.swift` — bounded full-screen artwork export.
