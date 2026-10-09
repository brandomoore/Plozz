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
        plozzMetrics = source.plozzMetrics
        plozzCardStyle = source.plozzCardStyle
        plozzCardFocusStyle = source.plozzCardFocusStyle
        copyCardCaptionPresentation(from: source)
        plozzArtworkSettings = source.plozzArtworkSettings
        plozzArtworkProviders = source.plozzArtworkProviders
        plozzArtworkArea = source.plozzArtworkArea
        plozzWatchStatusIndicator = source.plozzWatchStatusIndicator
        plozzSeerConnected = source.plozzSeerConnected
        plozzReduceTransparency = source.plozzReduceTransparency
        plozzNavigationStyle = source.plozzNavigationStyle
        plozzNavigationContentInset = source.plozzNavigationContentInset
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
