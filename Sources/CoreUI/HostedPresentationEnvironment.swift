#if canImport(SwiftUI)
import SwiftUI

public extension EnvironmentValues {
    /// Cross hosting boundaries without copying SwiftUI's private accessibility tree.
    mutating func copyHostedPresentation(from source: EnvironmentValues) {
        colorScheme = source.colorScheme
        locale = source.locale
        layoutDirection = source.layoutDirection
        dynamicTypeSize = source.dynamicTypeSize
        displayScale = source.displayScale
        isEnabled = source.isEnabled
        redactionReasons = source.redactionReasons
        scenePhase = source.scenePhase
        themePalette = source.themePalette
        gradientBackgroundsEnabled = source.gradientBackgroundsEnabled
        plozzShowsContentRatings = source.plozzShowsContentRatings
        artworkGradientTintSaturation = source.artworkGradientTintSaturation
        plozzMetrics = source.plozzMetrics
        plozzCardStyle = source.plozzCardStyle
        plozzCardFocusStyle = source.plozzCardFocusStyle
        copyCardCaptionPresentation(from: source)
        plozzContinueWatchingPlaybackDetails = source.plozzContinueWatchingPlaybackDetails
        plozzArtworkSettings = source.plozzArtworkSettings
        plozzArtworkProviders = source.plozzArtworkProviders
        plozzArtworkArea = source.plozzArtworkArea
        plozzWatchStatusIndicator = source.plozzWatchStatusIndicator
        plozzWatchIndicatorColor = source.plozzWatchIndicatorColor
        plozzShowsUnwatchedEpisodeCount = source.plozzShowsUnwatchedEpisodeCount
        plozzShowsProgressBars = source.plozzShowsProgressBars
        plozzEpisodeCountBadgeStyle = source.plozzEpisodeCountBadgeStyle
        plozzSeerConnected = source.plozzSeerConnected
        plozzReduceTransparency = source.plozzReduceTransparency
        plozzNavigationStyle = source.plozzNavigationStyle
        plozzNavigationContentInset = source.plozzNavigationContentInset
        plozzTopNavigationContentInsets = source.plozzTopNavigationContentInsets
        plozzTopNavigationScroll = source.plozzTopNavigationScroll
        mediaRowHeaderTrailingInset = source.mediaRowHeaderTrailingInset
        plozzPinnedSidebarActive = source.plozzPinnedSidebarActive
        plozzPinnedSidebarInteraction = source.plozzPinnedSidebarInteraction
        plozzRowTitleTightening = source.plozzRowTitleTightening
        plozzRowTitleOffset = source.plozzRowTitleOffset
        mediaItemActionHandler = source.mediaItemActionHandler
        mediaItemActionContext = source.mediaItemActionContext
        mediaItemNavigator = source.mediaItemNavigator
    }
}
#endif
