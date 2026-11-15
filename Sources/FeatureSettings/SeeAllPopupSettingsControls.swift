#if os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

/// The See all screens' layout and pop-up timing, shared by every library and Home row.
struct SeeAllPopupSettingsControls: View {
    @Bindable var model: LibraryPresentationSettingsModel

    private static func delayLabel(_ seconds: Double) -> String {
        let whole = seconds.truncatingRemainder(dividingBy: 1) == 0
        return Duration.seconds(seconds).formatted(.units(
            allowed: [.seconds], width: .narrow, fractionalPart: whole ? .hide : .show(length: 1)))
    }

    var body: some View {
        let showsDelay = model.settings.seeAllLayout == .gridWithPopup || model.settings.searchPopupEnabled
        SettingsMenuRow(
            title: "See all layout", value: Text(model.settings.seeAllLayout.displayName),
            minimumContentHeight: 44
        ) {
            Picker("See all layout", selection: $model.settings.seeAllLayout) {
                ForEach(SeeAllLayout.allCases, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
        }
        // The delay row exists only while a pop-up is on; search for it lands here otherwise.
        .settingsSearchAnchor("see-all-layout", fallbackFor: showsDelay ? [] : ["see-all-popup-delay"])
        .accessibilityIdentifier("see-all-layout")
        Toggle("Pop-up details in search", isOn: $model.settings.searchPopupEnabled)
            .settingsSearchAnchor("search-popup")
            .accessibilityIdentifier("search-popup")
        if showsDelay {
            SettingsMenuRow(
                title: "Pop-up delay", value: Text(verbatim: Self.delayLabel(model.settings.seeAllPopupDelay)),
                minimumContentHeight: 44
            ) {
                Picker("Pop-up delay", selection: $model.settings.seeAllPopupDelay) {
                    ForEach(LibraryPresentationSettings.popupDelayChoices, id: \.self) { seconds in
                        Text(verbatim: Self.delayLabel(seconds)).tag(seconds)
                    }
                }
            }
            .settingsSearchAnchor("see-all-popup-delay")
            .accessibilityIdentifier("see-all-popup-delay")
        }
    }
}
#endif
