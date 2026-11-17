# Contributors

Plozz is maintained by [Brandon Moore](https://github.com/brandomoore).
Thank you to the community contributors below, and to everyone helping with
reports, testing, translations, documentation and support.

These credits include adapted proposals, not only commits GitHub counts in its
[contributor graph](https://github.com/brandomoore/Plozz/graphs/contributors).
Entries and README portraits are ordered by merged or adopted PR count, most
first, with alphabetical ties. Each PR counts once, including partial
adaptations; follow-up commits do not increase its count. This measures
contribution frequency, not effort or impact. A source PR link does not imply
that every change in that PR was adopted.

## tresby

15 merged or adopted PRs. [Profile](https://github.com/tresby)

- HTTP connectivity and per-stream M3U headers:
  [#62](https://github.com/brandomoore/Plozz/pull/62),
  [#63](https://github.com/brandomoore/Plozz/pull/63).
- Channel-logo backgrounds, Live TV playback and guide browsing:
  [#64](https://github.com/brandomoore/Plozz/pull/64),
  [#67](https://github.com/brandomoore/Plozz/pull/67),
  [#71](https://github.com/brandomoore/Plozz/pull/71).
- Per-kind skip modes and community markers:
  [#65](https://github.com/brandomoore/Plozz/pull/65).
- Native subtitle formatting, WebVTT positioning and readable green subtitles:
  [#66](https://github.com/brandomoore/Plozz/pull/66),
  [#70](https://github.com/brandomoore/Plozz/pull/70),
  [#72](https://github.com/brandomoore/Plozz/pull/72).
- Artwork-tinted background proposal:
  [#75](https://github.com/brandomoore/Plozz/pull/75), adapted as profile-scoped
  artwork gradients across themes in
  [6d27b18593](https://github.com/brandomoore/Plozz/commit/6d27b18593ca6dd2cbe815d052265ae863918368).
- On-device scrub previews, live HLS seeking/previews, AirPlay audio continuity,
  and redirected/encrypted live previews:
  [#80](https://github.com/brandomoore/Plozz/pull/80),
  [#92](https://github.com/brandomoore/Plozz/pull/92),
  [#97](https://github.com/brandomoore/Plozz/pull/97),
  [#102](https://github.com/brandomoore/Plozz/pull/102),
  [#282](https://github.com/brandomoore/Plozz/pull/282).

## kristofferR

5 merged or adopted PRs. [Profile](https://github.com/kristofferR)

- Browse artwork caching, off-main-thread poster compositing, scrolling
  benchmarks and directional prefetch:
  [#98](https://github.com/brandomoore/Plozz/pull/98),
  [#99](https://github.com/brandomoore/Plozz/pull/99),
  [#100](https://github.com/brandomoore/Plozz/pull/100),
  [#101](https://github.com/brandomoore/Plozz/pull/101).
- Custom watched-indicator colors:
  [#166](https://github.com/brandomoore/Plozz/pull/166), cherry-picked from
  [c12640783d](https://github.com/brandomoore/Plozz/commit/c12640783d5e91a81a808e04311eb89d9df72051).
  Original authorship and the source reference are retained in
  [853f399029](https://github.com/brandomoore/Plozz/commit/853f399029f178c4ca6b54c1af77952a089ed2bd);
  the shared-swatches follow-up
  [7312c0f2a4](https://github.com/brandomoore/Plozz/commit/7312c0f2a4a6faa4358933747b7c16f971c75ca9)
  also references the PR.

## MargeyShah

4 merged or adopted PRs. [Profile](https://github.com/MargeyShah)

- State-management guidance and content-refresh lifecycle proposals:
  [#440](https://github.com/brandomoore/Plozz/pull/440) and
  [#442](https://github.com/brandomoore/Plozz/pull/442), adapted in
  [3217ab666c](https://github.com/brandomoore/Plozz/commit/3217ab666c86786833130cfcd6301d00b59bf40b).
- Community skip-marker and after-credits proposal:
  [#444](https://github.com/brandomoore/Plozz/pull/444), adapted in
  [eb0fd6b70e](https://github.com/brandomoore/Plozz/commit/eb0fd6b70e1002b4ae6f4342573906f41ffc304b).
  The adopted behavior keeps distinct credits windows and does not infer
  after-credits scenes from short tails.
- Detail-hero sizing during native back navigation:
  [#457](https://github.com/brandomoore/Plozz/pull/457), specifically the
  detail-local geometry from the reviewed
  [67820fdfa3 snapshot](https://github.com/brandomoore/Plozz/commit/67820fdfa3b6686574d39769f853bbd745ea163a),
  adapted in
  [5e1381d0e9](https://github.com/brandomoore/Plozz/commit/5e1381d0e9f45a6f7a490b0a500bc1a6989ecb5e).
  This credits only that accepted part, not the broader Home, networking,
  Search or transition changes in the PR. The integration also contains
  separately requested Related/Cast sizing and native-gesture handling.
- Non-UI networking and Jellyfin scheduling ideas from the same
  [#457](https://github.com/brandomoore/Plozz/pull/457), originally in
  [8e3a47fd3e](https://github.com/brandomoore/Plozz/commit/8e3a47fd3e81118f311e33e7225a23e44bee94a4):
  shared foreground session pools, independently cancellable GET sharing,
  lightweight collection probes and bounded recency scheduling. This adaptation
  reuses the reviewed primary and alternative candidate repairs, preserves
  exhaustive Next Up, keeps discovery cookie stores isolated, and does not adopt
  the broader UI changes.

The #457 source-to-integration reference above was added retrospectively:
the published integration commit omitted it. Its history has not been rewritten.

## mossline

4 merged or adopted PRs. [Profile](https://github.com/mossline)

- Identifying the song playing in a movie:
  [#383](https://github.com/brandomoore/Plozz/pull/383).
- Allowing display sleep while a hero trailer plays:
  [#392](https://github.com/brandomoore/Plozz/pull/392).
- In-player Continue Watching:
  [#393](https://github.com/brandomoore/Plozz/pull/393), adapted to Home
  preferences in
  [2fe0dfc6b4](https://github.com/brandomoore/Plozz/commit/2fe0dfc6b43cb3f5094c6ee495408d342b311ef6).
  The integration preserves the source PR and human co-author credit.
- Restoring Picture in Picture to the player on app return:
  [#398](https://github.com/brandomoore/Plozz/pull/398).

## moofone

1 merged or adopted PR. [Profile](https://github.com/moofone)

- Saved guide-index answers for IPTV guide batches:
  [#456](https://github.com/brandomoore/Plozz/pull/456), integrated with
  revision-scoped lineup validation in
  [e4ba4d28af](https://github.com/brandomoore/Plozz/commit/e4ba4d28af12d58208881eb1c42e87ff7fc2b6c1).

## teymourb

1 merged or adopted PR. [Profile](https://github.com/teymourb)

- Preserving Dolby Vision conversion for confirmed Profile 7 MEL:
  [#418](https://github.com/brandomoore/Plozz/pull/418), integrated in
  [808dcd7f18](https://github.com/brandomoore/Plozz/commit/808dcd7f1803a90681d4e3de8fece80d905ce9a1).

## Keeping credit intact

Original authorship remains in the retained contributor commits for directly
merged work. For adaptations, keep both the original source and the integrating
commit discoverable, even when only part of a proposal is used.
The [contribution guidance](.github/CONTRIBUTING.md#preserving-contribution-credit)
describes how to preserve those references through cherry-picks and squashes.

These community credits do not replace upstream copyright and license notices.
See [NOTICE.md](NOTICE.md), the README's
[library and service credits](README.md#license-and-credits), and the
[Mozz adaptation notice](Sources/FeatureMusic/iOS/Mozz-NOTICE.txt).

README portraits are circular crops of the contributors' public GitHub avatars,
displayed at 64 pixels. Their original profile and image URLs are recorded in
[the portrait provenance](docs/assets/contributors/provenance.json).
Keep that record and the README updated when adding or changing a portrait.
