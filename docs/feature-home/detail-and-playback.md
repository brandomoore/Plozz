# Detail and playback selection

[Home task map](../../Sources/FeatureHome/README.md#where-to-look-first)

## Related loading

Library-only Related rows use the active profile's identity index to locate a
native copy, then fetch that item from its owning account instead of searching
every server by title. The fresh response must agree on item, account, kind and
strong catalog identity; native titles, artwork and watch state remain intact.
Missing, stale or unavailable index entries fall back to the existing verified
search. Index membership alone is not enough to display a synthetic library card.

Plex, Jellyfin and Emby fetch known copies in exact-ID batches scoped to the
authenticated account, including when several accounts use the same provider.
Silo, shares and other providers without the optional `LibraryItemBatchProviding`
transport retain individual lookups. A partial, failed or invalid batch retries
only the affected candidates individually before falling back to verified search.
Raw item IDs never identify an account or combine different servers' responses.

At most six batch/individual lookup or search jobs run concurrently, with a 24-candidate budget and
twelve distinct displayed results. Known indexed copies reserve display slots,
so a full indexed row does not initiate searches for unused later recommendations.
Unknown candidates retain bounded lookahead so a slow early search cannot hold
back a full set of later matches.
Provider order and continuation priority remain intact. Fast rows publish as a
batch immediately on completion; slower fallbacks retain 400-ms coalesced progress.
A cancellable publication timer exposes ready cards even when another server is
still pending and no further result arrives to trigger publication.
The detail model owns cancellation, including native lookups, and resumes an
interrupted row when returning. Cancelled recommendation responses do not enter
the public cache. Discovery's external-inclusive mode remains network-free after
recommendations, using the index only.

Seeded movie/series pages prepare public recommendations alongside their initial
detail fetch, without starting private library reads. Fresh detail consumes that
work only when the complete recommendation key still matches; identity changes
cancel it and resolve the new query. Failed/cancelled opens discard unconsumed
preparation. Series Related loading starts after fresh detail, not after seasons.

Recommendation caching does not cache private library metadata. A new detail
loader still verifies native copies; cached public recommendations cannot promise
zero network or immediate cold-provider responses. See the controlled
[Related loading measurements](../performance-lab.md#related-loading-while-scrolling)
for timing scope and scrolling limitations.

## Pending primary action

tvOS detail entry keeps the real primary action focusable while its play target
loads. An early press queues one activation, replacing the icon with a spinner
without resizing the button. Readiness consumes that intent once through the
normal playback callback; a pending series request opens the normal season
chooser, never a bulk request. A fresh Select during the cinematic entrance
queues only while the target is unavailable. A ready action finishes the
decorative entrance immediately rather than waiting for its animation or artwork;
the opening press, cancelled presses, and return-transition input are not replayed.
Leaving/covering the page, scene inactivity,
profile/request-identity changes, explicit source/version changes, or entering
the episode browser cancel the intent. Failed/empty resolution clears it and
retains the existing error/retry presentation. Late episode resolution must not move focus back from a
secondary action the user selected. Request/status actions retain the same
leading-entry preference, and returning from a child preserves source focus.

## Request status

Movie request statuses in Home and detail heroes use the same
`Requested · Unreleased` wording as season requests. This is an approved request
with a known future release day, not a prediction that downloading will start on
that day. Pending approval stays Requested; library availability and reported
queue activity take precedence, including queue items with no measurable progress.
Release days use the viewer's local calendar day, and missing dates are not guessed.
The UIKit and SwiftUI hero renderers share the localized status and calendar symbol.

## Inventory failures

Playback inventory failures on automatically selected TV sources use the existing
untried-account failover before constructing a player. Every replacement still
loads authoritative inventory; explicit selections, cancellation and revoked
presentation scope never fail over. An unavailable unselected edition is logged
and omitted from the current picker rather than blocking a confirmed primary.

The shared version gate and detail/episode inventory enrichment emit bounded,
failure-only `plozz-preparation-1` records to Recent Activity. They identify the
request stage, elapsed time, HTTP/network failure, safe decode field/type, and
inventory validation reason. Identity checks name the mismatched dimension, not
the item/account values. The existing Send Recent Activity action includes these
records on both platforms; error dialogs, playback routing and timeouts are unchanged.

## Version inventory

- **Explicit version inventory** — Version is offered only with at least two
  known choices on both platforms. A provider's ability to discover more files
  is not itself another choice. Lazy file discovery still runs only after an
  available version action is opened or Play requests its own inventory.
  Home, detail dwell, returning to a page and passive
  episode badge enrichment use presentation metadata, never playback inventory.
  Publication is fenced by the current source and the picker task's cancellation;
  later sparse metadata cannot erase authoritative file choices. Same-account
  alternate files use the same sequential discovery as the Play gate.
  Failure keeps browsing available but never authorizes playback: Play runs its
  own strict gate. Providers with complete detail inventories incur no extra fetch.
  Series heroes enrich the playable episode's ordinary metadata. Explicit
  mobile source/version actions use that episode even while
  the hero shows the series' artwork and description, matching tvOS. Choosing a
  version therefore remembers the episode/series preference, not a container file.
  A confirmed no-stream result from explicit detail discovery replaces Play with
  `No streams found` on both platforms. It rechecks the selected source without
  starting playback; successful recovery restores Play. This page-local result is
  scoped to the active server and episode, not inferred from timeouts, missing
  metadata or generic source errors. Retry failures remain visible and secondary
  mobile actions continue to overflow before the primary label is squeezed.

## Playback preparation

- **Bounded detail playback preparation** — The visible, active detail page may
  prepare one already-known WebDAV file after a 750 ms dwell. Movies use the
  resolved server/version; series use only the hero's resolved playable episode,
  not the displayed series container or every rail card. A versionless episode or
  raw movie qualifies only when ProviderShare's canonical physical-file ID proves
  its exact relative path; a logical title ID or synthetic presentation version
  alone is never that proof. Ambiguous or unauthorized selections do no work. Multi-version preparation
  additionally requires an explicit exact selection and automatic version mode.
  HTTP(S) network-share accounts and `networkFile` locators are both required;
  other providers and SMB/SFTP/FTP/NFS shares are not implicitly WebDAV.
  This approved exception uses `MediaProvider.playbackPreparationLocator`, not
  full `playbackInfo`: it cannot inventory/materialize sidecar subtitles or mutate
  watch state. It does not call `loadPlaybackVersions`, discover alternate
  inventories, instantiate an engine, or add another stream-facts probe.
  Preparation uses the item's already-loaded resume position (zero when absent);
  nonfinite or negative positions are ineligible. Progress changes supersede the
  old candidate without fetching watch state. Resume/Start Over still choose the
  actual playback time, and may reuse a valid file cache prepared for another time.
  The shared `FeatureHomeCore` coordinator checks live profile, authorization,
  account, server-user and credential identity around awaits. Source/version/
  episode changes, covered pages, inactivity and disappearance cancel work, with
  a 30-second preparation deadline. Background failures are logged without
  credential-bearing descriptions or user error sheets.
  A deliberate exact Play handoff retains an in-flight or completed reservation
  in the shell and asks optional preparation to yield while the normal
  resume/version/admission gates run. Profile/auth changes still
  evict it; abandonment is bounded by the resolver's 30-second TTL. Play must
  freshly validate and claim the exact locator, and a different choice plays
  normally without borrowing the prepared file. Preparation is an optimization,
  never authorization or evidence that playback succeeded.
  Performance reports must separate cold starts from detail-prepared starts and
  include dwell/byte costs; sub-three-second tap-to-play is not a cold-start claim.

## Item detail

- **Item detail** — `ItemDetailView` + `ItemDetailViewModel` and
  `DetailHeroView` / `DetailExtrasView` render the cinematic full-bleed
  backdrop, logo, overview, ratings, cast, and Play/Resume button. Works
  for movies, episodes, and people.
  Home and detail Play/Resume buttons use the compact `S1 E22` episode label on
  TV and mobile. Episode metadata elsewhere retains its existing punctuation.
  Explicit episode entries retain that episode as the hero's watched-action
  target. The opening card selects identity, not ongoing watch state: TV and
  mobile resolve the loaded episode with live resume data, never reapplying the
  original card's watched flag after a toggle.
  Playback resume reconciliation excludes sources of another media kind. A
  series page's source inventory must not clear its hero episode's saved position
  or contribute the show's watched state; eligible episode sources still use
  the shared cross-server resume policy.
  An episode's show breadcrumb is a single native button showing only the show
  title and chevron, without a background or border in either focus state.
  Play takes initial focus when available; Up then reaches
  the show, preserving its source account and season. Episodes without Play
  keep the breadcrumb immediately eligible for focus.
  Page ownership is identity-based, not an appearance-callback counter: repeated
  appearances and late departures cannot hide a different detail or give it the
  previous movie's trailer. A confirmed cancelled cinematic Back restores the page that
  remains on the real navigation stack, removes its cover/input guard, and keeps
  its controls focusable. Older transition completions cannot finish a newer pop.
  Returning to a retained page restores its cached artwork palette without a
  second crossfade after the cinematic cover lifts. Ordinary artwork changes
  still crossfade, and hidden pages still release their displayed-artwork owner.
  The bounded debug handoff journal records page membership, return outcomes,
  and hashed trailer ownership so an intermittent failure can be inspected
  without restarting the affected app.

## Series

- **Series** — `SeriesDetailView` + `SeriesResume` provide one stable
  series header, focus-driven season tabs and an episode rail. On TV and mobile,
  the header describes and rates the show, not the selected or resume episode;
  missing series metadata never falls back to episode prose or scores.
  Home, library, Search, Related, Continue Watching, season/context-menu and
  deep-link entry retain their episode/season selection without changing that
  subject, including the first paint while parent metadata is loading.
  Episode descriptions stay in the browser; explicit Episode Info pages retain
  their own synopsis, ratings and spoiler rules. Play/Resume, versions and watched
  actions still target the selected episode, while Watchlist and Trailer target
  the series. No series-versus-episode setting is needed.
  Season lists publish independently of the server resume lookup on both
  platforms. "Go to Show" retains the episode's season and can load its rail
  while resume is pending; entries without an explicit season still wait for
  resume before settling the opening episode. A failed initial show request
  exposes the existing retry state instead of leaving a bare seed loading.
  Refresh failures retain a previously loaded season list.
  On tvOS, opening an individual episode from Home or Search starts at the hero
  with Play focused, just like opening the show. The episode's source, season,
  and prepared rail target are retained; the rail does not claim initial focus
  or bypass the cinematic entrance. Returning from a child page retains the
  existing focus-restoration behavior rather than claiming Play again.
  Episode-rail re-entry measures the remembered card before revealing it.
  An already-visible card keeps its horizontal position instead of snapping to
  the leading edge when focus moves to Seasons, the hero, or lower details.
  Ratings and Details count as leaving the browser, so returning restores its
  full vertical stage without replacing the browsed card with a loading slot.
  Direct returns from Related to an episode restore that stage inside UIKit's
  coordinated focus animation. A SwiftUI focus-entry scroll alone can be
  overwritten by the native card's reveal, leaving actual focus offscreen.
  The page return overrides the short native focus-effect timing with a
  0.6-second ease-in/ease-out animation, paced against the native downward
  reveal. It remains interruptible and applies its destination immediately
  with Reduce Motion. Leaving the browser releases its scroll guard during the
  native focus handoff, before UIKit reveals the next row; stale SwiftUI reveal
  state cannot relock the page during rapid Up/Down reversals.
  A populated Related rail owns a full-width native focus section, so Down from
  a horizontally distant episode reaches even a single Related card before
  Cast. Empty and loading Related rows add no focus stop.
  Leaving for lower details also re-arms the episode entry gate. Returning
  through a different Related column, even while rapidly passing through to
  the hero, preserves the last browsed episode instead of remembering a
  geometrically closer card encountered in transit.
  The compact logo above Seasons fits wholly inside its 200pt slot, including
  tall wordmarks; it does not use the full hero's flexible height allowance.
  This changes only artwork sizing, not season/episode focus geometry.
  While the browser reveals, only the outer page's native scrolling is held:
  horizontal episode focus stays live without provoking a second vertical
  scroll that lifts the logo. The page restores normal scrolling when the
  reveal finishes or is cancelled. Season pills, resting episode artwork,
  loading cards, and About share the same leading keyline; card spacing stays
  on the trailing side rather than indenting the artwork.
  The shared hero/browser motion uses a finite 0.9-second curve with an earlier
  slowdown and gentle landing, including logo and backdrop parallax.
  A spring's logical completion leaves
  several points of upward travel after the apparent landing, even when the
  outer page never scrolls.
  Reduce Motion keeps the same resting hero placement and browser geometry:
  the resting content offset is structural, not optional animation travel.
  Movie hero focus restoration likewise skips its animated scroll under
  Reduce Motion instead of changing the hero's dimensions or artwork crop.
  When pinned navigation hides on detail pages, horizontal rows draw through
  the empty side gutter to the screen edge, including focused episode artwork.
  The sidebar's mask changes without replacing the scroll view, preserving
  browse position and restoring the normal feather when navigation returns.
