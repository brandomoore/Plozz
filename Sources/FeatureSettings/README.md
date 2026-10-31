# FeatureSettings

Mobile customization lists apply the shared native switch style to both standard
sections and grouped cards. Enabled switches keep the system green appearance
instead of inheriting the page's monochrome navigation tint.

The Settings screen and its detail pages. Profile-aware and integration-aware.

## Settings search

Settings search is local: queries are neither saved nor sent to a service or log.
The shared `SettingsSearchCatalog` indexes profile and device preferences,
including Home/Hero, artwork and labels, playback and subtitles, libraries,
Live TV, downloads, profile appearance, sync, metadata, diagnostics and startup.
Results use the current platform's destination and retain their query on Back.
Protected destinations retain their normal profile/PIN checks; search never
selects a server, library or user, enables a prerequisite, or submits an editor.
Unavailable controls lead to their existing prerequisite or availability message.
On mobile, custom quality keeps its normal modal editor: Cancel discards the draft, Apply
updates only the selected network, and either action returns to the search.

Matching prioritizes exact titles, then prefixes, related terms, and bounded
spelling corrections. This is a curated synonym index, not a general-purpose
language model. Do not promise arbitrary semantic understanding or add aliases
for capabilities a control does not provide.

The initial cross-player terminology comes from the
[Infuse settings reference](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview)
and Kodi's [video](https://kodi.wiki/view/Settings/Player/Videos) and
[subtitle](https://kodi.wiki/view/Settings/Player/Subtitles) references:
continuous playback, streaming cache, forward/backward skip, skip steps,
background playback, landscape lock, gesture control, poster titles, external
ratings, and subtitle position. These are discoverability terms, not claims of
feature parity. In particular, audio passthrough is not an alias for lossless
conversion; display refresh-rate matching is not an alias for transition fades;
subtitle placement is distinct from audio/subtitle timing.

iPhone on iOS 26 and later uses the system search toolbar item in the bottom
bar; iPad keeps the native search field visible in the Settings sidebar without a
redundant Settings heading. Detail pages retain their titles. Earlier iPhone
systems use SwiftUI's native search placement. Mobile results use plain native List rows,
with shared title/breadcrumb keylines and no additional result-container inset.
On iPhone, returning from a result restores the query and keyboard. Dismissing
the keyboard leaves the query visible and clearable; it does not end search.
The compact Settings root places its large heading inside the scrolling content,
below the toolbar. Scrolling past the heading shows the inline navigation title.
TV uses the existing retained
Settings page stack and native remote text entry. `SettingsSearchLanding` and
`settingsSearchAnchor` reveal the existing control without changing its value.
On mobile, the brief landing highlight covers the complete padded row, not just
its label or picker. Grouped rows own the highlight and their corner clipping;
standalone native List/Form rows use the native row background. The highlight
does not intercept touches or change the setting.
Grouped ownership is set before resolving SwiftUI subviews, so ScrollView rows
do not also paint a smaller control highlight. Nested anchors preserve a child's
active highlight, and nested row owners consume it without lighting up their parents.
Native lazy List cells register their contained targets with
`settingsSearchGroup`; the selected control is then revealed within that cell.
Every indexed entry needs an available route and a matching control anchor.
Disabled prerequisite controls can register dependent targets with `fallbackFor`;
do not register the same target on a still-mounted disabled child.
TV controls with their own focus binding pass `focusAction` to use that owner.
Search waits for native layout before requesting focus, including native menus
whose focusable view is not ready when the initial SwiftUI task begins.

Run `tools/check-settings-search.sh` when changing Settings. Its SwiftSyntax
inventory independently discovers controls in Settings/Preferences files and
reachable components, including custom input call sites and nested menus.
The checked-in `tools/settings-search-coverage.json` records individually reviewed
navigation, credential, contextual-content and preview exclusions. Exclusions
have exact control keys/counts; reusable renderer and presentation boundaries
also retain their control structure. A new control, arbitrary uncatalogued
anchor, missing destination anchor, stale exclusion or changed boundary fails.
Review a failure rather than accepting the current inventory as a new baseline.
Runtime navigation, provider access, lazy reveal and native focus still require
behavioral tests; static coverage is not proof that a screen works.

Searching for Hero, a Home banner, carousel, or spotlight opens the full Home
Hero page at **Show hero**, ahead of the incidental movie/show Background match.
This remains available when Hero is off and does not enable it automatically.
On TV with Showcase selected, search instead focuses the Hero layout choice;
changing layout still requires an explicit selection.

Mobile customization menus reuse `SettingsMenuValue`, the value/chevron rendering
used by `SettingsMenuLabel`. Playback details, per-view labels, and item-tap actions
retain their native menus and adaptive labels without separate value pills.
Artwork by view, label customization, and Hero subpages also use the shared
mobile `SettingsPageList` surface and `SettingsSectionGroup` rows. They inherit
the same page margins, headers, separators, corner radius, theme/gradient
background, and toolbar treatment as other Settings destinations, rather than
adding native inset-grouped styling or an opaque background. Lazy grouped
artwork and label rows register their contained search targets.

Playback > **Ask to resume or start over** is per-profile and off by default, including
for existing profiles. TV and mobile resume partially watched movies and episodes
directly unless it is enabled. Enabled profiles get the shared native Resume /
Start Over dialog before user-initiated playback; explicit restart and
automatic episode advancement do not gain a confirmation. Rewind on resume
remains independent. The preference travels with the existing playback settings.

On tvOS, Everyone > Profiles keeps **Automatically Sign In** in its own
`SettingsControlGroup` above the profile list, using the shared native switch.
This is a device-wide choice, not a setting belonging to the profile being edited.
Return timing is automatic, with no separate preference or saved override.
The profile list is a separate
`SettingsControlGroup` using `SettingsRowLabel` and contained native focus.
The page omits the introductory paragraph and redundant sign-in description.
The return defaults, PIN boundaries, and playback
exemptions are documented in `FeatureProfiles/README.md`. Mobile is unchanged.

**Appearance** owns global visual styling: theme, cards, artwork, display size,
and Circadian Mode. **Screens & Navigation → All screens** is a destination for shared
visibility preferences, including Spoiler Protection and the
profile-wide **Show content ratings** switch, on by default.
Spoiler controls appear inline below content ratings on both platforms, without
another subpage.
Its label includes small, noninteractive PG-13 and R examples using the actual
classification badge style; the examples stay visible when the switch is off.
The label adapts to narrow widths and accessibility text sizes. This controls
Home/detail badges, featured-card metadata, title-information classifications,
and exported Top Shelf classifications, not review scores or parental restrictions.
On tvOS, the example lettering and outlines follow the native row's focus
foreground so they remain visible on its inverted focused surface.

Home, Libraries, and Movie & show details expose the same card-label choices as
Appearance → Cards → Customize by view. These are additional controls over the
existing profile-scoped `CardCaptionSettings`, not independent preferences.
Home exposes Home rows and Continue Watching; Libraries exposes Recommended,
Browse, collections, playlists, and the shared Continue Watching choice.
Movie & show details exposes episodes, related titles, and extras. Central presets still
replace all overrides; contextual edits preserve other views. Screen-specific
sizing stays with its screen, while overall display size stays in Appearance.

Collection-cover layout is a presentation setting, not a browse filter.
Libraries lists collection directories alongside video libraries and
owns each library's Auto/Posters/Landscape choice. Collection-only directories
do not request or display a Recommended-page editor. Home and Recommended rows
retain their separate cover-layout choices in their settings editors.

Live TV settings exposes TV sources and the automatic Plozz channels switch on
the root page. Sources have a regular Add source header action and reuse the
shared fading scroll container above four entries. Guide/browsing preferences
remain owned here; the shell composes them with the retained source/library
runtime through `LiveTVSettingsSources`, without a FeatureSettings/FeatureLiveTV
dependency cycle. Source authorization does not gate ordinary view preferences.
See [Live TV settings](../../docs/live-tv-prototype.md) for navigation and overflow behavior.

Server sign-ins offer **Sign In Again** without removing the saved account.
Plex, Jellyfin, Emby, and Silo share the same guarded recovery contract; IPTV
uses **Edit connection**. Failed library authentication routes to that exact
account rather than the add-another-user flow. A network failure remains Retry,
and Connection addresses stays available for managed servers that moved.

Diagnostic reporting requires an explicit device-wide choice on every build
channel. `CrashReportingConsentView` appears before first-time setup or normal
startup when the build has a reporting endpoint and the current consent version
has not been answered. Existing users, including prior opt-ins and opt-outs, are
asked once after this migration; reporting stays off until they choose to share.
Either choice continues setup and survives relaunch and profile switching.
Help & Diagnostics can change it later. Consent is not synced or transferred.
The prompt and its primary Share Diagnostics and secondary Don't Share actions
use the shared Settings card above a separate bottom privacy footer, with
48-point content insets on tvOS and the standard card insets on mobile.
Its GitHub-marked link opens the repository
on mobile or a scannable QR sheet on Apple TV; opening it does not grant consent.

Settings and the consent screen also expose **Privacy Policy**, opening the
public policy on mobile or its URL and QR code on Apple TV. `SettingsCopy` keeps
automatic and manual diagnostic disclosures consistent across platforms.
Automatic reports describe technical errors, app/device information, screen
categories and performance diagnostics, not a blanket anonymity guarantee.
Manual uploads disclose additional playback/connection records and the user's
required message, which is sent as written apart from surrounding whitespace.
Submission copy does not promise confirmed server delivery. Privacy-policy
content is maintained on the website.
Manual attachments are constructed from typed activity categories/severity,
bounded technical operation timings, and structured playback/source journals.
Library browsing, recommendations and Continue Watching failures retain their
typed section, HTTP/decode route, coding-field path and paging evidence in a
bounded in-memory journal; arbitrary error descriptions are never attached.
Raw recent-activity messages and free-form persistent playback traces stay local:
they can contain server addresses, account identifiers, titles or search text.
Journal identifiers are replaced with report-local aliases and record times are
relative ages, preserving relationships and timing without exporting persistent
identity hashes or session UUIDs. Activity copy/share and prefilled issue links
use the same filtered activity projection. Filtering cannot make the user's
message anonymous or hide connection metadata from the receiving service.

On tvOS, Video buffer and Live TV buffer use the shared `SettingsMenuRow`: one
compact row showing the current value, with choices in the native menu and help
text below. Opening, focusing, or cancelling the menu does not save a choice;
Select does. Mobile retains its native pickers. These remain independent,
device-local preferences with Automatic as the default.

Playback's **Prefer lossless audio** toggle uses one short helper:
**Turn off for surround sound over regular HDMI ARC, which requires compressed audio.**
It defaults on for new and upgrading devices and is shared by Plozz
profiles on that device, not synced to other audio setups. Off selects the
ordinary compatibility-surround bridge; the spatial-height setting is separate.

Title navigation uses native page opening and closing. The former
**Zoom when opening titles** setting is removed, and saved values are ignored.
The hero's staged content reveal remains, without waiting for backdrop artwork,
and still respects Reduce Motion.

Home hero, Showcase (TV), Recommended Page (TV), and Movie & show details have independent
profile-scoped **Logo size** controls. Thirteen stops span 0.5x to 1.5x, with finer
adjustments around the unchanged 1x default, marked at the center. Previously
saved intermediate sizes keep their exact scale until adjusted.
These areas also have independent **Text size** controls:
eleven stops with a centered default. Apple TV spans 0.75x to 1.5x (24pt
descriptions by default, 18–36pt overall); mobile retains 0.75x to 1.25x.
They scale title fallbacks, metadata, descriptions, and the corresponding badge
icons, padding, and borders together, not actions, cards, or menus.
On Apple TV, Detail text sizing also controls episode titles and synopses beneath
the artwork. Detail hero descriptions are capped at four lines; Home may gain
one line when enlarged. Mobile retains its existing line limits, with
scrim coverage extended upward to suit the enlarged content. Showcase and
Recommended retain their available space: if needed, logo and text fit down
together while preserving their requested proportions and saved preferences.
TV reuses the shared Settings stepper's remote/focus behavior in two single-line
rows, with short stepped tracks and a larger center tick marking the default.
Labels, ticks, and adjustment glyphs share a vertical center; there is no Default
caption or Reset button. VoiceOver still announces the default value.
Long labels can wrap rather than shrink. Home and Showcase update their existing
layout-choice previews live instead of adding a second preview to the control.
Recommended retains its 320-point-wide preview. Movie & show details uses a 400-by-300
preview showing the hero, right-side credits, and episode captions scaling
together. Both retain the shared group inset and inner corner radius.
The complete preview-and-controls group is one native tvOS focus section, so
vertical navigation reaches the size controls even from the preview's side.
Artwork shares the layout picker's backdrop: Showcase fades in from the right,
while Home and detail previews use edge-to-edge artwork.
Mobile Home keeps native sliders beside their labels and one stacked preview.
No artwork lookup is needed for these fictional previews.

Movie & show details theme music uses the shared `ThemeMusicVolumeControl` on TV and mobile:
0–100%, with native touch sliders and the shared remote-adjustable Settings stepper.
TV shows the current percentage instead of notches, so each 1% Left/Right press
has visible numeric feedback. This control opts into the shared fast hold-repeat:
the unchanged 0.45-second initial delay, then one percentage point every 0.03 seconds
instead of the standard 0.08 seconds. Other controls retain their existing speed.
Mobile keeps its native slider and 1% precision. Saved values are not changed
merely by opening the control.
New/reset preferences start at 25%; existing saved volumes are not raised.
There is no explanatory paragraph under the preview action; playback errors
remain visible when they occur.
The player uses the selected gain directly, up to the device's full volume;
old Low/Medium/High preferences keep their exact 15/35/60% gains.
Adjusting starts a preview, with an explicit Play/Stop preview action too.
It samples up to eight recent/resume titles already admitted to the active
profile's Home content, through `MediaProvider`; without an available theme,
it loops an original locally generated instrumental sample. Errors are reported,
not presented as a successful preview. Leaving the control or app stops previews.
The Background mode owns Off. Only old string-valued silent preferences migrate
to Background Off; a new slider value of 0% remains selected and persists.
Migration does not change Home or trailer settings, with 25% ready for the next explicit opt-in.
On tvOS, the selected Background option supplies its own explanation rather than
repeating it in a section footer.

On tvOS, profile Appearance, Profile Lock setup, and Parental PIN setup use the
workspace's full-width destination layout, like subtitle styling. Their
two-column content must not be squeezed into the ordinary centered Settings
column. The stack retains the narrower parent page and its focus on return.

On tvOS, **Everyone → Top Shelf** reuses the native left/right `SettingsStepper`
for Continue Watching and Recently Added counts (4 by default, 1–20 each).
`TopShelfSettingsModel` owns one device-local preference shared across Plozz
profiles, excluded from profile transfer and sync. Household settings require an
adult profile; changing these counts never broadens the shelf's content access.
The page explains how top-row apps appear on the Apple TV Home Screen. The
default-on **Show Top Shelf** switch clears published media when disabled and
hides the count controls while retaining both counts for re-enabling.
The category uses a monochrome Home Screen icon with the shelf highlighted.
Posters / Full Screen reuse the shared `PreviewCard` focus and selection style
with schematic Home Screen previews. A slightly larger solid-white tile marks
the focused app, without an icon. Posters stays the default; full-screen explains
tvOS's swipe-up expansion and retains the same two item limits.

Playback > Advanced also contains **Dolby Vision FEL (experimental)** on TV,
iPhone and iPad. This is a profile-scoped, default-off preference, unlike the
device-wide external-player choice. It applies to new built-in on-demand sessions
and travels through profile settings transfer. Its short helper warns that it
may impact performance. On iOS/iPadOS and tvOS before 26 it also warns that
FEL disables spatial audio; ordinary channel audio still plays. On OS 26+,
eligible FEL tracks can retain spatial audio when the Spatial audio setting is on.
Live playback, shared players and muted previews do not opt in.
See [playback engines](../../docs/playback-engines.md#dolby-vision-fel) for eligibility
and output limits.

On tvOS and iOS/iPadOS 26+, Playback > Advanced also offers **Rendering layout** in a native
menu: 5.1.2, 5.1.4, 7.1.2, 7.1.4 and the default 9.1.6. This device-local choice
is shared by profiles, excluded from profile transfer and read on each new load.
It does not enable Spatial audio or alter saved On/Off choices. The helper
discloses that DTS:X heights require 7.1.4 or 9.1.6; smaller layouts retain
ordinary channel playback for those tracks. This is a rendering bed, not a
speaker-detection setting.

**Remember audio language per series** stores only the selected language, not a
specific audio track or format. Its label needs no explanatory footer.

On TV, related control groups can share one section heading through
`SettingsConnectedControlGroups`: an 8pt gap and tighter 8pt facing corners keep
them connected, while the section's outer corners retain the standard radius.
Audio language controls share the first group; Prefer lossless audio and Spatial
audio share the second, retaining their independent preferences and helpers.
Autoplay switches share a group, separate from the Up Next card and its
conditional timing control. These use the existing surfaces and native controls,
without an enclosing card or changing the independent settings.

**Skip intros, credits & more** uses one profile-scoped master switch on the
Playback page on both platforms. Enabling it reveals **Customize**, which opens
**Intros, credits & more**. Its first control, **Default behavior**, applies to
every marker and content type without an exception: Show skip button, Skip
instantly, or Skip after. Existing Off defaults remain visible until changed.
Each marker page always shows Movies, TV Shows, and Anime. Inherited choices show
the effective behavior with **(default)** in the picker value, without a helper
line. The native menu offers **Use default** to follow the shared behavior and timing.
It lists Use default, Show skip button, Skip instantly, and Skip after together,
then **Off** below a native divider on both platforms. Off uses normal styling.
An explicit Off, Show skip button, Skip instantly, or Skip after choice overrides
only that marker/content pair. There is no separate opt-in for exceptions.
Turning skipping off hides the link without clearing any saved choices.
Only an explicit **Skip after** choice reveals a timer, from 1 through 30 seconds
in one-second steps. Instant skipping is a direct choice, not a zero-second timer.
The default delayed skip remains five seconds. Movies, TV Shows, and Anime can
be enabled independently, using the existing audio/subtitle content classifier.
Disabling a category disables its controls on every marker page with a short
explanation, preserving all of its choices. It suppresses skip prompts and
automatic skips, not the independent Up Next or autoplay preferences.
Advanced per-marker choices retain
independent Off/manual/automatic behavior and timing. Existing saved modes,
including mixed immediate/delayed marker overrides, remain explicit exceptions.
Choosing **Use default** removes only the selected content rule; legacy per-marker
exceptions are preserved for the other categories. Changing the shared default
never overwrites exceptions, even if an exception currently matches the default.
Movies and episodes classified
as anime use the anime rules on either server provider. The new rules remain
profile-scoped and travel through settings transfer. Community-marker attribution
and identifier sharing appear as a short caption attached to its switch, without
a separate section footer.

The **Spatial audio (height channel support)** switch is available on tvOS and iOS/iPadOS 26 and later. Its
profile-scoped `trueHDAtmosEnabled` preference defaults on, preserves saved Off
choices and travels through profile transfer. It applies to new supported
on-demand sessions, not live streams, shared players or muted previews. The
helper identifies TrueHD Atmos and DTS:X as inputs, PCM rendering and lossy
AirPlay output. Format names describe compatibility, not certification,
lossless passthrough, or patent clearance.
FEL can use the same spatial conversion on these platforms; source eligibility and
fallback remain engine-owned. Unsupported platforms
keep ordinary channel playback; directly compatible spatial audio is unaffected.
Compatible AirPods use the system's spatial rendering automatically when enabled
in the OS; Plozz does not override Spatial Audio or head-tracking preferences.
Feature descriptions use neutral spatial-audio wording; track
metadata, diagnostics and legal notices retain accurate format and dependency names.
See [spatial audio](../../docs/playback-engines.md#spatial-audio) for limitations.

Playback > Advanced > External player is a device-only, default-off preference
shared by all profiles on that device. It stays inside Playback rather than
adding an Everyone category. The picker has one short scope label; About external
playback and custom configuration are separate drill-ins.
Choosing an installed player redirects compatible movies and episodes:
Native Player on tvOS, Infuse 8.4.7+ on both platforms, and VLC on both platforms.
The further-nested custom player editor accepts one encoded `{url}` placeholder.
Unavailable apps, failed handoff preparation, and unsupported sources use Plozz
automatically without a confirmation prompt or changing the preference.
Cancellation and profile/authorization changes abort playback, not fall back.
All IPTV content (including movies/episodes), NAS shares, and Silo bypass external
negotiation altogether. Silo's session-bound grants need its built-in lifecycle;
no speculative external session is opened. Live TV, trailers, and music keep
their existing runtimes.

On iPhone/iPad, downloaded movies and episodes play inside Plozz. Downloads
menus do not export files to other apps, regardless of the external-player
preference. External playback remains available for supported online sources.

External playback requires directly accessible HTTP(S) media: no app-local
proxy, downloaded file, private share credentials, separate audio stream, or
server conversion. Mobile quality limits are not bypassed. Links can contain
server tokens, so the settings explain that the chosen app receives them.
Jellyfin, Emby, and Plex direct-play sources remain eligible. Native Player and
Infuse receive resume positions and up to eight SRT sidecars;
VLC receives at most one sidecar and no resume/progress promise. Track selection,
skip markers, Plozz controls, and Plozz autoplay are not available after handoff.

`AppRuntime.ExternalPlaybackRuntime` correlates returns with a random session,
bundle-specific callback scheme, and media-URL digest. Its device-local receipt
contains no media URLs or tokens. Only the authorized launching profile,
account, server user, and credential revision can apply returned progress through
the existing durable watch outbox. No callback means no inferred watch progress.
Callbacks expire after 24 hours; a new playback intent supersedes older returns.
VLC/custom app links do not update Plozz watch progress. Once another app has
accepted a handoff, Plozz cannot detect arbitrary playback failures inside it;
supported error callbacks show the existing error without fabricating progress.
Native Player's optional `progress` fraction must be finite and within 0...1.
When present, it determines completion and its returned position is not clamped
to a possibly missing or inaccurate catalog runtime. Without that fraction,
existing runtime-based validation/calculation remains, including for Infuse.
The fraction survives receipt restoration; malformed or duplicate values are
rejected before watch state changes.
Supported partial returns also queue their percentage to Trakt as paused
playback; completion retains the existing watched-history reporting.
`ExternalPlayerSettingsModel` owns the unnamespaced device key, excluded from
profile transfer. The active profile's old choice migrates once; later profile
switches or sync never overwrite the device selection. `PlaybackSettings` reads
the retired field only for migration and no longer encodes it.
Protocol references: [Native Player](https://docs.google.com/document/d/e/2PACX-1vRfEYlU-LdWIAvIDXuHeoSs_d1ifydou7NBAhIUGsI5F663IlejVFQZ3UOaPPd9y9DhQcwKtM3VAKxz/pub),
[Infuse](https://support.firecore.com/hc/en-us/articles/215090997-API-for-Third-Party-Apps-Services),
and [VLC's Apple URL handler](https://github.com/videolan/vlc-ios/blob/749cf8be5f3abe0a044f1680a471999d714eb9e3/Sources/Helpers/Network/URLHandler.swift).

Trackers includes WeTrakr on both platforms, using device codes on TV and
verified HTTPS PKCE on canonical mobile builds. Its connection is profile-scoped;
watch history and planning-list behavior are documented in
[WetrakrService](../WetrakrService/README.md).

## Responsibility

- **Screen customization hierarchy** follows task boundaries. Screens & Navigation presents
  App navigation and All screens before Home, Libraries, Movie & show details,
  and Music player (TV only). Shared and screen-specific destinations are separated
  without an extra category heading. Navigation labels name destinations;
  explanatory copy uses "screen" for destinations and "view" for grid/list presentation.
  The App navigation entry and destination share that title on TV and mobile.
  Home opens Layout/Hero, Card labels, Rows, or Filtering through matching
  full-height navigation rows, without redundant subtitles. TV shows the current
  layout as a secondary value. Home rows owns Preset, one Add row action, the
  row list, and Edit/Done. Mobile uses a native toolbar editing action; TV places
  the native action inline with the scrolling page title and Back control.
  Editing remains available for one row so it can be removed; movement does not.
  Presets and reordering never change page appearance. Showcase's fixed Discovery
  row links back to Home layout rather than pretending to be reorderable.
  Shared Continue Watching settings remain accessible when its Home row is hidden.
  Home → Filtering groups two independent switches under **Hide watched content**:
  **Recently Added** (off by default) and **Hero & discovery** (on by default).
  Filtering stays available when the hero is off. These controls are moved, not
  duplicated in the row or hero editors, and retain their existing profile-scoped stores.
  Recently Added applies to combined, library, and server Recently Added rows,
  not Continue Watching, Next Up, Watchlist, collections, or the hero.
  Movie & show details keeps hero controls together and places its label editor under Cards.
  These destinations preserve the existing profile-scoped stores. See CoreUI's
  row-geometry guidance; the deprecated text-height focus strip must not return.
- **Customize labels** uses one shared, page-organized visual editor from
  Appearance's Cards page and the scoped Home, Libraries, and Detail Page links.
  Home and Recommended each show Default (On/Off/Mixed), followed by an Overrides
  section containing Continue Watching (Use default/On/Off). The short footer names
  the other page sharing that override; Use default inherits each page's own choice.
  Single-control pages retain Card labels without Default or Overrides headings.
  Detail Page keeps independent Episodes, Related titles, and Extras controls;
  Search, Watchlist, and People are also available from the full editor. Scoped
  single-page editors omit the Page selector. All entry points edit the same
  profile-scoped caption settings; navigation and preview focus never change
  saved values. Previews highlight the affected captions, not a duplicate table
  describing whether each label is on or off.
  The scoped Home destination is titled Card labels and places its live preview
  immediately below the controls and shared-scope note. Other editors retain their
  pinned contextual help. TV Page opens a native checked selection menu rather than cycling through
  pages. TV diagrams use fewer sample cards and larger row headings for viewing
  at a distance. Mixed has a visible, platform-specific explanation; Home and
  Recommended explicitly distinguish per-page inheritance from their shared
  Continue Watching On/Off override.
- **Libraries customization** lives in Screens & Navigation on TV and mobile.
  Library Navigation comes first, including the first Down move from Back on TV.
  Page appearance follows it, containing Recommended Page sizing on TV and the
  separate label editor for all library tabs. Recommended rows lists libraries
  and opens each library's Recommended Page Rows editor.
  The TV logo control reuses `HeroLogoSizeControl` with one Showcase preview.
  Customize labels is the attached lower group beneath those controls, using
  `SettingsConnectedControlGroups` rather than a prominent list of overrides.
  Its editor selects a page: Recommended, Browse, Collections, or Playlists.
  Recommended has Default and a separate Continue Watching override; the other
  pages each have one Card labels control. TV focus and mobile value changes
  highlight the affected captions on that page, without a duplicate status table.
- **App navigation** automatically includes enabled, discovered library shortcuts.
  Top Bar scrolls horizontally without an item cap, beside a fixed profile
  button. Settings opens from the profile picker instead. Both sidebars retain
  all items and Settings.
  Manual hides and ordering stay
  profile-scoped. Refreshing Libraries also updates the main navigation inventory;
  unchanged results must not invalidate the navigation chrome during Settings entry.
  Mobile includes enabled library tabs alongside its built-in destinations.
  VoiceOver retains the equivalent state description.
  Use default retains the existing inheritance; On/Off remains
  one shared override, explicitly noted as also affecting Home.
  Recommended highlights Continue Watching only while it
  follows the page. Collection/playlist covers are distinct from titles inside,
  which retain Browse's labels. No stored defaults or profile scopes change.
  Library tabs share an arrangement across the profile; each library separately
  owns its Recommended row arrangement. Both editors use `LiftableReorderList`,
  its Hidden divider, native focus/drag behavior, and scoped reset actions.
  Navigation library rows use the shared content-kind glyph, with the provider
  mark and server name below the library name rather than beside the drag handle.
  `LibraryPresentationLoading` connects the settings UI to the existing browse
  and discovery pipeline through AppRuntime, without a feature-to-feature
  dependency. Identity changes cancel pending discovery and replace row editors.
  These choices never disable a library or alter its Home rows.
- **Libraries** owns profile-wide library availability. Mobile Home customization
  does not duplicate its Enabled controls: the Home editor manages section presentation,
  and Hero source selection uses the enabled library inventory. Discovering
  libraries for those controls must not restore a separate management list.
- **Home rows** is one shared arrangement editor on TV, iPhone and iPad.
  Normal rows open their own settings. Source-specific rows and their settings
  use the shared provider brand mark, including the transport badge for shares.
  In the editor, Add row, and reorder rows, the mark sits beside the
  library/server name on the second line rather than before the section title;
  generic row glyphs appear only during reordering.
  An inline Preset selector sits below the title, with up/down chevrons beside
  its current value to expose the native menu; mobile uses a secondary heading
  with a trailing native menu capsule and a divider, not another section card.
  It scrolls with the content and stacks at large text sizes when needed.
  One full-width Add row action appears below Preset and above the editable rows.
  A centered plus-and-label, native capsule style, and vertical spacing distinguish
  the action from the editable rows. Edit/Done switches to native movement controls
  with no Hidden drop zone. Hero and Showcase remain on their separate layout page.
  Mobile uses the shared page inset without extra gutters.
  Add row separates **From a collection** from **Available rows** not already
  shown. Empty results omit the empty heading; discovery failures show source
  errors and Retry instead of claiming no rows are available. Creation starts with
  a library collection; the editor identifies that source as Content and its
  presentation as Layout (see [Home terminology](../../CONTEXT.md)). Choose a source collection first,
  then edit its name and Posters, Landscape or Featured presentation with the layout control immediately above a real-title
  preview. The preview uses the existing artwork preferences and spoiler protection.
  Each navigation destination explicitly forwards the active profile's card settings,
  including Add row's nested creation destination; iOS navigation does not
  inherit dependencies injected only into the preceding page.
  Save places a new independently configured row before Libraries; the ordinary
  arranger can move it anywhere among the movable rows. Editing never changes
  the collection on the server. Preview loading is bounded and retains server order;
  filtering and combining multiple sources are not yet supported. Removing a
  section hides it without erasing its configuration or disabling its libraries.
  Holding a normal row opens Reorder and Remove from Home. Reorder keeps the
  selected section as the movement target: TV lifts and focuses it immediately;
  mobile exposes native drag handles without losing its position. Collection
  subtitles resolve their server mark from the current account even without a
  discovered library. The collection chooser also shows the active account's
  provider mark beside each library's second-line server label, including personal
  collection sources. Featured previews share the live card's artwork, logo and
  metadata layout without starting playback in Settings. Reorder menus include Move to top
  and Move to bottom within the movable sections, never above Home layout.
  On TV, picked-up rows retain native focus during rapid directional presses
  and held Up/Down; reaching an edge does not move focus out of the list.
  Home's latest section warnings also appear here with Details and Retry.
  These are transient results fenced by profile, account, effective viewer,
  credentials, and the loaded Home settings; catalog discovery is not treated
  as evidence that the actual Home content request succeeded.
  Continue Watching owns its merge and artwork controls. Hero owns its sources
  and presentation, including the existing TV Home Layout/Showcase options.
  Continue Watching groups artwork, playback details and labels before their shared
  Recommended-page scope note; Include Next Up and selection behavior follow.
  Showcase groups Ratings and Discovery with their dependent controls.
  **Center button action** on TV and **When tapping an item** on iPhone/iPad
  select **Play** or **Open detail page** for Home's movie/episode cards.
  Play remains the default for fresh and existing profiles. The choice uses the
  existing profile-scoped Home settings store and profile transfer; it does not
  change artwork or Live TV shortcuts.
  On Apple TV this setting controls the center button only; the remote's
  Play/Pause button always starts the focused Continue Watching movie or episode.
  Helper text below the control describes Play/Pause, with its filled circular
  symbol, as an additional way to play the focused item without promising immediate
  playback. VoiceOver reads the button name without repeating the symbol.
  The section editor shows the three artwork choices first, followed by a shared
  settings group for Playback details and Labels, then a group for Merge Next Up
  and selection behavior. The shared containers own insets and separators.
  Continue Watching offers three native preview choices: Artwork + logo,
  Thumbnail, and Poster. Simple fabricated illustrations distinguish a backdrop
  with an overlaid logo, an unbranded scene, and portrait poster artwork without
  implying a fixed title position. Figures preserve their proportions; artwork
  and playback controls use a shared scale that preserves the cards' relative
  sizes, with larger compact previews, 12-point horizontal gutters, and tighter
  vertical padding. Visible artwork and optional labels are centered together,
  with no empty caption space when labels are off.
  TV examples use a taller preview area and larger playback details for viewing-distance
  legibility; this illustration-only adjustment does not change real cards or mobile previews.
  Their containers use the same `ThemeCardButtonStyle` as `PreviewCard`, including
  its shared selection and focus treatment, rather than a separate glass action-button style.
  Each choice owns its hit shape and accessibility label so scaled decorative
  artwork cannot overlap neighboring controls or expose fabricated playback text.
  They share equal choice sizes on TV and
  wide layouts, becoming preview-led rows on compact mobile layouts. The native
  Playback details control applies to all three choices: Detailed retains the
  play/progress/text overlay; Progress only uses the existing shared white bar
  without playback text on the artwork. Detailed remains the default.
  Portrait uses complete movie/show posters, with a short progressively blurred
  reflection in Detailed or standard-height posters in Progress only.
  Portrait cannot combine with thumbnails and preserves the saved landscape artwork
  preference. The presentation is profile-scoped and also applies to library
  Continue Watching rows. All three styles expose a Labels control bound to the same
  Continue Watching override in Appearance -> Cards -> Labels by view:
  Use default inherits Home or Recommended's default; On/Off controls the labels
  below any Continue Watching artwork. Each preview shows or hides its caption
  lines using the same choice. The previous portrait override is preserved.
  Caption presets/reset clear this override, and
  switching artwork presentation preserves it. Playback details is independently
  profile-scoped, survives layout changes, and does not change the Labels override.
  The Include Next Up explanation belongs to the native toggle's label, not a
  separate helper-text row.
  Preset retains the confirmed Match server and Combined rows choices and shows
  Custom for edited arrangements. Selecting a new preset still requires
  confirmation.
  Merely opening the editor, a destination, or Reorder does not freeze a preset.
  Home rows and Add row use shared `InlineErrorMessage` warnings to name affected
  sources and offer Retry; appearance-only destinations do not repeat these.
  The root and every catalog-editing destination keep discovery active while
  visible and retain loading status and local edit failures. Preset changes reload the catalog.
  Edit is available as soon as one known row can be removed, independently of
  server discovery or failures; movement requires two rows. An editing session snapshots its known rows so
  late discovery cannot move or disable a lifted row; the first actual move
  saves that arrangement, retaining unavailable saved identities. Newly discovered
  sections remain available through Add row. Known, identity-scoped sections
  remain focusable and editable while optional discovery runs; loading only
  delays choices that have not been discovered yet.
  Mobile library discovery publishes one identity-scoped snapshot, never pairing
  a previous viewer's library metadata with the newly active credentials.
  Continue Watching artwork previews remain inside equal native choices rather
  than a separate floating preview; compact mobile layouts use preview-led rows.
- `HomeSectionCatalog` owns typed choice deduplication and validated section
  edits; `HomeSectionCatalogModel` owns bounded, identity-fenced discovery.
  The UI writes through the existing profile-scoped `HomeLibraryVisibilityModel`.
  See [CoreModels](../CoreModels/README.md#home-section-editing) for ownership
  and extension boundaries. This editor does not introduce another feed engine.
- Individual profile settings expose the existing device-wide Automatically
  Sign In preference below Kids Profile, followed by a separate Delete Profile
  group. Everyone → Profiles keeps the same control and binding. Shared
  `FeatureProfiles` controls explain device scope in the description, not an
  additional heading; profile locks and parental gates still protect management.
- **Servers > Connection addresses** opens the shared address editor for each
  Jellyfin, Emby, Plex, or Silo sign-in on TV and mobile. One explicit
  **Add or manage addresses** action replaces a second list of user names.
  Multiple sign-ins get a native chooser explaining which sign-in is being
  updated; a single sign-in opens directly. The editor names both the server and
  sign-in, while address rows show URLs rather than user names. The original sign-in
  address remains visible; verified aliases can be added or removed. Saving
  updates retained providers' routes without rotating credentials or discarding
  active playback grants; unrelated sign-ins retain their providers. Address
  changes apply to subsequent work, not seamless migration of an active stream.
  Network-share aliases are a separate feature.
- `ProfileSettingsCategory` in CoreUI owns the cross-platform profile category
  order, names, icons, and summaries: Playback, Subtitles, Live TV, Libraries,
  Appearance, Screens & Navigation, Trackers, Language. Compact mobile windows
  use native push navigation; regular-width windows use a sidebar and detail stack.
  Both mobile layouts share their category section and destinations. Appearance
  groups Theme, Cards, Artwork, and Circadian Mode; Display
  Size is last inside Cards. Screens & Navigation groups App navigation,
  All screens, Home, Libraries, and Movie & show details; Music player remains TV-only because mobile does
  not implement those presentation choices. Mobile navigation editing includes
  every enabled video library from the shared discovery inventory; Music remains
  TV-only. Refreshing Libraries updates the available shortcuts
  without resetting saved hide/order choices.
  Home, Downloads, and Search are the iPhone/iPad defaults, even before content
  discovery. Watchlist, Live TV, Settings, All Libraries, and individual libraries
  are opt-in through App navigation. Discovery never adds tabs automatically.
  Explicit Show/Hide choices and ordering stay profile-scoped; Reset Navigation
  restores these three defaults without changing content availability or TV defaults.
  The mobile app shell uses native adaptive tabs and sidebar, with system More
  overflow on iPhone only above five enabled pages. Destination declarations and their navigation stacks stay mounted
  across width changes; profile-scoped ordering and visibility remain authoritative.
  Pages opened from More use their existing stack's single navigation bar: Back,
  an inline title, and page actions share one row. The outer More bar is hidden
  only while showing a destination and restored on return. Direct tabs keep their
  normal title styles; deeper pages keep their own back navigation.
  The bridge resolves destinations from native `UITab` objects when present:
  newer iOS versions leave the legacy `viewControllers` array empty. More-row
  interception and destination matching must use the same controller inventory.
  Downloads composes the shared Back item inside its page toolbar so its actions
  do not displace the shell's root navigation control.
  Library tabs use the same content-kind icons as tvOS and library names without
  server suffixes. Same-named libraries remain separate destinations; the
  arrangement editor identifies their servers on a second line.
  All Libraries is also available on iPhone/iPad when the profile has more than
  one visible video library. It can be shown, moved, or hidden in App navigation, using
  the same saved key as tvOS. Hiding an individual navigation shortcut does not
  exclude that library's content from the combined grid; disabling its content does.
  Settings opens as a sheet from direct tabs or native More without replacing
  the selected page or its navigation history.
  Everyone uses the TV order, with mobile-only Downloads last. Version/build,
  release notes, and community links are inline on both mobile root layouts.
  Mobile Community uses standard-height, single-line Discord and GitHub links
  with small brand icons, without subtitles or QR codes. TV keeps its scannable
  community cards.
  Mobile Settings also includes a **More apps** section linking Mozz to its
  public TestFlight beta. Both compact and regular layouts share the same native
  link and preserve the official full-color light/dark app icon. Its three-line
  label identifies Mozz as a free, open-source music player and names the
  TestFlight public beta without adding another line. Mozz is not
  advertised on tvOS. The iOS-only `MozzAppIcon` imageset is copied unchanged from
  `brandomoore/Mozz` at `b262a5a1257ac20369287599e6fea888462f8284`,
  `App/Mozz/Assets.xcassets/AppIcon.appiconset`; `AppLinks.mozzTestFlight`
  owns the invite URL.
  The compact and regular root menus eagerly lay out their small, fixed set of
  sections. This keeps variable-height groups stable while scrolling rather
  than repeatedly revising lazy height estimates as the promotion enters view.
  Kids-profile gates and profile/household storage ownership are unchanged.
  `SettingsLibrarySourcesSummary` shares configured source grouping and profile
  inclusion with TV. Mobile keeps the source icons/names on one horizontal line,
  showing up to three names when they fit and counting the rest in `+N more`.
  Narrow sidebars and larger text show fewer names; an oversized first name
  truncates beside a compact `+N` count rather than wrapping or hiding the count.
- `PlaybackReadAheadControl` — Playback's device-local **Video buffer**
  uses the shared checkable option list on TV and a native menu picker on mobile,
  including share-only profiles. Automatic, 1 minute, 5 minutes, 10 minutes and
  Maximum available share one ordered model and default. One short note explains
  the storage cost and excludes Apple's native player without naming internal
  engines or explaining when settings take effect. This is
  independent of profile preferences and metadata/artwork cache budgets.
- `LivePlaybackBufferControl` — the neighboring **Live TV buffer** uses the same
  native controls and remains independent of Video buffer. Automatic preserves
  the engine defaults; 10, 20, 30 and 45 seconds trade live delay and potentially
  slower channel changes for buffering resilience. This device-local preference
  is excluded from profile transfer and does not change scheduled library channels.
- `HeroSettingsControls` — Hero keeps content selection, watched filtering, item
  count, and automatic changes together, shared by TV and mobile. **Ratings** and
  **Trailers** each show their current On/Off state and open their detailed
  controls; neither is hidden behind a generic Appearance label.
  The shared rating-count picker is visibly labeled **Maximum ratings shown**:
  it caps available scores rather than promising every title has that many.
  **Hero content sources** is the source-selection page; its link summarizes the
  currently permitted selections using the current app locale for both source
  labels and list formatting. Library, collection, Watchlist variety, and
  Discovery options use the shared `ViewPreferenceChoiceGroup` with the source
  they configure, so a source toggle and its links form one visual group.
  TV forms share row/section spacing and contained, concentric focus geometry;
  steppers focus the whole labeled row, with visible minus/plus cues and
  Left/Right adjustment. Values stay aligned to the trailing column.
  `ViewCustomizationList` varies edge-fade strength over fixed mask geometry.
  Resizing the mask while native focus scrolls can feed back into layout and
  leave long forms, including Hero content sources, unresponsive.
  `SettingsControlRows` separates controls sharing a container, keeping each
  helper with its control and omitting the divider after the last visible row.
  Hero copy uses **content** for the overall selection and **item** for one entry,
  rather than calling entries titles. **Advance automatically** and its conditional
  **Seconds per item** control share a group without a redundant section heading.
  Mobile source groups use separate native Section rows; grouped-page links
  use independent buttons with native navigation destinations so no link can
  claim a sibling switch's cell action. Each mobile destination explicitly receives
  the link's existing profile-scoped hero and trailer settings models, including
  nested source pages; page-local environment injection does not cross the native
  navigation boundary.
  **Discovery** consistently means external recommendations; its
  provider selections and **Show provider labels** attribution toggle live together.
  Ratings, trailers, and the longer source/provider/library/collection lists use subpages. TV uses
  retained detail panes with a separate nested navigation owner and returns focus
  to the originating link; mobile keeps system switches and native navigation.
- **Kids profiles** always disable external Home Discovery, including Showcase's
  Discovery row, independently of whether a Parental PIN exists. Preferences stay
  saved for later use outside Kids mode; this restriction is not synced as an
  editable setting. Connected server-user restrictions still govern library
  content—Plozz does not infer maturity from incomplete external catalog ratings.
- `CardAppearanceControls` — **Watch indicators** offers Watched, Unwatched,
  and Hidden. Hidden removes only watch marks, preserving episode counts,
  playback progress, download badges, and library/request status. The saved
  color is retained while its control is hidden. TV keeps side-by-side previews;
  iOS also shows side-by-side choices when the settings content fits three
  200-point cards plus spacing (scaled with text size). Narrow windows and
  accessibility text sizes use one compact live preview and a native menu for
  both Labels and Watch indicators. This responds to available width, including
  iPad multitasking, rather than device type. Custom label overrides leave the
  visual presets unselected and show Custom in the menu until a preset replaces them.
  The independent **Show unwatched episode count** toggle defaults on,
  persists per profile, and transfers/syncs with that profile without changing
  its watched/unwatched style. Both previews show a sample count on the
  in-progress series when enabled; toggling it updates the previews immediately
  without removing the separate watched check or unwatched flag examples.
  **Episode count style** offers Attached or Floating while counts are enabled.
  Mobile uses the same native menu picker as Watch indicators, with a trailing
  selected value and the system menu affordance.
  The choice is profile-scoped, transfers with the profile, and never changes watch marks.
  Turning counts off retains the style. Existing profiles keep their previous
  placement on upgrade; both previews then follow this independent choice.
  **Show progress bars** is a separate default-on, profile-scoped toggle below
  the count controls. It hides viewing-progress bars on media and episode cards,
  including Continue Watching and live previews, without removing episode/time
  text, download indicators, or changing player timelines and play-button progress.
  The preference transfers/syncs with the profile.
  The eight watch-mark colors appear as one horizontal swatch row below the
  indicator previews. White remains the default; changes update the previews
  immediately and persist/transfer per profile. Narrow mobile layouts scroll
  horizontally instead of wrapping or shrinking the 44pt controls.
- `SettingsView` / `SettingsWorkspace` — tvOS shows one centered page at a time.
  The root contains profile identity and the category list, without a preview pane.
  Categories and ordinary descendants share `SettingsFormMetrics.pageWidth`;
  entering and returning fades between those equally sized pages with a short
  directional movement, without resizing or sliding across the screen.
  Back from a category restores its selected row and retained scroll position;
  Back from a child returns one page. Playback initially owns focus, not a second pane.
  The remembered category only restores navigation: native focus owns the row's
  highlight and selected accessibility trait. Moving to profile actions, credits,
  or any other root control must not leave an inactive category highlighted.
  The avatar/name switches profiles; the adjacent
  Edit action uses the same `ProfileActionsList` as the profile picker.
  Profile and Everyone headers share title weight/size, icon width, label gap
  and content insets so their icons and names align. Everyone's scope glyph sits
  inside a circle the same size as the profile avatar. The separators beneath
  these two headers span the full card; category-row separators stay text-aligned.
  `SettingsFormLayout` groups related controls into one vertical form, retaining
  child pages for longer editors. Single-control preferences such as Language
  use one compact label-and-control row without an extra heading or explanatory
  paragraphs. Language is a native menu directly on the root, after Trackers,
  showing the current selection. A translation-feedback QR dialog remains
  available from that menu for non-English languages and restores focus on dismissal. It shares the category
  focus/return behavior without opening an intermediate General page.
  `SettingsMenuRow` gives app/audio/subtitle language, subtitle download policy,
  and Circadian location the same whole-row focus and native menu presentation.
  A setting's label and current value form one control, not a detached value pill.
  Appearance contains Theme (including gradient backgrounds and Liquid Glass),
  Cards (with Display Size last), Artwork and Circadian Mode.
  Screens & Navigation contains App navigation, All screens, Home, Libraries,
  Movie & show details and Music player. Moving these controls does not change their profile-scoped stores.
  Playback groups
  audio, autoplay/Up Next, marker skipping, seeking and display fades.
  **Skip intros, credits & more** has one inline toggle and a conditional **Customize**
  link. That page contains the shared default, community markers, and one page
  per marker with Movies, TV Shows, and Anime exceptions or **Use default**.
  Subtitles is its own profile category for mode, the shared/Live TV style
  editors, language, downloading and per-series memory; downloading still
  follows the active profile's provider capabilities.
  Both subtitle-style editors deliberately use the full workspace for their large
  live preview; this is the only width exception. The shared
  `SettingsPageStack` retains parents and owns typed routes, local child pages,
  and Back, including IPTV and profile editors. All use the same directional
  420ms eased fade and 64pt travel as the subtitle editor's internal panels.
  Reduce Motion changes the layout without animation.
  The incoming and outgoing style destination always lays out at the final
  workspace width; the navigation viewport reveals it without resizing the preview.
  Hidden or focus-ineligible categories also stop observing native focus, so
  an editor control cannot be mistaken for a category during the transition.
  The navigation history and profile context remain intact, including
  inside the editor's font and appearance subpages.
  Libraries, Live TV and Trackers remain profile-owned. Household setup is
  separate under Everyone. Beneath Libraries, the original signed-in strip shows
  the names and provider icons of the added sources this profile watches, grouped
  by server like the detail page. It shows up to three, then a "+N more" count.
  These are configured source names, not discovered sections such as Movies or
  Music, so they remain visible before discovery or while a server is offline.
  Profile categories start with Playback, Subtitles,
  Live TV and Libraries, then Appearance, Screens & Navigation, Trackers and Language.
  Appearance, Screens & Navigation and Trackers retain concise explanatory subtitles.
  Artwork remains profile-owned; Metadata Providers remains shared under Everyone.
  Kids profiles retain their existing parental authorization and household restrictions.
  About is a compact
  root summary with version/build, release notes and community QR codes; credits,
  Help & Diagnostics and the adult-only sign-out action follow in one group.
  `SettingsRowStyle` and `SettingsContext` provide shared controls and dependencies.
  The navigation viewport extends through the vertical safe area, keeping
  the initial top inset inside its scrollable content instead of clipping pages
  at that inset. Segmented choices share the body-sized control font; explanatory
  copy uses the smaller shared helper style.
  `SettingsFormMetrics` in CoreUI owns the centered page width, page insets, group padding and the gaps
  between sections, controls and related content, using `PlozzTheme.Spacing`.
  A legacy split-pane gap must not become large empty space between controls
  inside a workspace form. The navigation owner supplies a focus-aware Back
  control through `settingsPageBackButton`; page headers and custom editors
  host it inside ordinary pages' scrolling content. `SettingsBackButton` selects
  the same native style everywhere, and `SettingsPageHeader` places the title to
  its right, including Customize by view. Full-screen subtitle
  customization is the explicit exception: Back sits beside the stationary title,
  and only the bounded left tool pane scrolls beside the large preview.
  Preview controls below the pane expand on focus, smoothly reducing the pane's
  available height instead of scrolling the whole page. There is no redundant
  Appearance heading.
  Standalone page links use matching 28pt idle/focus corners and compact 8pt gaps.
  Controls within sections use inset rounded focus geometry instead. The shared
  `SettingsControlGroup` supplies section surfaces, row separators and insets;
  `SettingsDetailGroup` uses it for Cards and other multi-group pages. A row marked
  `groupedContent()` already owns its groups and must not gain another outer box.
  `ViewCustomizationList.hasGroupedContent` preserves the same boundary for
  editors such as Hero's source groups instead of adding a second container.
  Illustrated groups use 16pt padding on every side and a 16pt gap without a
  divider between previews and controls, including Theme, Cards and Navigation.
  Ordinary form groups share that 16pt inset and a concentric 12pt focus radius.
  Illustrated cards derive their outer chrome from the same contained radius and
  do not scale through the inset on focus; standalone/onboarding cards are unchanged.
  Group headings, compact labels, toggle/stepper labels, helper copy and ordinary
  separators use one 28pt leading text keyline. Static copy inherits its inset
  from the group; already-padded control labels consume it instead of doubling it.
  `illustratedContent()` selects that layout for single-group form rows. Ordinary
  row separators leave 8pt clear of focus on each side; root category separators
  align with the labels rather than extending under their icons.
  Compact About community cards keep their QR codes beside wrapping captions and
  share one equal-height row; mobile and expanded community layouts are unchanged.
- **SDH subtitles** is a profile-scoped playback preference, available even
  without a subtitle-download provider. TV uses the shared whole-row menu in Subtitles;
  mobile includes it in Subtitles > Behavior. Prefer SDH permits regular-subtitle
  fallback; Only SDH does not. The same saved preference also filters searches.
- **iCloud Sync > Troubleshooting** remains reachable with sync off. The grouped
  breakdown is an on-demand local-ledger snapshot of encoded payload bytes and
  record counts, not an iCloud quota or network-usage measurement. Pending uploads
  are included, pending deletions are counted separately, and separately managed
  iCloud Keychain/Trakt authorization data is explicitly excluded.
  **Erase Sync Data** needs no Developer Mode. A compact, single-title shared dialog
  separates iCloud data, local data, and unaffected media, with native buttons
  for its standalone actions. tvOS presents from the app root to avoid contested
  nested Settings modal hosts; mobile uses the shared sheet. Choose **Erase Sync Data…**,
  then confirm the native destructive alert. Cancellation at either
  step does nothing. Kids profiles cannot execute it, including after a profile
  switch. Erasure drains the sync engine, switches sync off, enumerates all
  configured server zones (including unmirrored and direct tracker records),
  checks every deletion and verifies emptiness before resetting local profiles
  and servers. In-flight Trakt exchanges are drained and their local replay state
  retired before remote deletion, including already-cancelled exchanges.
  Sync cannot be re-enabled while recovery is still running.
  Failures remain failures, even after a partial erase; no automatic reseed follows.
  Other devices must stop syncing to avoid republishing. Apple TV cannot remove
  server logins from iCloud Keychain; the review page directs that step to mobile.
- `ProfileDetailView` — manage the active profile: rename, recolor,
  switch / sign out of accounts, configure the Plex Home-user mapping
  (`PlexLinkedUserDetailView`).
- `ServerDetailView` + `ServersAndLibrariesDetailView` — manage stored
  household servers / accounts (`AccountStore`) and remove accounts.
  `MyLibrariesDetailView` owns the active profile's server-user and library choices.
  On TV, each enabled media-share section shows its own compact update phase,
  progress bar and known percentage. Only accounts included in the current
  profile contribute; idle, excluded and removed shares show no status. Progress
  observation stays in that small row, not the Settings workspace. Other Settings
  categories no longer carry a global scan card; mobile and browsing banners
  retain their existing behavior.
- `IntegrationsDetailView` — "Trackers" page: connect/disconnect for Trakt,
  Simkl, AniList & MyAnimeList (delegates to each tracker service) plus the
  Watch Status across-servers sync toggle.
- `PreferenceDetailViews` — subtitle behaviour / spoiler / diagnostics /
  Home-customization preferences. Subtitle *behaviour* (mode, language,
  auto-download) lives here; the subtitle *look* is now adjusted in the
  player while watching.
- **Send Diagnostics** on TV and mobile uses the existing crash-reporting consent.
  The setting is labeled **Share Diagnostics** because it covers more than crashes.
  When sharing is off, the native **Enable Sharing** action opens the existing
  consent prompt; confirming only enables sharing, without submitting or clearing
  the message. Declining or dismissing does not enable sharing. Unconfigured builds
  explain their limitation and cannot offer an opt-in action.
  Detailed automatic/manual data disclosures and the privacy policy are behind
  the native information button, which remains available while Send is disabled.
  The main page retains only the message privacy reminder and actionable states.
  Send uses native button/disabled styling and remains disabled until a nonblank
  message is entered. The shared submission
  path also rejects missing or whitespace-only messages before collecting or
  submitting any diagnostics; automatic crash reports are unchanged.
  Each submission appears in Sentry's User Feedback inbox with the required message,
  linked to the diagnostic event in Issues and its `plozz-diagnostics.json`
  attachment. No name or email is collected. The privacy filter retains only the
  feedback message, custom source,
  and valid associated event ID, not identity or arbitrary feedback fields.
  Success means SDK handoff, not server acknowledgment; inactive reporting or a
  rejected event returns failure. Feedback is not submitted when its diagnostic
  event is rejected. Both events pass through the same privacy hook before upload.
- `HeroCollectionPickerView` — Home's opt-in **Collections** hero source
  chooses multiple collections across enabled movie and TV libraries, or from accounts'
  personal collections when its provider advertises that capability. The native picker
  is shared by TV, iPhone and iPad, scopes requests to the active account and
  server viewer, and loads collection pages only while open. Errors retain
  loaded rows and expose Retry. TV reuses the settings detail-page scroll layout,
  local header, native Back and wrapping checkable source rows rather than a
  full-page List or automatic segmented Picker. Mobile retains grouped native
  navigation. Choosing a collection toggles only that selection; switching sources
  retains other selections. Selected rows show their source and can be removed
  individually, including when a source is unavailable. Choice identity includes
  account, optional library, server viewer and collection, not the display name.
  The account/optional-library/collection selections stay
  in the profile's `HeroSettings` blob and travels with existing profile
  transfer/sync; older single-selection blobs migrate to a one-element array,
  and unavailable sources do not silently erase saved choices.
- `SettingsAboutSection` — app identity / version / release notes.
- `SettingsCommunityLinks` — separate Discord-first and GitHub cards shared by
  About and mobile Settings. Apple TV shows them below the app identity.
  Mobile uses one shared Community section with full-wordmark direct links and
  expandable QR cards: directly above Support in compact iPhone Settings,
  and on the About page in regular-width layouts. The cards use
  official icon-and-wordmark lockups directly on their surfaces, without colored
  icon tiles or duplicate name labels. They follow the theme's primary text color
  and stay outside the codes' white scan margins. Narrow layouts stack without
  shrinking the codes. Public destinations are centralized in `CoreModels.AppLinks`.
  `SettingsCommunityLogo` balances both brands by visible ink area rather than
  equal height: Discord renders at 75% of GitHub's height, with each original
  aspect ratio preserved. A common layout height keeps caption baselines aligned
  on TV and mobile; hosted coverage compares the rendered areas at both sizes.
  Lockup sources are from [Discord](https://discord.com/branding) and
  [GitHub](https://brand.github.com/foundations/logo); original SVGs are in
  `docs/assets/{discord,github}-lockup.svg`. The marks and lockups live in
  `App/Resources/CommunityAssets.xcassets`, linked by both app targets and their
  presentation-test hosts; platform-only catalogs must not own shared logos.
  Their vector PDF exports use CairoSVG
  with `dpi=72` so source units map to PDF points without fractional-height
  rounding by the asset compiler:
  `python3 -c "import cairosvg; cairosvg.svg2pdf(url='docs/assets/discord-lockup.svg', dpi=72, write_to='App/Resources/CommunityAssets.xcassets/DiscordLockup.imageset/discord_lockup.pdf')"`
  (substitute `github` / `GitHubLockup` for the GitHub export).
  The Discord mark comes from [Simple Icons](https://simpleicons.org/) (CC0).
  Its original path is in `docs/assets/discord-mark.svg`; the asset catalog uses
  a vector PDF because Xcode's SVG renderer distorts this path's compact arcs.
  Regenerate it with
  `python3 -c "import cairosvg; cairosvg.svg2pdf(url='docs/assets/discord-mark.svg', write_to='App/Resources/CommunityAssets.xcassets/DiscordMark.imageset/discord_mark.pdf')"`.

## Invariants

- **Settings surfaces.** Read-only focusable panels use the same adaptive
  gradient surface as ordinary groups, including the opaque Reduce Transparency
  fallback. Their native focus behavior stays unchanged.
- **TV navigation ownership.** Focusing a category selects its row; Select
  or Right opens the equally sized category page.
  Back pops a child, then returns to categories, then focuses app navigation.
  MainTabView presents the workspace as a normal destination in all three shells.
  Categories and nested pages report their full page depth, including return
  transitions, to custom chrome. Native Sidebar uses a full-screen subpage stack
  because its indicator ignores toolbar visibility; dismissal restores category
  focus after the native presentation completes. Root categories keep navigation available.
  Changing navigation style retains the mounted shell, Settings section and typed
  child path throughout the Settings visit; the new chrome takes effect on exit.
  Settings columns remain centered and subpage headers keep their full-height
  layout; only root foreground reserves space below the top bar.
  That reservation remains constant while subpages cover the retained root, so
  its scroll viewport and offset do not change as navigation hides or returns.
  Settings pages retain their horizontal slide/fade transitions without resizing
  their scroll viewports. Parent pages retain their scroll positions and return
  focus to the originating row. Navigation chrome animates independently, only
  while visible.
  The top bar scrolls away with root content, without a foreground fade.
  Root Back restores the page top and navigation; subpage Back remains one level.
  The profile action reserves a stable 100-point height: native focus shifts the
  name upward and reveals "Switch profile" below it at the normal helper size.
  The avatar, Edit action, and following rows stay anchored; Reduce Motion
  removes the text movement animation.
  Focus requests are separate from native focus arrival: competing controls stay
  gated until `NativeFocusRegionObserver` confirms ownership.
- **Profile and parental scope.** Switching profile or changing Kids/PIN status
  resets the workspace. Parental unlock proof is tied to the active profile and
  current PIN verifier, not a persistent boolean. Route rendering enforces the
  same restrictions as category visibility, including artwork/metadata cross-links.
  A PIN unlock opens the selected protected pane in place; it must not dismiss
  Settings. Kids without a household PIN retain their simplified, unsealed setup.
  Mobile keeps its existing Settings navigation and control layouts.
- **Review capture.** `SettingsWorkspaceRemoteTests` is opt-in through
  `PLOZZ_SETTINGS_REVIEW=1` and runs only against the real app on an explicitly
  owned simulator. The DEBUG-only `PLOZZ_SHOTS_SETTINGS=1` launch fixture uses
  fictional Alex/Sam profiles. `PLOZZ_SHOTS_SETTINGS_NAVIGATION` chooses the
  initial navigation style; `PLOZZ_SHOTS_SETTINGS_KIDS` configures the test child
  as `off`, `no-pin`, or `pin`. These fixtures are never enabled on physical TVs
  or normal launches. Attachments include native screenshots and accessibility
  trees, not browser mockups.

- **Shared TV control scale.** Tri-state segments, reorder labels, compact preview-card
  captions, and form controls use `SettingsRowMetrics.titleFont`. Feature and group
  descriptions share the smaller `descriptionFont`. Segmented tracks and single-line
  reorder rows match the shared primary control height. Only the selected segment
  makes room for a checkmark; that space animates between options without padding
  unselected labels. Focus still only previews an option: Select commits it.
  Reorder lift/drop behavior and mobile sizing are unchanged.
  Checkable choices (including Artwork presets), option chips, stepper values, and
  navigation labels consume the same title token; inline explanations use the
  description token. Checklists and segments share `SettingsCheckmark`, rather than
  styling separate oversized selection indicators. Rank columns reserve the largest
  enabled number using monospaced digits, including lists with 20 or more items.
- **Artwork and label presets.** Choosing any preset, including reselecting the
  previous one, replaces the whole configuration through `applyPreset`. Editing
  a view switches to Custom: no preset is selected, and a single badge appears on
  "Customize by view". `selectedPreset` derives this status from existing stored
  overrides; the backing preference retains unedited views' behavior, including
  mixed recommended rules. Settings remain in the existing profile store and sync
  payload; artwork's `scopeVersion` migrates earlier shared choices once.
  Matching a preset's value manually stays Custom; choosing a preset replaces all
  overrides. Rows show a name and short value: Library / Metadata providers, or
  On / Off. Only title-detail artwork and Home/Recommended labels also offer
  Mixed: metadata backgrounds/logos with library posters, or labels except in
  Showcase/on series artwork, respectively. Mixed is an explicit, persisted
  per-view choice independent of the backing preset. TV Select cycles the same
  supported choices as the mobile menus, with focused explanatory artwork.
  On iPhone/iPad, a chevron-marked value control opens a native checked menu:
  opening or dismissing it never changes settings. It checks the effective
  value, without an extra default/inheritance option. Presets reset the entire
  configuration, including explicit Mixed choices. The mobile Artwork page
  places its heading outside the three-preset group and customization in its
  own group below.
  Mobile customization pages use inset grouped rows on an opaque theme-aware
  background, not the ambient gradient. Only the value opens the menu; the view
  label stays in the row while the menu shows choices without a repeated title.
  Accessibility hints retain explanations without repetitive row descriptions. Mixed labels in
  Home and library Recommended retain their Showcase/title-artwork rules until
  edited. Long values and accessibility text sizes stack instead of clipping.
  Both lists group library tabs under "Libraries". Artwork separates Home's
  Showcase/hero from other Home rows, and library Recommended's hero (TV only)
  from its rows. Browse, Collections, and Playlists have independent choices;
  titles inside collections/playlists use Browse. Continue Watching rows share
  one choice across Home and libraries, independent of the series-artwork option.
  Watchlist means the standalone page, not Home's Watchlist row. Episode browser
  means detail-page episode cards; Video player artwork covers player menus,
  Up Next, and system Now Playing. Shared view components retain these scopes
  rather than treating a common layout as a shared preference.
  Labels retain equal-height visual presets: App default uses a single split illustration with
  caption bars on only one half. Show labels everywhere and Hide labels everywhere
  govern all media captions; App default owns Showcase and title-artwork exceptions.
  Explicit per-view choices, including Episodes, last until a preset replaces them.
  Home's Libraries row has a Use default / On / Off override alongside Continue Watching.
  Use default inherits Home's label setting, including Showcase; explicit choices
  affect only the Home library-card caption, not the library directory. Library-directory
  captions continue to follow the global preset. All label editors place page defaults
  first, then the live preview, then any Overrides section on TV and mobile. Library
  names in navigation bars, sidebars, menus, and on-artwork information remain visible.
  Per-view help states whether labels are visible or hidden; Mixed explains
  the Showcase and series-artwork exceptions. It follows the focused setting
  and updates when that setting changes.
  TV customization pages share the same scrolling Back control and title.
  Their scroll content can cross the top safe-area inset without a hard crop;
  a scroll-dependent fade handles the outer edge. Neither Back nor the title
  is pinned. Pages without contextual help also draw through the bottom safe
  area to the screen edge; pages with a fixed help footer retain its clearance.
- **Scoped TV detail navigation.** `SettingsDetailPages` and `SettingsDetailLink`
  in `SettingsDetailNavigation.swift` are reusable across settings, independent of
  artwork and labels. A `SettingsSplitRow` opts in with `SettingsDetailSubpage`;
  use `SettingsDetailLink` inside its root content to open that child. Outside a
  scoped pane, the link uses ordinary navigation. Both pages slide by the pane's
  full width: the root leaves toward the leading edge as the child enters from
  the trailing edge, and Back reverses both motions. The root stays mounted to
  preserve state and scroll position; it becomes ineligible for input while away.
  The sidebar stays stationary. Entry transfers native focus to the first row;
  Back restores the originating link after removal completes. Stale completions
  are invalidated when changing the selected sidebar page. Left remains available
  for sidebar navigation, RTL mirrors the motion, and Reduce Motion disables it.
  The slide mask contains horizontal overflow but extends through the vertical
  safe area, preserving native scroll rendering at the pane's top and bottom.
  Do not clip the safe-area frame on both axes: it cuts preview cards off above
  the panel's lower edge.
  Child content chooses its initial native focus target and calls
  `SettingsDetailNavigation.focusArrived()` when that control receives focus.
  Customization lists and their inset contextual cards occupy separate regions.
  Larger 16:9 illustrations highlight only the affected artwork, beside one sentence
  of help; full-page outlines sit inside the preview's rounded corners rather than
  being clipped by its mask. Scoped label illustrations show tightly packed media
  rows or a two-row grid, using the live card sizes, spacing, frame insets, and
  Continue Watching aspect ratios. Row headings stay native text, including in RTL;
  grid pages do not repeat invented section headings. Hidden labels disappear rather
  than leaving dashed bars, and framing ends at the artwork when labels are off.
  The all-page label presets retain the single-card comparison swatch. Navigation follows the active
  profile, including native sidebar, pinned rail, and top-tab differences. Ordinary
  title rows use 2:3 posters; episode/player thumbnails use their landscape ratios.
  Home follows the active Fullscreen Hero/Showcase layout, including disabled heroes;
  Continue Watching uses its actual thumbnail or extended series-artwork shape.
  The shared title-detail choice shows separate movie and show layouts: show episodes
  stay muted because the episode choice owns those images. Extras and cast photos
  are not promised a title-level source replacement. Keep the card and viewport
  stable as focus or values change, with no extra focus stop or content behind
  the card. A smooth 40-point bottom fade and matching scroll clearance keep focused
  rows above the fade. Lists without help reserve no footer. Horizontal pane-level
  transition clipping remains. Artwork values use "Library" and "Metadata providers", with "Mixed" for
  Recommended title details (metadata-provider heroes and library-first related posters); narrow/mobile
  and accessibility layouts stack the complete value rather than abbreviating it.
- **Profile Seerr setup uses page gutters, not artwork padding.** On iPhone/iPad,
  `ProfileSeerrSetupView` uses `SettingsPageScroll` and a centered, at-most
  720-point column. Its noninteractive profile chip uses `ProfileAvatarView`
  for the real photo, emoji, or symbol and wraps below the heading when needed.
  Panel rows and footers share one inner inset. Actions fill
  the column and stack at accessibility text sizes; long profile/user names
  wrap without widening the scroll content. TV retains its bounded settings
  layout with contained row focus.
- **Mobile Settings is a presentation action.** The profile button is the default
  entry point. Its navigation shortcut starts hidden on iPhone and iPad, keeping
  the default navigation at Home, Downloads, and Search.
  The arranger can explicitly Show it; this profile-scoped override survives
  relaunches, while Reset Navigation restores the hidden default. Automatic
  hiding is not saved as a manual preference and does not hide Settings on TV.
  Its optional tab or More entry opens
  the drawer over the current page without selecting a replacement destination.
  Keep the active content stack and overflow navigation intact on dismissal;
  destination normalization still retains the Settings-only recovery screen.
  The native tab delegate must reject the Settings transition before UIKit
  changes navigation insets; declining only the SwiftUI selection binding can
  move a scrolled page. Forward other delegate callbacks and restore the prior
  delegate when the action bridge is removed.
  Replacement bridges take over the original delegate directly rather than
  chaining through an older bridge; overlapping SwiftUI lifetimes must not
  create a forwarding cycle or let a removed bridge uninstall its replacement.
- **Automatic iCloud sync.** The main sync page does not show a separate Live TV
  explanation panel. Recovery lives in Troubleshooting, with a warning above
  Reload and Reset explaining that neither is normally needed. Both platforms
  use the shared transient-status presenter for progress and the actual result,
  and disable both actions while either is running. Reset still requires
  confirmation. Pending Live TV source repair rows remain in Troubleshooting.
- **Profile-namespaced settings.** Per-user prefs (theme, captions,
  diagnostics, spoiler) are namespaced by the active profile id; the
  default profile uses no suffix so an upgrading install keeps existing
  values (`migrateLegacyIfNeeded` in `ProfileStore`).
- **No tokens here.** Account & Trakt token management is delegated to
  `FeatureAuth.AccountStore` / `TraktService.TraktTokenStore`.
- **Dual-provider.** Server/library management must work for both Plex
  and Jellyfin accounts (Plex Home-user mapping is Plex-specific, but
  the UI must clearly say so).
- **No persistence schema duplication.** Persistence lives in
  `CoreModels` / `FeatureAuth` / `TraktService`; this module only
  **edits** what they store.

## Where to look first

- `SettingsView.swift` — the row composition (the tree of detail pages).
- `ProfileDetailView.swift` — profile-scoped editing.
- `PreferenceDetailViews.swift` — caption / spoiler / diagnostics prefs.
