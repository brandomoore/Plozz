#if os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

struct TopShelfSettingsView: View {
    @Bindable var model: TopShelfSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.controlSpacing) {
                SettingsPageHeader("Top Shelf")
                SettingsControlGroup {
                    Toggle(isOn: $model.settings.isEnabled) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Show Top Shelf")
                            Text("Place Plozz in the top row of your Apple TV Home Screen to see Continue Watching and Recently Added titles above the app icons.")
                                .font(SettingsRowMetrics.helperFont)
                                .settingsRowSecondary()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("top-shelf-enabled")
                    .settingsSearchAnchor(
                        "top-shelf-enabled",
                        fallbackFor: model.settings.isEnabled
                            ? [] : ["top-shelf-style", "top-shelf-continue", "top-shelf-recent"]
                    )
                }
                if model.settings.isEnabled {
                    TopShelfStylePicker(usesFullScreen: $model.settings.usesFullScreen)
                    SettingsControlGroup {
                        SettingsStepper(
                            options: Array(TopShelfSettings.itemCountRange),
                            selection: $model.settings.continueWatchingItems,
                            compact: true, label: "Continue Watching",
                            verbatimTitle: { $0.formatted() }
                        )
                        .accessibilityIdentifier("top-shelf-continue-watching").settingsSearchAnchor("top-shelf-continue")
                        SettingsStepper(
                            options: Array(TopShelfSettings.itemCountRange),
                            selection: $model.settings.recentlyAddedItems,
                            compact: true, label: "Recently Added",
                            verbatimTitle: { $0.formatted() }
                        )
                        .accessibilityIdentifier("top-shelf-recently-added").settingsSearchAnchor("top-shelf-recent")
                    }
                    if model.settings.usesFullScreen {
                        Text("Swipe up on the Apple TV Home Screen to open the full-screen view. Continue Watching appears first, followed by Recently Added.")
                            .font(SettingsRowMetrics.helperFont)
                            .plozzForeground(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
        }
        .scrollClipDisabled()
    }
}
#endif
