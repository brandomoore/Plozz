# Refresh and watch state

[Home task map](../../Sources/FeatureHome/README.md#where-to-look-first)

## Foreground and return refresh

Home and movie/series/episode detail register a visible surface with
`ContentRefreshCoordinator`. Platform timing and action choice live in
`ContentRefreshProfile`; views only perform the typed action they receive.

The top surface is the only one refreshed. Home refreshes silently when the
existing Continue Watching policy says it is stale. A series return re-fetches
the item, seasons, and server resume episode so the page can move to the current
season/episode; an explicit season choice is preserved. An episode return updates
only the loaded item's watch state — it does not reload children, change seasons,
or navigate. The parent series page refreshes when revealed after a long absence.
Home uses a 15-second return threshold; detail uses five minutes on both platforms.
First appearance does not duplicate loading. Failed series refreshes preserve the
previous context, and cancellation/source-generation checks reject late responses.
Each mounted page owns its registration, including repeated pushes of one title;
the modifier cancels refresh work when the page is hidden or the profile resets.
Single-source playback uses the current detail model's `playbackSources`, not
the opening card's watch state, so refreshed progress reaches the mobile Play
button even when no server picker is shown.

App activation is delivered by `ContentRefreshLifecycleReader` rather than a
view-local `scenePhase` check, so suspend/resume and a long-idle return to Home
use the same path. See [state management](../state-management.md).

`ContentRefreshReturnInteractionTests` runs the production movie and series
detail views in the TV and mobile test hosts. It changes fixture-provider data,
backgrounds/reactivates the app or pushes/pops another page, then checks the
rendered progress and episode Play target. Only the provider and absence
threshold are substituted; actual UIKit/SwiftUI lifecycle delivery is exercised.
`ContentRefreshSurfaceHostedTests` separately covers request cancellation on
cover, background, profile reset, identity change, and unmount on both platforms.
The deterministic coordinator suite owns the exact production timing boundaries.

`LiveContentRefreshInteractionTests` is a separate opt-in tvOS simulator smoke
test for Plex and Jellyfin. It mounts production Home/detail views with real
providers, backgrounds the host, changes the dedicated test user's history
through an independent client, and waits the production 15-second Home or
five-minute detail threshold before returning. It checks movie progress,
series Next Up, and Continue Watching; it does not play media or install on
physical devices.

The runner requires `PLOZZ_LIVE_REFRESH_BROKER`, a loopback-only broker base URL.
`GET /{provider}/configuration/{scope}` supplies the in-memory session and
selected item IDs; `POST /{provider}/prepare/{scope}` establishes the initial
state, and `POST /{provider}/advance/{scope}` changes it while the app is away.
Providers are `jellyfin` or `plex`; scopes are `movie`, `series`, or `home`.
Only explicitly authorized test identities may be used. Credentials must stay
out of launch arguments, result attachments, logs, and committed configuration.
Without that opt-in, the live tests skip rather than impersonating a passing
server check.

`HomeLoadingLayoutTests.testLiveJellyfinCompletedEpisodeRemainsOnHome` reuses
that broker's authorized Jellyfin series scope in the mobile hosted target.
It seeds a five-minute resume point, then completes that episode independently.
It checks the exact episode in the production provider feed, progress policy,
fresh Home models, and one retained Home model across a silent reload. The
completed episode must leave and its successor must enter without restarting
or changing profiles. Include Next Up off is an explicit negative control,
not evidence that a reporter has misconfigured the setting. No media is
decoded; only the dedicated internal user's disposable history is changed.

The investigation of [#170](https://github.com/brandomoore/Plozz/issues/170)
confirmed that the provider, aggregator, progress policy and Next Up preference
implementation are unchanged between `release/071.6` and `021f7972a`.
Subsequent lifecycle work changes refresh delivery, while the mobile library-row
optimization changes duplicate equality work, not Continue Watching membership.
Passing a controlled live-server case does not resolve a report about another
server, user, series, or device; the reporter's exact missing title still needs
to be traced through Resume, Next Up, curation and presentation.
The current-branch check passed on iPhone and iPad simulators (Xcode 27.2,
iOS 26.2), including retained-model advancement, both fresh-load phases and
the negative controls. Local evidence:
`live-home-rows-9d2fd88f9d834092a3337de45d1faf98`. This was not a run of the
71.6 binary and did not reproduce or fix the reported failure.

## Continue Watching watch actions

In-progress movies, episodes and videos offer both **Mark as Watched** and
**Mark as Unwatched** in the shared TV/mobile menu. Mark as Unwatched resets
completion and saved progress, as if the selected item had not been started.
Home removes its in-progress card immediately and retains that reset while the
account-scoped server writes are queued, including after relaunch.
Queued resets retain the server playback timestamps already observed when the
action was chosen, so a server clock ahead of the device cannot revive that same
resume point. Genuinely newer server playback still takes precedence.
Other episodes are not reset; the provider's Next Up feed remains authoritative.
Existing cross-server sync preferences apply. External tracker history is not deleted.

**Remove from Continue Watching** stays separate: it dismisses the title where
supported, or clears resume as a fallback, without changing its watched status.

## Detail watch-state updates

The shared `ItemDetailViewModel` applies account-scoped watch mutations to both
the displayed item and its separate source-picker records. Playing an SMB copy
must update a Plex-backed merged detail even when cross-server synchronization
is disabled, without changing the Plex copy's state. The next Play/Resume target
uses those same updated records rather than a stale pre-play position.

Local edits remain authoritative for the open page across delayed source
enrichment, snapshot restoration, and source switches while provider writes
converge. Metadata-only enrichment must not copy unified progress into an
untargeted physical source. Regressions cover the production stop notification,
source selection, completion, unwatch, and unrelated-account ID collisions.
