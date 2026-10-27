# CoreUI

Shared, **focusable** UI primitives, the app theme, and the artwork image
cache that every feature module reuses on tvOS and iOS/iPadOS — guarded behind
`#if canImport(SwiftUI)` so the package still compiles on Linux for tests.

## Responsibility

`ServerUserRow` keeps the user's name above its owner/PIN metadata. The metadata
wraps independently, preserving the avatar, native focus treatment, and trailing
selection indicator without squeezing the name alongside badges.

`PlozzTypography` owns semantic text metrics, including additional line spacing,
and composes local adjustments with `plozzAppTextScale` once at a surface boundary.
SwiftUI text and the UIKit Home foreground resolve the same styles; badge children
receive the resolved `metadataTextScale`, not another multiplier. Episode captions,
loading placeholders, and the Detail preview use the same episode styles.
Persisted preferences remain raw `CoreModels/HeroTextSize` values, not point sizes.
The app multiplier currently defaults to 1 and has no settings UI. A future
app-wide preference can supply it at the root while additional surfaces adopt
semantic styles; unmigrated app text is not implicitly covered.

`HeroDescriptionFactsLayout` measures the live facts row during layout and gives
its description the same reading width, with an 800pt baseline and 1200pt cap.
The Detail hero reserves the separate credits column before proposing this width.
Changes to badges, text size, or the focused episode remeasure in the same pass,
without geometry state or an extra hidden copy of the badge views.

`ActionProgressIcon` overlays native progress inside the original symbol's
layout footprint. `PlayResumeButtonLabel.isLoading` uses it without changing the
button's dimensions or the existing resume/placeholder layout.

`TrailerActionButtonLabel` always renders icon-only on TV and mobile, preserving
the destination description for accessibility regardless of available width.
`TrailerActionIcon` keeps the film symbol for server files and adds a small
outgoing arrow for external YouTube links. The arrow's surrounding stroke removes
symbol pixels transparently, rather than painting a badge or background color,
so native glass, focus, light/dark appearances, and reduced transparency still
come from the existing button styles.

The tvOS detail entrance checks cancellation after every timed reveal. A sleep
that expired before cancellation can still be waiting for the main actor; it
must not overwrite a finished entrance and hide already-visible controls.

`SettingsCheckableRow` is shared by Settings and channel-library selection.
Its prominence controls the common row metrics; `.contained` keeps focus inside
a grouped surface. `SettingsFormButtonStyle` supplies the matching action/menu
height, while `SettingsMenuLabel` and `SettingsDisclosureLabel` remain padding-free.
`SettingsPageSurface` applies the palette's neutral control tint to mobile settings
pages, including standalone destinations. Native switches retain their green on
state. Custom-icon `SettingsRowLabel` callers can supply content insets when their
group already owns the outer spacing.
Default `SettingsRowLabel` labels reuse `settingsFormRowLayout()` on TV, so
single-line navigation, menus, and form controls share their minimum height and
interior padding. Explicit content insets retain compact source-row sizing.
Padding-free disclosure labels and bare form actions use `SettingsFormButtonStyle`,
which puts the shared minimum height and padding inside the TV focus fill.
`SettingsFocusButtonStyle` is only for labels that already supply their own
control geometry. Standalone and inline actions use `plozzActionButton`; do not
use a text-height focus strip as a smaller action-button variant.
The text-height disclosure-row treatment is deprecated: never apply
`SettingsFocusButtonStyle` directly to a compact label such as
`HomeEditorRowLabel`. Use a full-row wrapper such as `HomeEditorLink`, or a
padding-free disclosure label with `SettingsFormButtonStyle`. Padding outside
the button's focus fill does not replace its required internal row geometry.

`SettingsPageHeader` accepts a trailing native action for page-scoped commands.
Keep it in the header's full-width focus section and scroll the header with the
page; do not add a separate action strip or shrink the native button.

`SettingsStepper` retains every adjustment stop while limiting dense range tracks
to 21 visual ticks. `ThemeMusicPreviewControlling` is the Settings-to-runtime
preview seam; it carries ownership, availability, and errors without coupling
Settings to the Home feature or a concrete audio player.
The shared TV adjustment scope defaults to its standard hold-repeat speed.
`settingsAdjustmentRepeatSpeed` lets dense percentage controls opt into faster
repeat without changing their single-press increment or other settings controls.

`ChannelLogoArtwork` renders generated Plozz channels with the shared Byline
layout: a name-first title and inset pixel-mascot signature. Its optional
`LibraryChannelArtworkMood` comes from channel rules, not display-name guessing.
Category tint blends over `themePalette.cardOpaqueSurface`, so Light, Dark,
and Black keep their own brightness and foreground contrast. Supplied logos
always retain precedence; external channels keep the ordinary name fallback.

`PlozzStartupLogo` starts from a smile and rotates through wink, delight, and
surprise on successive cold launches. The device-local choice is saved once per
process when animation first becomes active; view remounts and foreground
transitions reuse it. Reduce Motion leaves the smile and does not advance the
rotation. Each selected expression begins at 0.25 seconds and reports intro completion
from the animation timeline at 0.7 seconds. The optional completion is one-shot,
does not advance in inactive scenes, and fires immediately with Reduce Motion.
The shell may retain the launch presentation for that intro without delaying
startup work. Longer loading keeps the existing eight-second expression loop.

Loading placeholders share `shimmering()`. Its static gradient band is rasterized
before the animated translation, avoiding repeated gradient work without
rasterizing the placeholder content or changing the sweep, masking, or intensity.
Inactive placeholders remain unmodified; Reduce Motion retains the static dim.
The simulator lab's `skeletons-idle` and `skeletons-static` scenarios isolate this
cost from loaded cards and network/provider work.

Loading jokes wait 11 seconds before appearing by default, then retain their
5.5-second cadence. `LoadingMessagesView` and the model share the sequencer's
default delay; individual callers can still supply an explicit grace period.

Continue Watching's profile-scoped Playback details choice applies to Artwork + logo,
Thumbnail, and Poster, on Home and library rows.
Detailed keeps the existing play/progress/text overlay; Progress only uses the
shared white progress bar without that overlay. Other cards are unaffected.
The previously stored portrait-only preference is retained.

`MediaRowView.onPlay` optionally gives each media card a tvOS Play/Pause shortcut,
independent of Select and without preparing a detail transition. Home Continue
Watching supplies its existing playback callback for either selection preference.
Other rows, loading placeholders and Live TV cards retain their own behavior.

Continue Watching portrait cards reuse `PosterCardView` at ordinary 2:3 poster
dimensions. Detailed starts with the complete poster above a bottom reflection 10% of
the fitted picture's height, filling the narrow left/right gaps with mirrored
poster edges rather than cropping or stretching the artwork. The side reflections
gradually soften outward; the bottom band retains its progressive blur as it
darkens. The complete original poster stays sharp. Blur input is bounded to each
reflection band plus its filter margin instead of filtering full-size posters.
Native TV fits only reflection copies to display resolution before rendering,
leaving the sharp central poster's original source untouched. It caches the
finished artwork, including the reserved band and blur treatment in the cache
identity; Reduce Transparency retains the unblurred fallback. Landscape reflection
is unchanged. Nonstandard poster ratios use the same centered aspect-fill crop
for the visible picture and reflected edges; the picture cannot overdraw the
side bands. Native preparation and unclipped composition fill their complete
pixel allocation at fractional card sizes without changing the card's layout.
Progress only uses the ordinary 2:3 poster and existing
`MediaCardPlaybackIndicators` white bar, including shared thickness, focus,
insets, watch-state rules and download badges; it does not create another bar style.
The shared indicator falls back to the existing resume fraction when the provider
omits a percentage, so switching treatments does not lose known progress.
They resolve movie or series posters, never episode stills or textless backdrops.
Portrait uses zero side crop, no duplicate logo or logo dimming. Detailed keeps
the landscape Continue Watching scrim's start, easing and depth; the slight
reflection blur is additional, not a replacement for that scrim.
Progress only uses the shared bar's scrim.
Artwork-source preferences still apply.
Native TV bitmaps, SwiftUI cards, previews, and loading placeholders share this
selected shape. Detailed tightens only the shared chip's horizontal spacing,
preserving episode/time details and the progress/download elements in its narrower
slot. Its outer insets are even and match landscape Continue Watching; compact
spacing between controls does not reduce the leading edge inset.
On iOS/iPadOS, a constrained Detailed portrait chip drops the play glyph first,
then the progress bar, before reducing its text by at most 15%. Episode and time
text stays complete; exceptionally narrow cards or large accessibility type wrap
the text instead of truncating it. Download status keeps its trailing position.
At accessibility text sizes it occupies its own bottom-trailing line rather than
squeezing the episode/time column.
Mobile cards and their Settings previews reserve the measured playback block's
height in the reflection, capped at 30% of the artwork slot so the poster remains
dominant. The outer 2:3 dimensions never change. Extreme accessibility text may
extend above that cap rather than shrinking the picture to half the card.
TV and non-portrait chips retain their existing layout.
All three artwork styles share the existing Continue Watching caption override,
inheriting the row's Home or Recommended choice unless explicitly shown/hidden.
Its original portrait preference is retained. Settings previews resolve this
same choice for each style, including Showcase inheritance, and keep artwork
geometry stable when their caption lines appear or disappear.
`plozzContinueWatchingPlaybackDetails` carries the active profile's choice through
both app roots and native hosting boundaries without changing non-Continue-Watching cards.

Full-width card progress bars use `PlozzMetrics.resumeChipBarHeight`, matching
Detailed without changing it: 8 pt on TV and 6 pt on mobile at standard settings.
Density, Dynamic Type, and the minimum height follow the same shared metric.

- **Version choices** — `MediaVersionChoiceButton` is the shared native rounded
  card for pre-play, detail, and in-player pickers. It keeps edition/size and
  release text above the wrapping format/language badges, with one
  trailing selected checkmark. Hosts retain selection, dismissal, and focus
  ownership. `MediaVersionPicker` supplies the sheet used by mobile playback
  and hero context-menu actions; context menus link to it rather than rendering
  a second text-only version list.
  On iOS/iPadOS, version sheets use an inline centered navigation title and a
  leading native X close action, with no bottom Cancel button. The pre-play X
  cancels the pending playback choice; tvOS retains its existing dialog controls.
  TV version cards enlarge their format/language marks for viewing at a distance;
  marks use a 1.7 container scale and 12-point gaps, while mobile keeps its compact
  scale and spacing. The TV source menu gives its version page an 800-point width
  and up to 820 points of height, bounded inside the screen. Each TV menu page owns
  its native scroll state so Back from a long list restores visible root actions.
  The TV pre-play heading uses the compact
  34-point semibold dialog treatment, scaled with the headline text style, rather
  than the oversized native TV title.
  Edition/size, source quality, bitrate and runtime share one naturally wrapping
  summary instead of separate size-only or runtime-only rows on either platform.
  Release filenames preserve their original script and wrap to their full height,
  including at accessibility text sizes; they have no two-line truncation cap.
  Display-only break opportunities after dots/underscores prevent an orphaned
  `Spider-` prefix. Stored filenames and accessibility labels remain unchanged.
  Language chips prioritize the profile's explicit audio language, or the device
  language when no explicit preference is set. Only reported matches move first;
  otherwise the source order stays unchanged. The additional-language count stays
  inside the same chip (`English | +9`), so it cannot wrap away from its language
  or look like hidden format badges. Accessibility exposes the full language list.
  For a two-language source, an inline badge stays compact; if the format row
  cannot fit it, the language row spells out both names. Very large text may
  separate those names into wrapping chips instead of clipping either one.
  Adaptive hero rows own `PlaybackSourceMenuState` and its presentation above
  `ViewThatFits`; candidate rows contain only triggers. Late trailer, action or
  inventory updates can rearrange the row without destroying an open version page.
  An optional `MediaVersionInventoryLoader` keeps lazy sources discoverable even
  with no cached alternatives. Only a mounted version page/sheet starts discovery,
  not the overflow root or focus changes. Shared loading/error/Retry content
  never starts playback or retries automatically. Loader identity fences retained
  choices across owner, account and playable-target changes; dismissal cancels
  the reader, not any server work already admitted by its provider.
  `NoStreamsButtonLabel` reserves its single-line width before actions overflow.
  Only the final stacked layout can scale it to fit; the retry spinner occupies
  the same 20-point icon slot and uses explicit contrast for the button surface.
  The full track inventory stays in the Audio menu;
  this display priority never changes playback's original/per-content-type policy.
  The compact mobile source-menu disclosure groups edition/picture facts above
  quieter source/size facts. Each group stays inline only while it fits; narrower
  widths and larger text stack complete facts with leading alignment, without
  dangling separators or truncating the selected version's accessible summary.
  At accessibility sizes, the category and chevron sit above the full-width
  summary; the decorative film icon yields its space to readable text.

- **Reorder-only lists** — `LiftableReorderList(allowsHiding: false)` presents
  enabled entries only and keeps them enabled through native dragging, remote
  lift-and-move and context-menu movement. It has no Hidden divider or Hide/Show
  actions. Existing callers keep the reorder-and-hide behavior by default.
  Rows can opt into `providerMarkInSubtitle` to place their provider/transport
  mark beside the secondary source name; other callers retain leading marks.
  Menu edge moves stay within the item's current section and preserve peer order.
  Hosts may provide removal independently of the Hidden divider.
  TV lift-and-move uses the vertical axis of `SettingsAdjustmentFocusScope`,
  retaining the native focus item instead of inferring direction from neighboring
  focus changes. Press repetition stops on release, focus loss, screen changes,
  dismissal, or app deactivation; ordinary navigation remains native when dropped.

- **Settings icon columns** — `SettingsRowLabel` reserves one icon column on TV.
  Grouped `Label` controls use `SettingsIconLabelStyle` with a shared,
  Dynamic Type-scaled column, so wide symbols cannot shift neighboring titles.
  Both keep icons centered and text leading-aligned in either layout direction.

- **Recovery screens** — `RecoveryScreen` supplies the bounded, vertically
  centered, scrolling card and adaptive horizontal/vertical action layout used by
  playback failures and account recovery. Hosts supply the heading and native
  actions, and retain ownership of theme, focus, retry and dismissal.
- **Playback failures** — `PlaybackFailureView` uses that shared TV/mobile
  layout with a bounded symbol inline with the heading, readable summary, adaptive
  native actions and optional Details sheet. Hosts own retry and dismissal; the error surface owns
  its dark palette without changing browsing themes. Its opaque themed surface
  stays legible over video without depending on glass or motion.
  `PlaybackDiagnosticDetailsView` is shared by on-demand playback, Live TV and
  IPTV setup. It renders and shares only the structured `PlaybackDiagnosticReport`,
  including app/OS identity; it is not the continuously sampled diagnostics HUD.
  Library recommendation and browse failures reuse this sheet through `ContentFailureActions`
  and `ContentStateView.errorReport`. Their structured report identifies failed
  sections and safe response-decoding/paging/transport facts while retaining browsing themes and
  already-loaded content; no playback-specific full-screen chrome is imposed.
  On iPhone and iPad, every diagnostic sheet uses a centered native inline
  "Details" title and a leading icon-only Close button, including the Live TV
  guide's diagnostics destination. tvOS retains its existing heading and Done action.

- **Touch hero actions** — `HeroActionRow` preserves readable intrinsic widths
  before falling back to a vertical arrangement. `TouchHeroActionButtonStyle`
  lets labels wrap and uses bounded 24pt corners so tall accessibility-size
  content stays inside the button surface. Circular actions retain their 48pt
  touch targets and cap glyph scaling at XXX Large; text buttons continue to
  honor the full accessibility text size.

- **Portrait mobile hero artwork** — `HeroStageMetrics` reserves 24pt at the
  top for a softly faded reflection, shifting the original artwork below more
  of the status-bar chrome without moving metadata or growing the hero.
  Home and Details share this still-image layout, including swipe reflections.
  The bottom reflection and minimum dissolve span remain intact; trailers keep
  their full-stage presentation. Landscape and tvOS heroes are unchanged.

- **Setup presentation** — `ConnectionCodeView` shares the readable monospaced
  code panel across server sign-in and device pairing. `SetupCodeComparisonView`
  keeps both devices' confirmation copy and code treatment consistent while
  callers retain confirmation and cancellation ownership. `SetupSectionCard`
  groups methods and counted summaries without styling native controls.
  `SetupSummaryView` scrolls the heading, full server names, and supplied profile
  grid while keeping Done/Continue reachable. TV rows and profile tiles provide
  native focus targets so the remote can reach long summaries. TV summaries scroll
  to the page's top edge, with initial header spacing inside the scroll content
  rather than an inset clipping boundary. `VerticalEdgeFadeMask` softens only the
  bottom above the fixed action while more content remains; the final rows stay
  undimmed at the end.

- **Reduce Motion** — `ReducedMotion` suppresses explicit and implicit SwiftUI
  animations at the TV app root without removing layout offsets or replacing
  view identity. Native hero artwork uses a crossfade instead of a parallax wipe;
  changing the system preference finishes an in-flight wipe. Timeline-driven
  liquid backgrounds and player-menu marquees also stop their decorative motion.
  Native focus feedback and meaningful playback/countdown progress remain available.

- **First-use choices** — `FirstUseChoiceView` shares the Live TV preview and
  playback-version introduction heading, native actions, and Settings reminder.
  Hosts own persistence and cancellation; dismissing a version prompt never
  records a mode. Mobile uses a vertically stacked, scrolling adaptation.

- **Settings row typography** — `SettingsRowMetrics.titleFont` is the shared
  body-size label for navigation rows, TV switch variants, and labeled controls.
  Keep headings separate; do not give toggles a larger headline font or add
  per-screen compensating font overrides. Native iOS/iPadOS switches retain
  system sizing. TV option/segmented pickers use the same body-sized labels;
  `settingsHelperText()` uses the smaller caption size for explanatory copy
  (tvOS footnote and body render at the same size).
- **Settings form geometry** — `settingsFormRowLayout()` gives links, On/Off
  rows, and compact inline steppers the same content padding and minimum height.
  TV form groups use a uniform 16pt focus inset. The contained focus radius is
  the 28pt group radius minus that inset (12pt), including illustrated groups.
  Headings, compact labels, helper copy and ordinary dividers share the control
  text keyline: 16pt group inset plus 12pt row padding. Groups provide
  `settingsFormTextInset`; `settingsFormTextLayout()` consumes it for static
  content, while padded focus-row labels reset it to prevent double insets.
  Outside a grouped form the text helpers add no padding. Legacy uncontained
  checkmark groups retain their separate focus-bleed geometry.
  Standalone page links use the `.navigation` row role: idle and focused surfaces
  both read the same 28pt radius, with no focus bleed or corner tightening.
  Adjacent page links have an 8pt gap; separate control sections keep their larger gap.
  Page titles and Back belong inside the scrolling content, not in a fixed
  header strip that shortens the viewport. `SettingsPageHeader` supplies their
  horizontal Back/title layout, not a separate pinned container. `SettingsBackButton`
  shows only the backward chevron in the shared native button, retaining the
  localized Back accessibility label. Callers retain navigation and focus
  ownership. The full-width header is a native focus section, so Up from
  right-aligned controls can reach the leading Back button. The full-screen subtitle editor is
  an explicit exception: its stationary heading sits above a scrolling tool pane.
  TV Settings categories and descendants share the centered
  `SettingsFormMetrics.pageWidth`. `SettingsPageStack` keeps that width throughout
  navigation; only explicitly full-width destinations use the whole viewport.
- **Settings page navigation** — the TV workspace uses `SettingsPageStack` for
  the retained category list and its equally sized child pages. Only the current page owns input,
  accessibility and Back; a pop restores the originating link's focus after the
  shared 420ms eased fade with 64pt directional travel, rather than crossing the
  screen. Retained parents and inserted children use the same motion and keep
  their final layout sizes throughout. Input and native entry/return focus transfer
  only after the fade completes, so overlapping pages cannot steal focus.
  `SettingsPageLink`, `SettingsPageDismiss` and
  boolean destinations retain native navigation outside this workspace,
  including iOS/iPadOS. `SettingsPageMotion` is also used by nested form and
  subtitle panels, with Reduce Motion respected by their hosts.
- **Title navigation** — tvOS uses native page pushes and pops. The app no longer
  installs `detailNavigationZoom(isEnabled:)` or reads the retired zoom preference.
  The logo, metadata, controls, and episode entrance sequence remains.
  It starts when the native page appears, without a cover, window
  input guard, artwork wait, or custom Back handler. Leaving cancels the reveal;
  returning to an existing page does not replay it. Reduce Motion shows everything
  immediately. iOS/iPadOS navigation is unchanged.
- **Retained cinematic transition infrastructure** — the zoom implementation and
  its focused fixtures remain available for future work, but no production shell
  enables it. TV browse stacks install
  `cinematicDetailNavigation(path:)` on the stack so its destinations inherit it.
  Back changes that bound path in the reverse transition's nonanimated transaction:
  SwiftUI's environment dismiss action can still animate a native pop underneath
  the cover. Input remains guarded until both the reverse motion and real pop
  finish and native source focus is restored. Native media controls also reject
  directional focus updates while the window's input guard is installed; a
  window gesture recognizer alone does not prevent UIKit's directional focus.
  Programmatic restoration remains allowed and targets the requested control,
  not the window's default focus candidate. If UIKit already restored the source,
  synchronize its SwiftUI binding without queuing another native request.
  Cross the native pop's render boundary and prepare source focus while the
  reverse artwork is still moving, not after it finishes. The cover and input
  guard remain until both preparation and motion complete; held input still
  drains before fresh navigation is admitted.
  Hosts without a bound path retain
  ordinary dismissal; Reduce Motion and noncinematic pages keep native navigation.
- **Native action controls** — `plozzActionButton` only selects the system
  glass/glass-prominent styles, or bordered styles on older systems. It adds no
  font, padding, capsule, border, focus effect or press scaling. Setup, profile/PIN,
  source/import, retry and sync actions share this native selection rather than
  the retired `PlozzActionButtonStyle`. Keep label sizing native; do not add wide
  minimum widths just to manufacture a large page-action pill. Text colors belong
  on text, not screen containers that also contain native controls.
  iOS primary actions pair the palette's monochrome `accent` with `onAccent`:
  native prominent buttons otherwise retain white text on a white tint. This
  theme-color pairing does not replace native geometry, material or interaction.
  Playback uses `PlayerControlButton` for icon-only transport actions. Multiview
  keeps visible title-and-icon labels and uses the same `playerGlassButton`
  treatment, including native menus. Only the existing reduced-transparency
  playback path draws the shared frosted fallback.
  Mobile video chrome uses untinted clear Liquid Glass with white symbols and
  progress in both appearances; `playerControlForeground`/`playerControlTint`
  keep SwiftUI and UIKit controls consistent without overriding menu appearance.
  Mobile panels use regular native glass with no extra decoration and leave
  the system Liquid Glass preference in control. Mobile fallback surfaces inherit
  the app appearance and pair light fills with dark foregrounds.
  Playback progress is the exception: seek tracks and level meters keep light
  progress over a subdued track even in the light-theme fallback.
  `playerPlatformAppearance` scopes tvOS playback chrome to dark regular glass,
  as in build 57, without changing the surrounding browsing or window appearance.
  It is a no-op on iOS.
- **Settings steppers** — TV makes the whole labeled row one focus target using
  the existing `SettingsFormButtonStyle`, including its helper, persistent minus/plus cues and
  `SettingsRowMetrics.titleFont` value. Labels must be supplied to the shared
  stepper, not placed outside its focus target. Left/Right adjusts,
  Select increments, and Up/Down remains native focus navigation. Bounds clamp
  unless a caller explicitly requests wrapping. Width reserves the longest value.
  `SettingsAdjustmentFocusScope` shares the player's horizontal input ownership,
  held-press cancellation, and navigation-rail protection. VoiceOver adjustment
  uses the same stepping operation. Mobile retains separate buttons.
  Use `textTitle` for mixed localized labels and formatted values, such as
  Immediately or a duration; do not resolve localized copy into `verbatimTitle`.
  Optional range labels replace the numeric display with a bounded track, retaining
  the same input owner, native focus styling, clamping, and accessibility actions.
  `inlineRange` uses a short, vertically centered track beside the label with a larger middle tick;
  long labels retain the row's wrapping fallback instead of shrinking text.
- **Hero logo size** — `HeroLogoSizing` supplies the existing default bounds and
  bounded layout sizing for TV heroes, Showcase, and mobile heroes, from half to
  1.5 times the unchanged default with finer adjustment stops near default.
  Width/height ceilings preserve aspect ratio and available screen space. The
  local `HeroLogoSizePreview` uses the same sizing math and shared illustrated
  scenery; adjustments do not change logo cache keys or prepare another bitmap.
- **Hero text size** — Home, Detail Page, and TV Showcase/Recommended scale text independently
  of artwork. `metadataTextScale` scales badge fonts, icons, borders, and spacing
  together without changing `mediaBadgeScale`'s existing compact-format styling.
  Scope it to the metadata subtree, not buttons, cards, or whole pages.
  The default is 1; mobile preserves Dynamic Type in addition to the chosen size.
- **Hero scrim coverage** — `heroScrimHeightScale` extends both the analytic gradient
  and cached texture upward from their bottom anchor, within the existing bounds
  and before the backdrop's dissolve mask. Default coverage remains unchanged.
- **Grouped Settings rows** — `SettingsControlRows` inserts palette separators
  between tvOS rows sharing a container, never after the last visible row. Keep
  a control and its helper in one child view; the divider belongs after both.
  Conditional rows keep their SwiftUI identity, and separators add no focus or
  accessibility stops. Focus fills stay within row bounds, with the shared
  8pt `dividerFocusClearance` on each side of the line. Icon-led category lists
  start their dividers at `SettingsRowMetrics.iconTitleInset`, sharing the actual
  row icon width, gap and content padding; leading alignment also follows RTL.
  Illustrated Settings groups instead use a 16pt gap and 16pt padding without
  internal dividers. Grouped steppers inherit
  the same leading inset as their neighboring rows, with no extra resting chip.
  Mobile keeps its existing stack/native-list presentation.
  `settingsGroupSurface(cornerRadii:)` shares the same paint and accessibility
  fallbacks for [connected TV control groups](../FeatureSettings/README.md).
- **Long Settings labels** — `LabeledSettingRow` preserves the aligned horizontal
  layout when it fits. On tvOS, longer copy switches to a wrapping label above
  its control rather than overlapping it or reducing the shared body font.
  Mobile retains its existing layout.
- **Grouped settings navigation** — `SettingsDisclosureLabel` supplies a
  direction-aware disclosure indicator and optional value without adding row
  padding. `SettingsSectionGroup` owns those insets; do not nest a separately
  padded `SettingsRowLabel` in it. Inline actions use `plozzActionButton`, not
  the group's full-width row-button style. Place a standalone native action in
  a layout container so its accessibility bounds do not include the row's
  noninteractive space.
- **Unwatched episode counts** — a default-on profile preference replaces the
  top-right watch-status mark with a number on series/season cards.
  Episode counts use charcoal tiles with white digits so they stay quieter than
  the watch-status marks. Counts independently use an inset Floating tile or a
  flush Attached tile with a curved bottom-left corner. Watched marks use a colored
  completed circle with a contrasting check; unwatched marks use a colored triangle.
  The count tile's top-right corner stays square; only the artwork clips its
  outer corner and shadow. Native poster and library-card overlay hosts apply
  that clipping at the full artwork bounds, not at the badge's own bounds.
  Both count styles use bold system digits. At standard TV size the curved
  tile has 12pt side padding and is 52pt tall; floating-tile spacing is unchanged.
  Floating marks have density-scaled clearance (16pt at standard TV size).
  Touch sizes and artwork radii remain proportionate. Episode cards and the
  watch-indicator Settings previews reuse the same check badge and flag.
  Their middle poster represents an in-progress series with three remaining
  episodes. Its shared count badge follows the live count toggle and independent
  Attached/Floating preference while progress stays visible. Count style crosses
  native hosting boundaries, controls overlay placement, and invalidates both
  native poster bitmap caches.
  `MediaWatchIndicatorStyle` owns the eight opaque watch-mark colors and contrasting
  check colors; white is the default. The profile preference crosses native
  hosting boundaries and participates in both native poster bitmap cache keys.
  `ColorSwatchButton` shares circular selection marks, accessibility and existing
  platform focus treatment between the watch palette and avatar color choices.
  Positive exact library counts take priority; unknown counts retain the
  existing watched/unwatched style. Completed containers retain its completion
  behavior. Movies, episodes, ownership/request marks and spoiler protection
  are unchanged. Native and SwiftUI cards share the renderer and preference,
  including native hosting and accessibility.
  Counts use Plex leaf/viewed-leaf fields, Jellyfin/Emby unplayed-item counts,
  and existing local Share episode rollups. They never query episodes per card,
  use online episode totals, or sum duplicate servers. Cross-server counts
  follow the same source as watch state. Child mutations invalidate snapshots
  until the next batched refresh instead of guessing a decrement. Movie actions
  never invalidate unrelated episode counts. Count-only refreshes wait for
  confirmed server delivery so they cannot undo an optimistic watched action.
- **Discovery marks** — the requestable plus, requested clock, and unowned
  binoculars fit the same density-scaled square and corner clearance as the
  watched badge: 21pt on standard touch cards, 42pt on standard TV cards.
  Symbol bounds, not font point sizes, determine their footprint; mobile marks
  never inherit TV's 36pt minimum. Their existing grey/white treatment and
  ownership/request meanings are unchanged. In-player credits use the same
  renderer with their card-width-scaled size.
- **Theme** — `Theme`, `ThemeOption` (System / Dark / Pure Black / Light) and
  the per-profile theme model, observed at the app root.
  Gradient Backgrounds is a separate default-on profile preference, transferred
  with that profile. Turning it off restores the existing flat page/settings
  fills without changing the selected theme or music-player appearance.
  The static mesh layout is adapted from tresby's
  [Ambient proposal (#75)](https://github.com/brandomoore/Plozz/pull/75), with
  separate light, dark, and near-black treatments rather than another theme.
  Home and movie/show detail pages own their tint/cache locally on both platforms.
  They use the artwork actually displayed by their own hero; covered pages cannot
  replace another page's colours. Home sources publish only while frontmost.
  Palette extraction reuses cached artwork, runs
  off the main actor, waits 180ms for navigation to settle, and retains at most
  24 artwork-identity-keyed palettes. Replaced/cancelled sources cannot publish
  stale colours or clear another source. Only the background leaf observes the
  colour array; no full-screen clock, blur, or per-frame page invalidation runs.
  Reduce Motion disables the palette crossfade. Dark uses a softer wash and Black
  retains more visible colour while staying darker; Light's palette is unchanged.
  Fullscreen Hero Home uses half the artwork tint's saturation on both platforms,
  retaining its hue and brightness without desaturating the hero image. Showcase,
  detail pages, and untinted stock gradients retain their existing treatment.
  Tint saturation is page-scoped and shared with native card fills/textures.
  Settings panels and detail information cards share a
  5%-white wash in Dark and Black, or a 5%-black wash in Light, so they remain
  distinct without replacing the gradient's colour. SwiftUI surfaces keep their
  shadow and a matching hairline edge. Gradient Off or Reduce Transparency restores the original solid
  surface and border; unrelated raised cards remain unchanged.
  PIN digit/delete keys use native Liquid Glass at rest and during interaction
  on iOS/tvOS 26+, independent of the page gradient. `PINDialPad` and `PINKeyStyle`
  own this for profile, Plex, parental, and Live TV authorization/setup prompts.
  In the tvOS Settings workspace, digit 1 uses the shared page-entry focus
  handoff after the transition enables input. Both layout directions must receive
  native keypad focus; do not rely on automatic focus selection after the slide.
  The system owns their glass appearance, focus, hover, and press treatment;
  digits keep their original circular size and Delete spans two columns at the
  same height. Mobile activation retains haptic feedback. Reduce Transparency
  and older OS versions retain the previous shared keypad fallback and exact key sizes.
  Mobile PIN headings use native Title 2 bold, matching the profile picker.
  The shared scaffold keeps this typography consistent across PIN flows;
  tvOS retains its larger viewing-distance heading.
  Mobile profile selection opts into `PINProfileTransition`: the profile's
  avatar/name are the primary identity, with the PIN type in smaller text.
  `PINEntryScaffold` retains this identity through live verification and errors;
  it mounts the progressively revealed dial pad only after protection is
  confirmed. Its portrait stack and landscape columns scroll at constrained
  heights. Standalone PIN prompts and tvOS keep their existing presentation.
  The detail information band retains its darker 40%-opaque surface.
  Compact mobile detail metadata and actions reveal the page gradient instead
  of covering it with a solid rectangle; Gradient Off and Reduce Transparency
  retain the original opaque base. The artwork's existing readability fade stays.
  Native tvOS cards display their local portion of a shared page-mesh texture,
  with the information band and wash precomposed because TVUIKit replaces fill
  alpha. The texture is created only when a card needs it, its longest edge is
  capped at 480 pixels, and it is rebuilt only for palette or viewport size
  changes. Scrolling updates each background's sampling rectangle, not its
  texture or foreground content. `settingsPageBackground()` provides the same
  page-aligned texture to Settings' focusable information cards, without the
  detail page's darker information band. Nested workspace pages inherit that
  background instead of painting another gradient. Native focus,
  clipping and text remain TVUIKit-owned.
  Text stays opaque and native focus geometry is unchanged. Gradient Off or
  Reduce Transparency restores both the solid band and solid card fills.
- **Episode loading preview** — the tvOS entry overlay leaves gutters and caption
  spacing transparent to the owning page, including artwork-tinted gradients.
  Only the real cards' drawing is hidden while their lazy layout realizes the
  entry target; no opaque rail-wide cover or second gradient is painted.
  Detail entrance gates restrict focus, not preview alignment. Loaded episodes
  replace the placeholder while Play retains focus, and a focused placeholder
  still hands off only to its measured, on-screen target.
- **App-owned dialogs** — `plozzSheet` owns one opaque, theme-aware surface:
  the native presentation background on iPhone/iPad, and the existing rounded
  overlay card over `PlozzDialogBackdrop` on tvOS. TV uses a clear native
  full-screen presentation because its glass sheet leaves refracted edge strips
  around custom backgrounds. The shared surface honors Gradient Backgrounds in
  Dark, Black, and Light without adding blur, including with Reduce Transparency.
  `AppBackground` and `SettingsPageBackground` defer to that surface inside a
  dialog rather than repainting smaller rectangles over it. Use `.floatingCard`
  only for content already owning its dimmer and `.overlay` card.
  `plozzFullScreenCover` resets background ownership for nested page flows;
  bindings, dismissal callbacks, and explicit preferred color schemes remain
  caller-owned. Native alerts and confirmation dialogs remain system-styled.
- **Focusable building blocks** — focus-aware buttons, cards, tab bars,
  parallax containers, brand QR code rendering, code-font numerals.
  Native card focus observation is separate from explicit focus requests.
  Caption, overlay and transition-anchor readers update without rebuilding
  the poster's artwork loader or context menu.
- **QR images** — `QRCodeView` renders on a worker actor, including Core Image
  initialization. Settings, account authorization and device pairing share it.
  Payload/correction/mask changes replace the request; cancelled work cannot
  publish an old code. Theme tint is applied to a transparent mask without
  rerendering. The memory-only cache retains at most 8 images and 16 MiB of
  pixels; payloads are never persisted or included in error logs.
- **Mobile content tabs** — `PlozzContentTabs` owns the touch-sized horizontal
  navigation shared by library modes and series seasons. Selected tabs use the
  existing glass capsule style; inactive tabs are secondary text without a
  capsule. Typography, spacing, 44pt minimum targets, selected accessibility
  traits, long-label fitting, and selected-tab reveal live in one component.
  It respects Reduce Motion when revealing a new selection and re-reveals after
  viewport, text-size, or option changes. Callers supply localized or verbatim
  labels and page keylines; native app tabs and tvOS focus controls are separate.
- **Container covers** — collection, playlist, and folder cards accept landscape
  and square primary covers and fit the complete image within the shared card
  footprint on mobile and tvOS. Media posters retain their portrait aspect guard;
  accepting curated container logos must not admit landscape episode stills as
  movie/series posters. Library-tile collages likewise accept wide container covers
  while retaining their aspect guard for ordinary media posters.
  Collection-cover groups resolve one uniform shape using Auto, Posters, or
  Landscape. Auto samples at most nine initial primary covers, uses a strict
  landscape majority, and falls back to posters for ties or unknown artwork.
  Server-reported ratios avoid image requests; absent ratios use the normal
  authenticated artwork loader before publication. Paging never changes the
  browser's chosen shape. The native tvOS grid accepts and fits container covers
  without relaxing the portrait filter for ordinary media.
- **Home row recovery** — ordinary rails and compact empty/failed rows share
  `MediaRowSection` and `MediaRowHeader`, including typography, header spacing,
  pinned-navigation inset, and trailing safe space. `MediaRowStatusContent`
  keeps the summary/source concise and wraps native recovery actions at narrow
  widths. Detailed explanations stay behind Details. Inline Settings warnings
  reuse the status content without adopting Home's full rail header.
- **Mobile media corners** — posters and Continue Watching share a 12pt artwork
  radius at every display size and responsive width. Borderless cards use that
  radius directly; glass frames add their inset to remain concentric. Loaded
  artwork, missing-art placeholders, and skeletons agree. TV rounding is unchanged.
  Regular artwork progress bars use the shared Detailed bar metric described
  above, including its density and Dynamic Type scaling.
  Mobile library, episode, and download artwork uses the same metric, keeping
  its caption clearance consistent with its actual corners. Mobile captions use
  a shared 4pt horizontal inset from the artwork edge, independently of their
  unchanged bottom corner clearance. Poster, landscape, music, download, and
  episode captions and skeletons share it; TV caption layout is unchanged.
  Home library names
  and server names share one leading-aligned text column beside the provider mark.
- **Provider marks** — IPTV uses coral-red while Media Share keeps teal.
  `ProviderBrandMark` owns their shared icon and badge tints, including deeper
  colors on white focus cards and brighter colors on black focus cards.
- **Media-row focus** — a dedicated modifier owns the row's `FocusState`
  and supplies its binding to tracked cards. Focus callbacks and prefetch
  bookkeeping must not invalidate the row that constructs all card inputs.
  Entry-gate state remains observable for episode rows; ordinary Home rows
  retain native column-aligned entry and cover/return behavior.
- **Poster preview prefetch** — shared media rows and mobile Home use
  `MediaArtworkPrefetchPolicy.claimPreview` to reject already-queued item IDs
  before parsing/resizing their URLs. Eligibility remains lazy; rejected
  previews are not recorded, so later usable artwork can still be queued.
  Existing row resets and direction changes rearm the same ID sets. This
  changes neither the nearest-first queue nor the full-image fallback ladder.
- **Grouped settings interactions** — `SettingsSectionGroup` uses explicit
  native switch toggles and menu pickers on iOS/iPadOS. Standalone mobile
  settings/Live TV controls and the shared `SettingsSwitchToggleStyle` also
  use the system switch; do not draw a replacement track or knob, wrap the
  toggle in a button, or override its native animation/accessibility.
  The switch alone clears inherited tint so monochrome page accents do not
  hide its thumb against the enabled track; neighboring controls keep their tint.
  Each standalone or pushed settings `Form` must apply
  `SettingsSwitchToggleStyle` itself; a style on the presenting form does not
  establish the style for its navigation destinations. Leave native menu toggles
  as checkmarks rather than applying a switch style to the entire app.
  tvOS uses native On/Off toggles with shared settings row typography, not drawn
  switch tracks. Focus-gated and side-effectful action rows retain their owned
  buttons and show the same On/Off text.
  Custom value menus use `SettingsMenuLabel` to show
  the selected value with up/down chevrons, matching editable pickers rather
  than read-only `LabeledContent`. Navigation keeps its right-facing chevron.
  Unavailable settings use a natively disabled control with a short explanation.
  Share-only streaming quality shows a disabled **Original quality** picker with
  **Unavailable for network shares.** beneath it; saved server-quality preferences
  are left untouched. Compatible-server quality menus remain enabled.
  A visual group occupies one native List cell; automatic
  pickers can promote their menu to that whole cell and intercept neighboring
  navigation links or controls. Keep picker activation local without replacing
  the shared group surface, separators, or tvOS control styles.
- **Detail-opening feedback** — `detailOpenFeedback()` provides one soft haptic
  when a mobile media, person, downloaded-show, or music detail page first
  appears. The page owns the one-shot state, outside loading content, so data
  refreshes, returning from playback, and popping a nested detail do not repeat
  it. Opening a new page emits again; tvOS and devices without haptics are silent.
- **Touch action feedback** — `TouchFeedback` gives mobile skip actions a light
  impact and committed scrubs / explicit reorder moves a selection tick. Native
  List drag reordering retains system feedback without a second app vibration.
  Watchlist actions acknowledge the press immediately with a light tap and stay
  silent on success; an error haptic accompanies a failed save and rollback.
  Their shared toast uses "Added to Watchlist" / "Removed from Watchlist" for
  the optimistic local change, not lingering progress wording. A failed save
  replaces that confirmation with "Couldn't update Watchlist".
  Manual watched actions retain the immediate tap and separate confirmation of
  durable outbox acceptance, not eventual server synchronization.
  Favorites confirm successful writes. Capture asynchronous completion haptics
  at the user action: they are one-shot and cancelled when the app deactivates
  or the profile changes, rather than expiring during a slow foreground save.
  Scrolling, menu opening, automatic playback and background persistence/retry
  events do not trigger action feedback.
- **Async artwork** — `FallbackAsyncImage` and `ArtworkImageCache`: an
  on-disk + in-memory image cache shared with `MetadataKit`'s URL cache,
  with profile-scoped source choices in Appearance > Artwork. Recommended uses
  metadata providers first for Home and library Showcase heroes, movie/show detail
  backgrounds and logos, and textless Continue Watching artwork. Ordinary rows,
  related-title posters, and episode thumbnails remain library-first. Detail hero
  placement is carried through resolution, cache identity, prewarming, and mobile
  reflections without changing the surrounding page's card policy.
  Shared hero/reflection first-paint results are qualified by source and provider
  policy so changing those settings cannot reuse a previous provider's winner.
  Library-first and metadata-provider-first
  presets initialize source choices for Home, Continue Watching, Browse,
  Search, Watchlist, Details, Episodes, Playback, Music, Top Shelf, and Downloads
  where available. Editing a view enters Custom mode; choosing any preset
  replaces the whole configuration. The shared editing and presentation contract
  lives in [FeatureSettings](../FeatureSettings/README.md#invariants). Cards retains
  card presentation controls, not app-wide artwork policy. Missing artwork can
  fall back to the other source. Provider-first waits for lookup and image decoding
  to finish, including time queued behind other requests; a short first-paint
  budget must not permanently select cached library artwork instead. Existing
  network/image-load deadlines still bound failures, and cancellation releases
  the view without painting a fallback for a cancelled request.
  Provider enablement/order is household-wide in Metadata Providers; changing
  appearance never enables a provider. The old library-artwork choice migrates to each profile,
  and the new preference transfers/syncs with that profile.
  Metadata Providers links directly to the active profile's Artwork preferences.
  Reciprocal links return to an existing page instead of stacking duplicate pages.
  Library-first heroes honor the server-selected backdrop or primary share
  sidecar rather than choosing a different image for Details or avoiding artwork
  on the focused card. Recommended retains varied library Details backgrounds as fallbacks;
  metadata-provider-first retains provider lookup and artwork variation. The
  choice applies equally to first paint, prewarming, mobile reflections, and
  later visits; alternative images remain fallbacks if the selected one fails.
  Continue Watching's recommended textless lookup is separate from source
  preference: explicit library-first uses supplied artwork without checking it
  online. A selected textless backdrop has priority over both ordinary provider
  and library images, including synchronous cache seeding. If that image fails,
  the normal source preference still orders the fallbacks. When textless artwork
  is unavailable, Recommended keeps a library background ahead of a metadata
  poster with baked-in lettering; episodes use only their series background.
  An explicit metadata-provider choice still gives providers priority. Missing
  or unreadable library backgrounds retain the metadata-poster fallback.
  Native tvOS and SwiftUI cards both settle cold textless lookups before
  selecting a background;
  the native poster and its focus owner remain mounted while waiting.
  `ContinueWatchingArtworkSource` is shared by rendering and lookahead on TV and
  mobile. It prepares the selected backdrop and processed logo, including
  metadata-provider fallbacks and SMB references, in the existing bounded caches.
  `ArtworkPrefetchWindow` retains only the current nine-card window, cancels work
  that leaves it, and reuses overlapping completed requests. Source or policy
  changes replace those requests; leaving the row cancels them. Background
  metadata has a separate one-request gate and image decoding uses the background
  lane. Neither focus callbacks nor touch scrolling await any preparation.
  Textless lookups coalesce per title; cancelling speculative work cannot cancel
  a visible consumer or turn an unfinished lookup into a cached miss.
  `TextlessBackdropIndex` keeps synchronous first-frame reads, but JSON encoding
  and atomic persistence run on a utility serial queue, never the main actor.
  One in-flight snapshot and coalesced pending changes preserve newest-answer
  ordering without a write backlog. Failed writes retain dirty state for a later
  save and log a numeric error code; they do not spin on automatic retries.
  The existing 400-entry budget and 14-day read expiry still apply.
  SMB selections retain local and online candidates in the shared
  catalog, including typed network-file references and their access gate.
  SwiftUI, native Browse cells, detached hosts, and prewarmers use the same
  effective policy. Cache identities include source and provider policy; a
  settings change replaces the image selection, not ordinary focus movement.
  A fallback is stable for that appearance, not a promise that an online source
  has no image. Playback system art receives an explicit snapshot.
  Top Shelf exports resolved images into its shared container. Downloads capture
  the selected artwork when queued; existing offline artwork is not re-fetched
  after a settings change. Clip-specific extra thumbnails, people, channel
  branding, and spoiler protection retain their separate semantics.
  When card captions are hidden, folder and missing-art placeholders carry the
  existing spoiler-safe title inside the artwork slot. Loaded art remains
  label-free, visible captions are not duplicated, and loading/failure never
  changes card height. Spoiler blur applies to images, not fallback names.
- **Content state** — `ContentStateView` renders the `LoadState`
  loading / loaded / empty / failed states identically across features.
- **Mobile settings surfaces** — `SettingsPageSurface` keeps the native scroll
  viewport full-width so the title's scroll-edge blur reaches both navigation
  edges. Horizontal safe-area padding insets the content without narrowing that
  viewport; both list rows and grouped scrolling panels retain their spacing.
  Settings subpages default to the system's centered inline navigation title on
  both iPhone and iPad, including the iPad detail column. Root destinations keep
  their leading large titles; only the Settings root overrides the shared surface
  title mode. Modal utility pages also use inline titles without custom fonts.
  The compact Settings drawer keeps its title leading beside a native close
  button at the top, switching to a centered inline title only after scrolling.
  Both Settings roots use a 16pt content inset matching the native leading title;
  subpages retain 24pt insets. Alignment never narrows the scroll viewport.
  Its first section uses a tighter 8pt content margin.
  Profile/PIN resealing observes the page, not a zero-height row that adds spacing.
- **Subtitle appearance** — editing the live subtitle look now happens in
  the player (`FeaturePlayback`'s in-player Style screen), not via a shared
  Settings card.
- **Cast & metadata cards** — `CastRowView` and friends, used by Home /
  detail. Family guidance uses the Common Sense circle/check artwork, with a
  palette-selected light/dark variant shared by the inline age and guidance panel.
  The inline mark retains its original 32 points on TV and 24 Dynamic Type-scaled
  points on mobile. TV uses a 1-point optical overlap of the transparent insets,
  keeping the visible mark close to its age; mobile retains its
  4-point scaled gap. Neither adds an outer frame or padding. Age text matches
  neighboring review scores' medium weight. Review icons use the same 4-point
  scaled icon-to-value gap.
  Full Common Sense Media attribution remains in the guidance
  panel and accessibility label; the decorative mark is hidden from VoiceOver.
- **Media badges** — Porcelain uses Outfit typography (bundled with its SIL OFL
  license), filled resolution badges, and matching outlined capsules for dynamic
  range and audio. Video-codec and dynamic-range capsules add a 15% foreground
  tint (white in dark themes, dark in light themes); audio formats and language
  capsules stay clear, with channel segments attached to their audio codec.
  Only resolution receives a solid fill. Format names are ordinary text, not vendor logo drawings.
  Refined compact uses 22-point resolution badges and 26-point other technical
  badges with 15-point main text, short display
  names (DV, DD+, DD, TrueHD, Atmos), and full source names in accessibility.
  Mobile metadata wrappers retain an 18-point baseline height for both.
  Resolution padding is 6 points; capsule outer padding is 8 points, with
  4 points on either side of the channel divider and 7 after the channels.
  Review scores and age recommendations use a 14-point scaled gap; certificates
  and formats use 12 points. Category boundaries use the larger adjacent gap.
  Compact wrappers scale that gap with the surrounding text, not the individual
  format's artwork height. Inline and wrapped metadata share this spacing without
  tightening year/runtime separation or grouping badges into an unbreakable row.
  Version pickers keep their independently enlarged artwork and use fixed gaps
  (12 points on TV, 8 on mobile) in both inline and wrapped badge rows.
  Resolution, picture range, and video codec precede audio formats and languages;
  audio codec and spatial capability may both
  describe one stream. Representative audio keeps the codec, channels and
  capability from one source instead of combining incompatible files' facts.
  Missing facts remain missing; filenames do not invent HDR or audio badges.
  Compact metadata badges follow the surrounding text's Dynamic Type scale.
  Classification badges use `ContentRatingPresentation`'s regional display aliases,
  preserving warnings and the full provider text for accessibility. Unknown
  descriptions are width-bounded, not converted to a guessed age rating.
  `plozzShowsContentRatings` hides certificates without affecting technical badges,
  review scores, or parental restrictions; copy it across native hosting boundaries.
  Featured cards use compact visual metadata and full accessible classifications.
  Title-information facts retain the full original classification when visible.
- **Detail information focus** — the tvOS About/Ratings/Information band uses
  native focus with at most 2% growth and 6pt of expansion per edge, leaving
  clearance in its 18pt gutters. Focused read-only cards and card buttons draw
  above their peers. This policy does not change ordinary media-card growth,
  custom focus styles, or touch layouts.
- **Native artwork focus comparison** — launch the separate tvOS focus host
  with `--native-artwork-focus-comparison`. It compares the current poster,
  a single-image poster, a content-masked poster with separate overlays, and a
  plain native card. The goal is to preserve outer enlargement and the native
  highlight without extra zoom/cropping inside the artwork, not disable growth.
  The single-image case prepares rounded transparent artwork and overlays once,
  then enables `masksFocusEffectToContents`; no custom focus transform is used.
  Geometry checks on tvOS 26.5 found preserved composition and overlay insets
  while enlarging 400×225 artwork to 440×247.5. Those checks did not validate
  the highlight bounds: subsequent physical testing exposed an offset highlight
  mask on the single-image `TVPosterView`. Content masking alone also leaves
  separate native overlays floating at a different depth. Neither is an
  accepted production replacement.
  `NativeArtworkFocusComparisonHostedTests` checks real focus, enlargement,
  baked-in image landmarks, overlay-marker pixels, visible highlight, and action
  delivery. Run it with
  `tools/run-focus-tests.sh -only-testing:PlozzFocusTests/NativeArtworkFocusComparisonHostedTests`.
  This fixture does not change production style. Its composited chrome is
  deliberately static: live content updates and image replacement during focus
  need separate coverage before adoption. Alpha masking also has a documented
  rendering cost; these geometry checks do not establish physical frame pacing
  or full Siri Remote motion behavior.
- **Native library artwork layout** — `NativeTVLibraryCell` leaves UIKit's
  `contentView` at the full cell size and owns the artwork as a separate direct
  child. Resizing `contentView` to exclude captions caused every repeated
  layout pass to grow then shrink its hosted artwork, invalidating SwiftUI
  geometry even when the final size was unchanged. The artwork remains directly
  under the focused cell for TVUIKit projection, with captions outside it and
  detail transitions referencing the artwork rather than the full cell.
- **Native poster focus** — the shared `NativeTVPoster` uses a
  `NativePosterButton`, not `TVPosterView` or a `TVCardView` ancestor. Its
  `UIImageView` retains native enlargement, remote motion and the moving
  specular highlight. Portrait rows and native Browse cells share
  `NativePosterImageView` and UIKit's rectangular focus mask:
  the small native internal crop (about 1-2% in hosted measurements) is an
  intentional tradeoff for retaining that native surface.
  The alpha-derived highlight mask produced an offset crescent at extreme tilt.
  Continue Watching, landscape/square artwork, transparent landscape library
  covers keep their no-internal-zoom alpha-masked path.
  Images arm native enlargement only on actual focus and release it after the
  current native defocus animation completes. This applies to opaque portraits
  too: arming them before focus can mount untouched lazy-row cards already lifted.
  A resting-only rounded clip preserves their corners while native effects are
  disarmed. It is removed before focus, so it never trims enlargement or tilt;
  stale animation completions cannot restore it during a newer transition.
  Portrait artwork and placeholders are opaque rectangles. Pre-rounded alpha
  pixels beneath the focused native mask create
  a second corner silhouette that can separate from the highlight. Transparent
  portrait sources receive the same dark backing as missing artwork.
  Alpha-masked landscape/square artwork remains rounded in the bitmap.
  Native loading cards bake their neutral fill into that same artwork plane.
  Only the spinner belongs on the nearer overlay plane; a full rounded fill
  there scales independently and exposes the underlying image as an extra rim.
  Corner flags, count-tile backgrounds and legibility washes are composited into
  the artwork itself. Portrait count digits and floating status/library marks
  use a cached foreground on `overlayContentView`. That surface receives a nearer
  native depth projection; its badge alone is aligned to the public artwork
  viewport so it does not drift outside the image.
  Async logos, focus-reactive progress and animated content remain live in
  `overlayContentView`; ordinary poster edge backgrounds and full-card legibility
  washes do not. Featured cards instead host their complete live composition on
  that surface without rasterization or a second overlay corner clip. Native
  artwork clipping owns their complete outer edge; clipping the overlay again
  exposes bright backing pixels at the antialiased corners, including after
  defocus. The Featured scrim extends 40pt beyond each layout edge to keep
  aspect-fill pixels shaded while the native projection settles. Its stops
  remain anchored to the original artwork height, and artwork, video and
  metadata keep their original layout. Do not clip this overscan back to the
  overlay bounds; the native image surface supplies the final silhouette.
  See [Featured sections](../FeatureHome/README.md).
  Continue Watching
  keeps its established size, reflection, logo position and resume chrome without
  top-corner watch marks, including when series artwork is disabled. This uses
  the Continue Watching presentation area, not instant-play or resume-chip flags:
  extras and other playable cards retain the profile's watched/unwatched marks
  independently of their resume chrome. Spoiler-hidden cards still suppress marks.
  Its adaptive logo dimming and the shared bottom scrim
  are drawn into the artwork; projecting those backgrounds with the live overlay
  creates a dark rim outside the focused image. Captions stay outside it. Transparent
  landscape artwork retains its alpha, and protected/extended artwork is prepared before
  normalization. Portrait count tiles stay flush. Their digits center inside the
  visible tile using the native crop allowance (2pt horizontally, aspect-scaled
  vertically). Badge destination geometry updates in UIKit's focus coordinator
  at the focus event, not in a completion callback. The poster and foreground
  images remain identical across focus changes: no late bitmap replacement,
  delayed number repositioning, custom poster scale, spring, duration or timer.
  Background/foreground indicator layers share the existing bounded bitmap cache;
  foreground identity uses the visible status and badge geometry, not unrelated
  playback progress or download state. Different posters with identical badges
  reuse the same concrete pixels; status/count, environment, size and scale
  changes still invalidate them. Background and combined layers retain all
  progress, download and scrim inputs. Mobile and
  landscape cards keep their combined indicator rendering.
  The button keeps the existing artwork slot and committed-bounds bitmap
  preparation, preserving row pitch and captions.
  SwiftUI measurement is side-effect-free: candidate widths never resize the
  native image or trigger artwork/status rendering. A mounted poster prepares
  its latest inputs at the committed UIKit size, with a per-poster autorelease
  pool for temporary raster surfaces. Creation uses shared loading surfaces
  (bounded to 8 entries, 4 MiB), not per-item composition.
  Cold source-image conversion runs on the same two-operation worker lane as
  Browse, never synchronously inside native poster layout. The existing native
  image view receives the finished pixels without replacing its focus owner.
  Identical pending requests coalesce; replacement, detachment and dismantling
  cancel work, and generation checks reject stale completions. A replacement
  shows a safe placeholder rather than the previous title or unprotected artwork.
  SwiftUI indicator and protected/extended treatment preparation still requires
  the main actor. Final Home and Browse bitmaps share one memory-budgeted cache;
  warm returning artwork paints immediately, and a memory warning prevents
  in-flight work from repopulating a purged cache.
  Ordinary artwork uses one final normalized/composited surface rather than
  retaining an additional unmarked full-size copy per card. Identical status
  presentations share concrete pixels in a separate 24 MiB/64-entry cache;
  cached images do not retain a SwiftUI renderer or its environment.
  Status-cache pixels remain unrounded until the final composite. Rounded alpha
  is applied once to alpha-masked artwork after washes and marks are combined; clipping the
  individual draws exposes pale artwork through an antialiased count-tile edge.
  The inverse mask's outer eraser extends beyond the allocated raster, including
  the extra row/column at fractional sizes. Artwork uses committed view bounds;
  Browse aligns its view and bitmap to the same physical pixels at 1x and 2x.
  Ordinary watch flags/check badges use the profile's opaque color; episode-count tiles keep
  their dark fill and white text.
  This keeps lazy-row estimation out of the expensive rendering path without
  adding another observable loading state to the row.
  Portrait television rows fit six full cards and a quarter of the seventh at
  standard display size. `PlozzMetrics.portraitRowSlotWidth` uses the actual
  navigation-safe viewport and visible card margins, shared by loaded cards,
  placeholders and pinned-sidebar scroll parking. Only viewport-width changes
  update sizing; scrolling does not invalidate the row. Showcase's row viewport
  reaches the trailing screen edge with native navigation as well as pinned
  navigation. Showcase's nested motion surfaces expand their leading viewport
  with matching safe-area padding so SwiftUI does not cull native cards while
  they are still visible in the overscan gutter. The trailing viewport is not
  expanded, preserving row density and pinned slot parking. Hosted loaded-artwork
  checks cover both screen edges in both scroll directions and navigation styles.
  Display-size preferences still adjust density; library Browse
  grids, landscape/episode card widths and mobile sizing are unchanged.
  Native Browse uses the correction for both borderless and framed system-focus
  cells. Debug's `--original-library-posters` opts out of Browse only.
  Browse rasterizes its SwiftUI overlay to concrete pixels on the main actor
  before background composition, including fully transparent overlays. Passing
  a deferred renderer image to the worker can retain the previous missing-art
  placeholder's center glyph and wash over loaded posters. Missing artwork keeps
  its placeholder; watch badges, episode counts and progress remain independent.
  The collection cell remains the focus and selection owner,
  with the same opaque artwork, native ancestor-focus adjustment, and immediate
  foreground alignment as row posters. Reuse clears both image layers.
  Collections, playlists and folders have no watch/progress indicators. A series
  or season with zero known unwatched episodes never falls back to an unwatched
  flag when its aggregate played boolean is absent or false.
  Captions and detail transitions retain their existing owners. Custom focus,
  SwiftUI content inside native framed cards, and mobile retain their existing
  rendering paths; none uses the replaced poster control.
  The shared cache is bounded to 24 MiB and 64 entries, keyed by source identity,
  size, scale, and visible presentation settings. These limits exclude images
  retained by visible cells and are not a process-memory budget. Content changes
  invalidate composition; focus movement alone does not. Full SwiftUI
  environments and providers are not retained in the shared cache.
  `NativeLibraryCardHostedTests` covers live episode-count/artwork replacement,
  focus retention, unchanged-configuration reuse, and cache accounting. Shared
  poster regressions compare painted landmarks with native enlargement for
  portrait, landscape, square and Continue Watching artwork, alongside live
  overlays, focus requests, captions and transparent library covers. Portrait
  coverage bounds the approved crop, verifies UIKit rounds opaque portrait pixels
  at rest/focus/defocus, and samples fixed motion-effect offsets with moving
  highlights on gray artwork. Those offsets do not simulate continuous remote
  touch or its focus-movement-hint transform; actual corner tilt needs a user check.
  Focused counts check actual visible digit padding, not just layout bounds. Corner-flag
  regressions count painted pixels outside the artwork's actual top/right edges,
  and real Home cards cover count/watch/preference updates without focus replacement.
  Earlier real TV Shows comparisons recorded more native hitch counts with this
  renderer; a performance improvement has not been established. It is enabled
  for the requested zoom correction, not to claim better scrolling. See the
  [actual-library measurement protocol](../../docs/performance-debugging.md#actual-library-poster-comparisons)
  for the workload, numbers and transport limitations.
  Physical comparisons must use the actual populated library, repeated fresh
  launches, matched startup/settling times and input cadence, and separate idle
  measurements. Preserve the profile's servers, filters and sorting; retain
  background-activity evidence rather than assuming a quiet app from its age.
- **Continue Watching logo contrast** — logo-overlay cards use a 40% base
  artwork dim, reduced for dark artwork and increased by up to 25 percentage
  points when the logo blends into its background (65% maximum). The dim sits
  behind the logo. Their logo subtree always uses the on-dark-artwork treatment,
  independent of the page theme; coloured logos retain their palette. Home/detail
  and Spotlight heroes still adapt monochrome ink to their own background, so
  Light keeps dark hero logos.
  Continue Watching cards and focus-driven hero titles keep their text fallback
  invisible during logo lookup and decoding, preserving its layout space.
  Text appears only after resolution finds no usable logo (or there are no logo
  sources); cached logos still paint immediately. Completion is request-scoped,
  so a cancelled or missing logo for one title cannot reveal text for the next.
- **Featured collection cards** — the whole mobile card is one native button,
  including its logo, metadata and bottom padding. Decorative layers do not
  intercept taps or scrolling. Logos use Continue Watching's on-dark treatment,
  gentle halo and bounded colour-preserving tone lift in both page themes.
  Contrast sampling follows the resolved artwork, accounts for its aspect-fill
  crop and the existing bottom scrim, and reuses the decoded card image and
  bounded sampler cache; trailer frames are not analysed.
- **Showcase logo contrast** — tvOS Showcase can lift dark coloured lettering
  while preserving hue, saturation, white highlights, and transparency. Brightening
  stops at the available colour headroom; it never mixes in white to force a
  contrast target. A smaller useful improvement is preferred to washed-out colour,
  and the original is retained when brightening would not help. The shared background
  preparation pass measures dark ink separately and caches an optional corrected
  bitmap alongside the original in the existing bounded logo caches. View updates
  only select a bitmap against the leading page/ambient colour; there is no
  per-frame pixel analysis, new artwork request, filter, or compositing layer.
  Already-readable, bright, monochrome, strongly highlighted, and boxed logos
  keep their existing treatment. Light mode, other heroes, and mobile are unchanged.
- **Series artwork identity** — episode-backed cards normalize through
  `MetadataQuery.seriesScoped` before creating a series artwork subject. Child
  IDs and Plex episode GUIDs must not become show IDs. Explicit series IDs,
  show-scoped anime IDs, account scope, and title-matching restrictions survive.
  Corrected logo queries share the series metadata-cache key and do not reuse
  misses stored under an episode ID; the image/memo caches remain shared.
  The textless-backdrop index also qualifies its account and series lookup, so
  a legacy ID-only miss cannot keep suppressing a newly resolvable logo.
  Providers applying parent enrichment to episodes/seasons must publish the
  inherited identifiers under `Series*` namespaces; unqualified IDs may identify
  the child. Share catalog read projection adds these scopes before an episode's
  local NFO overlays its own IDs, so persisted enrichment needs no rescan.
- **Circadian Mode** — profile-scoped warmth/dimming still uses the window-wide
  multiply tint while active. Disabled, daytime, and zero-strength states remove
  the view and its filter rather than leave an opaque white layer above video.
  Fading back to neutral removes it on completion; reactivation or a profile
  change invalidates the old completion. The observer remains alive so schedules
  and previews can reinstall the tint. Hosted tests cover both off and active
  behavior; layer removal alone is not proof of HDR10+ HDMI passthrough.

## Invariants

- **No Jellyfin/Plex specifics.** Components take `CoreModels` value
  types only.
- **No persistence other than caches.** Settings live in feature modules
  (`FeatureSettings`, `CoreModels.ProfileStore`).
- **Compiles without UI.** Files are guarded by `#if canImport(SwiftUI)`
  / `#if canImport(UIKit)` so the package still builds on Linux.

## Where to look first

- `ContentStateView.swift` — the unified load-state renderer.
- `ArtworkImageCache.swift` + `FallbackAsyncImage` — shared image cache &
  the server-first / fallback rendering pattern.
- `Theme.swift` — color/themes used everywhere.
