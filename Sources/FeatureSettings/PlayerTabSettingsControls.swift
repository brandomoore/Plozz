import CoreModels
import CoreUI
import SwiftUI

public struct PlayerTabSettingsControls: View {
    @Bindable private var model: PlaybackSettingsModel

    public init(model: PlaybackSettingsModel) {
        self.model = model
    }

    public var body: some View {
        #if os(tvOS)
        SettingsControlRows { controls }
        #else
        SettingsSectionGroup("Player tabs") { controls }
            .settingsSearchGroup(PlayerOptionalTab.allCases.map(\.searchAnchor))
        #endif
    }

    @ViewBuilder private var controls: some View {
        ForEach(PlayerOptionalTab.allCases, id: \.self) { tab in
            Toggle(isOn: binding(for: tab)) {
                Text(tab.title)
            }
            .settingsSearchAnchor(tab.searchAnchor)
            .accessibilityIdentifier(tab.searchAnchor)
        }
    }

    private func binding(for tab: PlayerOptionalTab) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: tab.visibilityKeyPath] },
            set: { model.settings[keyPath: tab.visibilityKeyPath] = $0 }
        )
    }
}
