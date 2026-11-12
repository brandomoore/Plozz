# FeatureHome

Home rows, item detail, series/season experience, and online-trailer fallback.
This module owns TV presentation. Shared behavior lives in
[`FeatureHomeCore`](../FeatureHomeCore); mobile presentation lives in
[`AppShelliOS`](../AppShelliOS).

## Where to look first

Pick a task below, then read the relevant section of its guide and the named
owner. These are entry points, not a requirement to load every linked file.
Use [state management](../../docs/state-management.md) for shared lifecycle and
ownership rules, [testing policy](../../docs/testing-policy.md) to choose checks,
and the [performance lab](../../docs/performance-lab.md) for measurements.

| Task | Behavior guide | Code owners | Regression entry points |
| --- | --- | --- | --- |
| Detail Play selects the wrong source, version, or resume position | [Detail and playback](../../docs/feature-home/detail-and-playback.md#item-detail) | [`ItemDetailViewModel`](../FeatureHomeCore/ItemDetailViewModel.swift) owns refreshed detail/source state; [`DetailPlaybackSelection`](../FeatureHomeCore/DetailPlaybackSelection.swift) chooses the target; [`MediaItem.retargetedForPlayback`](../CoreModels/MediaItem.swift) applies routing. [`ItemDetailView`](ItemDetailView.swift) and [`PlozziOSItemDetailView`](../AppShelliOS/PlozziOSItemDetailView.swift) adapt platform actions. [`PlaybackSourceSelection`](../AppRuntime/PlaybackSourceSelection.swift) handles runtime best-source selection, not feature state. | [`DetailPlaybackSelectionTests`](../../Tests/FeatureHomeCoreTests/DetailPlaybackSelectionTests.swift), [`ItemDetailViewModelTests`](../../Tests/FeatureHomeTests/ItemDetailViewModelTests.swift) (`DetailReturnRefreshTests`) |
| Home/detail does not refresh after returning | [Refresh and watch state](../../docs/feature-home/refresh-and-watch-state.md#foreground-and-return-refresh) | [`ContentRefreshModels`](../FeatureHomeCore/ContentRefresh/ContentRefreshModels.swift) owns timing profiles; [`ContentRefreshCoordinator`](../FeatureHomeCore/ContentRefresh/ContentRefreshCoordinator.swift) schedules; [`ContentRefreshLifecycleReader`](../FeatureHomeCore/ContentRefresh/ContentRefreshLifecycleReader.swift) and [`ContentRefreshSurfaceModifier`](../FeatureHomeCore/ContentRefresh/ContentRefreshSurfaceModifier.swift) deliver lifecycle/visibility. [`HomeViewModel`](../FeatureHomeCore/HomeViewModel.swift) and the detail model perform refreshes. | [`ContentRefreshCoordinatorTests`](../../Tests/FeatureHomeCoreTests/ContentRefreshCoordinatorTests.swift), [`HomeViewModelStalenessRefreshTests`](../../Tests/FeatureHomeTests/HomeViewModelStalenessRefreshTests.swift), [`ContentRefreshSurfaceHostedTests`](../../Tests/FocusIntegrationTests/ContentRefreshSurfaceHostedTests.swift), [production-view return tests](../../Tests/HomePresentationSupport/ContentRefreshReturnInteractionTests.swift) |
| Change Home rows or Continue Watching tap action | [Row customization](../../docs/feature-home/home-rows-and-loading.md#row-customization) | [`HomeLibraryVisibility`](../CoreModels/HomeLibraryVisibility.swift) owns typed values; [`HomeLibraryVisibilityStore` / `Model`](../CoreModels/HomeLibraryVisibilityStore.swift) persist by profile; [`HomeSectionSettingsViews`](../FeatureSettings/HomeSectionSettingsViews.swift) owns the control. [`HomeRow`](../FeatureHomeCore/HomeRow.swift), [`HomeView`](HomeView.swift), and [`PlozziOSHomeView`](../AppShelliOS/PlozziOSHomeView.swift) consume the choice. | [`HomeRowCustomizationTests`](../../Tests/CoreModelsTests/HomeRowCustomizationTests.swift), [`HomeRowTests`](../../Tests/FeatureHomeTests/HomeRowTests.swift), [`HomeRowArrangementHostedTests`](../../Tests/HomePresentationSupport/HomeRowArrangementHostedTests.swift) |
| Home loading, aggregation, or stale rows | [Rows and loading](../../docs/feature-home/home-rows-and-loading.md#home-loading) | [`HomeViewModel`](../FeatureHomeCore/HomeViewModel.swift), [`HomeAggregator`](../FeatureHomeCore/HomeAggregator.swift), [`HomePresentationRow`](../FeatureHomeCore/HomePresentationRow.swift) | [`HomeViewModelLoadIfNeededTests`](../../Tests/FeatureHomeTests/HomeViewModelLoadIfNeededTests.swift), [`HomeViewModelCarryForwardTests`](../../Tests/FeatureHomeTests/HomeViewModelCarryForwardTests.swift), [`HomePresentationRowTests`](../../Tests/FeatureHomeTests/HomePresentationRowTests.swift) |
| Library/See all browsing, paging, filters, or source scope | [Library and row browsing](../../docs/feature-home/library-browsing.md) | [`LibraryBrowseViewModel`](../FeatureHomeCore/LibraryBrowseViewModel.swift), [`HomeRowBrowseModel`](../FeatureHomeCore/HomeRowBrowseModel.swift) | [`HomeRowBrowseTests`](../../Tests/FeatureHomeCoreTests/HomeRowBrowseTests.swift), [`CollectionDetailBrowsingTests`](../../Tests/FeatureHomeTests/CollectionDetailBrowsingTests.swift) |
| Hero discovery, trailers, or detail theme music | [Hero and trailers](../../docs/feature-home/hero-and-trailers.md) | [`HomeViewModel`](../FeatureHomeCore/HomeViewModel.swift), [`ThemeMusicController`](../FeatureHomeCore/ThemeMusicController.swift), [`ThemeMusicPlayback`](../FeatureHomeCore/ThemeMusicPlayback.swift) | [`HomeHeroPersistenceTests`](../../Tests/FeatureHomeCoreTests/HomeHeroPersistenceTests.swift), [`ThemeMusicControllerTests`](../../Tests/FeatureHomeCoreTests/ThemeMusicControllerTests.swift), [`ThemeMusicPlaybackHostedTests`](../../Tests/FocusIntegrationTests/ThemeMusicPlaybackHostedTests.swift) |
| Showcase movement, card geometry, labels, or native focus | [Presentation and Showcase](../../docs/feature-home/presentation-and-showcase.md) | [`FocusHeroHomeView`](FocusHeroHomeView.swift), [`HomeView`](HomeView.swift), [`PlozziOSHomeView`](../AppShelliOS/PlozziOSHomeView.swift); shared components stay in [`CoreUI`](../CoreUI/README.md) | [`ShowcaseNavigationTests`](../../Tests/HomeRemoteTests/ShowcaseNavigationTests.swift), [`HomeViewModelLayoutTests`](../../Tests/FeatureHomeTests/HomeViewModelLayoutTests.swift) for layout policy, not physical focus |

For series headers, episode browsing, Related, version inventory, and pending Play
actions, use the additional sections in [Detail and playback](../../docs/feature-home/detail-and-playback.md).
For source identity reconciliation and authorization after asynchronous loading,
also read [Home loading](../../docs/feature-home/home-rows-and-loading.md#home-loading).
Test files identify coverage, not proof that a particular platform or provider
passed; hosted/UI and live-server checks have separate setup and authorization.

## Invariants

- **Provider-agnostic.** All data flows through `MediaProvider`. No
  Jellyfin- or Plex-specific code paths above the provider seam.
- **Server art first.** External art (`MetadataKit`) is used as a
  fallback via `CoreUI.FallbackAsyncImage`, never as the default — the
  server's own backdrop/logo is always tried first.
  Shared logo views pair fallback lookups with the source item/account and
  metadata query. Memoized logos and in-flight tasks also distinguish artwork
  preference, so a missing server logo never gives unrelated titles a shared
  cache entry. A reused view rejects the previous title's image immediately.
- **`LoadState` everywhere.** Loading / empty / failure rendering uses
  `CoreUI.ContentStateView` so all surfaces feel identical.
- **No tokens in logs.** Provider calls log only opaque ids — never
  authorisation headers.

## Foreground and return refresh

See [Foreground and return refresh](../../docs/feature-home/refresh-and-watch-state.md#foreground-and-return-refresh).

## Related loading

See [Related loading](../../docs/feature-home/detail-and-playback.md#related-loading).

## Continue Watching watch actions

See [Continue Watching watch actions](../../docs/feature-home/refresh-and-watch-state.md#continue-watching-watch-actions).

## Mobile Home loading geometry

See [Mobile Home loading geometry](../../docs/feature-home/home-rows-and-loading.md#mobile-home-loading-geometry).

## Inline library collections

See [Inline library collections](../../docs/feature-home/library-browsing.md#inline-library-collections).

## Browsing Home rows

See [Browsing Home rows](../../docs/feature-home/library-browsing.md#browsing-home-rows).

## Recently Added watched filtering

See [Recently Added watched filtering](../../docs/feature-home/home-rows-and-loading.md#recently-added-watched-filtering).

## Request status

See [Request status](../../docs/feature-home/detail-and-playback.md#request-status).

## Responsibility

Responsibilities are grouped by behavior in the task map above. Start with the matching guide rather than reading every topic.

## Home loading

See [Home loading](../../docs/feature-home/home-rows-and-loading.md#home-loading).

## Showcase

See [Showcase](../../docs/feature-home/presentation-and-showcase.md#showcase).

## Detail watch-state updates

See [Detail watch-state updates](../../docs/feature-home/refresh-and-watch-state.md#detail-watch-state-updates).
