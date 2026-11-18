import CoreModels
import CoreUI
import SwiftUI
@testable import AppShell
@testable import FeatureLiveTV
@testable import FeatureSettings

struct EmptyPinnedNavigationFixture: View {
    @State private var selection: NavigationRailDestination
    @State private var chrome = NavigationChromeModel()
    @State private var settings = SettingsNavigationModel()
    @State private var playbackHasNativeFocus = false

    init() {
        let prefix = "--empty-pinned-start="
        let raw = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) } ?? "home"
        _selection = State(initialValue: NavigationRailDestination(storageValue: raw) ?? .home)
    }

    var body: some View {
        NavigationRailShell(
            profile: Profile(name: "Empty libraries"), entries: [],
            destinations: [.home, .liveTV, .settings], selection: $selection,
            onOpenProfileSwitcher: {}, chrome: chrome,
            content: pages, contentDestination: selection
        )
        .environment(chrome)
        .environment(\.plozzNavigationStyle, .rail)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottomTrailing) {
            Text(playbackHasNativeFocus ? "playback" : "outside")
                .accessibilityIdentifier("empty-pinned-native-focus")
                .allowsHitTesting(false)
        }
    }

    private var pages: some View {
        let live = selection == .liveTV
        return ZStack {
            Group {
                if selection == .settings {
                    SettingsWorkspace(navigation: settings) {
                        ScrollView {
                            SettingsSectionGroup {
                                SettingsSectionButton(
                                    title: Text("Playback"), icon: "play", route: .playback
                                )
                                .background {
                                    NativeFocusRegionObserver(
                                        onFocusExited: { playbackHasNativeFocus = false }
                                    ) {
                                        playbackHasNativeFocus = true
                                    }
                                }
                                SettingsSectionButton(
                                    title: Text("Subtitles"), icon: "captions.bubble", route: .subtitles
                                )
                            }
                        }
                    } detail: { _ in
                        Button("Settings detail") {}
                    }
                } else if !live {
                    ContentStateView(state: LoadState<Int>.empty, onRetry: {}) { _ in
                        EmptyView()
                    }
                }
            }
            .opacity(live ? 0 : 1)
            .disabled(live)
            .allowsHitTesting(!live)
            .accessibilityHidden(live)

            RetainedLiveTVDestination(isActive: live) {
                LiveTVSetupWelcome(addPlaylist: {}, useServer: {}, createChannel: {})
            }
            .opacity(live ? 1 : 0)
            .disabled(!live)
            .allowsHitTesting(live)
            .accessibilityHidden(!live)
        }
    }
}
