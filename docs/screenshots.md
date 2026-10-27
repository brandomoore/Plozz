# Screenshots and media credits

The README uses real Plozz simulator captures. Home and library views use a
catalog of 20 real film titles, including multiple in-progress films at distinct
playback positions. Full-bleed covers use licensed film frames and historical
public-domain artwork. Online metadata and artwork are disabled for capture.
The demonstration library is not bundled with Plozz.

## Provenance

- [Image records](assets/screenshots/provenance.json) identify the app revision,
  original PNG hashes and published JPEG hashes.
- [Media records](assets/screenshots/media-credits.json) and
  [public credits](https://plozz.app/media-credits/) identify creators, source
  evidence, licenses and crop/adaptation notices. Third-party media is not
  licensed under Plozz's MIT license.
- The separately retained `demo-media-source.zip` describes the previous
  procedural collection, not the current screenshots.

The catalog fixture supplies reviewed data to Plozz's normal media-provider
client; it is not a real Jellyfin deployment or an interoperability test.
The capture bootstrap configures this local source and completes onboarding
through existing app paths. It also keeps the internal screenshot router from
cancelling its own navigation before an acknowledgement. It does not recreate,
paint over or replace the application interface.

The player and subtitle editor show the actual licensed film Wing It!.
Scene-description captions were prepared for demonstration, not presented as
official film dialogue or translations. Watch progress is synthetic but stays
within the real editions' runtimes. Archive editions may be incomplete.

## Preparing captures

Use an isolated checkout and fresh, owned simulators with no personal accounts
or libraries. Follow the repository's build-lease and signing procedures. Do not
reset or reuse another session's simulator, and do not deploy capture builds to
physical devices.

Acquire only the precisely identified source editions and retain their rights
records. Use matching full-bleed artwork without padding, then serve the reviewed
catalog through an owned loopback fixture. The legacy NFS capture variable
enables the existing command channel; it does not require connecting a personal
share.

The DEBUG-only screenshot directors accept named requests in the app's
Documents directory:

```text
home
library
play?title=Wing%20It%21&at=66.625&pause=1&subs=0
play?title=Wing%20It%21&at=66.625&panel=subtitleStyle&pause=1&subs=1
```

Require a successful acknowledgement and loaded artwork before capturing the
framebuffer with `xcrun simctl io <owned-simulator-id> screenshot`. A missing
title, blank poster, loading screen or timed-out request is not a usable image.
Keep progress values within each actual video's runtime.

Native PNGs can be normalized to sRGB with an opaque alpha channel removed.
README JPEGs are proportionally resized from those originals. Do not stretch
screens, replace app text, add fictional controls or paint over unapproved art.
Keep portrait iPad captures portrait unless the app was genuinely captured in
landscape.

Stop the fixture server and owned simulators after capture. Retain the native
PNGs and source records. Use content-versioned image filenames when updating
the README so cached previews do not retain the previous image.

## Publication checks

Review every visible frame, poster, backdrop, avatar, description and caption
for reuse permission. Buying or streaming a film, using a metadata service, or
distributing a free app does not itself grant permission to reproduce its art.
Do not use the historical commercial-title lists or personal-share defaults in
older capture scripts for public assets.

Verify README image paths, image dimensions and provenance hashes. Keep
unreferenced or unapproved captures out of the published screenshot directory.
The marketing website has its own reviewed screenshot inventory and
publication checks; follow that repository's import instructions rather than
copying images into it implicitly.

For App Store assets, use the
[current Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
and [asset guidance](https://developer.apple.com/app-store/asset-best-practices/).
README JPEGs are not submission-sized originals. Confirm the final screenshots
match the intended submission build, and obtain design approval before
localization, upload or submission. Asset records do not guarantee legal
clearance or App Store approval.

## Channel identity theme comparison

`PlozzChannelIdentityCaptureTests/testNativeBylineThemes` in
`PlozzHomeFixtureTests` captures the Byline artwork in Light, Dark, and Black using
the production tvOS guide, sidebar, hero, and focus components. Run this selected
test on an owned Apple TV 4K simulator. The fixture uses identical sample
channels, category moods, a fixed schedule, and the same focused programme for
all images.

The fixture-only `PLOZZ_CHANNEL_IDENTITY_THEME` launch environment selects
`light`, `dark`, or `black`. These are native simulator captures, not physical-TV
captures or a configured user's library. The saved
`assets/plozz-oled-icon-concept.svg` and matching PNG are separate icon
explorations, not shipping assets.
