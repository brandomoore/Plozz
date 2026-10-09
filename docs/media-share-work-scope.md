# Profile-scoped media-share work

## Policy

Catalog storage is shared between profiles; automatic work is not device-wide.
An automatic directory scan, local sidecar/artwork pass, or external metadata
request may run only for a media-share account included in the active profile
with an enabled indexed library. Before profile admission, automatic work is
closed. Home row preferences, merge settings, and navigation layout do not
change this policy.

An explicitly configured Movies or TV root uses its stable library toggle.
Legacy automatic roots share one physical catalog across Movies, TV Shows, and
Anime: any enabled category can require a directory walk of that root. Disabling
one category cannot prevent discovering the other categories in an intermixed
directory tree. Disabling the source, or all its indexed categories, pauses its
automatic work. Raw-file browsing alone and Personal Videos do not require an
automatic media catalog scan.

## Ownership and propagation

Both platform shells use the same observation-driven scope controller. It reads
profile admission, active account membership, and the current profile's library
visibility model, including replacement of that model during profile changes.
Each changed snapshot has a monotonically increasing revision.

The runtime forwards the scope to the catalog coordinator. Production starts
with an empty scope, so first-use catalog registration cannot outrun profile
selection. Coordinator and scheduler reject stale revisions and recheck
eligibility after asynchronous admission boundaries. Preferred-account ordering
remains a fairness/cache priority, never permission to run an excluded source.

## Pausing and resuming

Disabling a source cancels its automatic scanner and metadata work. Its exact
transport generation drains under the existing lifecycle owner, without
blocking unrelated enabled sources. No replacement work overlaps a draining
generation. The scanner's cancellation/checkpoint path preserves its frontier;
metadata queues and retry budgets remain durable. Pausing must not prune the
catalog, erase artwork, mark an interrupted scan complete, or keep a worker
polling when all queued work is ineligible.

Re-enabling a source resumes eligible registered work, respecting existing
scan throttles, playback admission, and foreground-only operation. Cached
catalog reads remain available without authorizing scans. Status distinguishes
paused execution from a completed scan, preserving the last completed date.

Artwork reference context uses a persisted account/credential-revision marker.
Unchanged catalogue access, including after relaunch, checks that marker without
enumerating artwork or starting a write transaction. A changed context backfills
legacy artwork IDs and rebuilds references before committing the marker; new
artwork gets its ID on upsert.

When a clean scan needs reconciliation, filename-ID projection resolves movie
representatives in one grouped catalog query rather than one lookup per movie.
The earliest member still owns the group projection even when only another
member has explicit IDs; conflicting IDs remain omitted.

## Explicit work

`Scan now` authorizes the requested scan and its ensuing metadata pass, even
when the source is disabled for the active profile. The explicit intent travels
with that work through queueing and suspension; it is not an account-wide
override and cannot leak into later automatic polls. Explicit item refresh
similarly authorizes only that item. These user-requested actions still obey
foreground, playback, credential, and account-removal fences.

## Verification

Cover disabled-source registration and polling, source/library toggles,
profile changes, startup admission, stale revisions, cancellation-insensitive
I/O, cached reads, resume, one-off work on excluded sources, and the absence of
idle polling. Preserve existing playback, foreground suspension, scan
checkpoint, metadata retry, and cross-account serialization coverage.
