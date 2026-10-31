import SwiftUI
import UIKit
import CoreUI
import CoreModels
import FeaturePlayback
import FeatureSettings

@main
struct FocusHostApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--tracker-history-import-fixture") {
                TrackerHistoryImportFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--publicmetadb-pairing-fixture") {
                PublicMetaDBPairingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--large-native-navigation-fixture") {
                LargeNativeNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--reorder-input-fixture") {
                ReorderInputFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--home-section-warning-fixture") {
                HomeSectionWarningFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--home-section-editor-fixture") {
                HomeSectionsEditorFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--playback-failure-fixture") {
                PlaybackFailureFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--setup-picker-fixture") {
                SetupPickerFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--setup-summary-fixture") {
                SetupSummaryFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--player-presentation-back-fixture") {
                PlayerPresentationBackFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--server-address-fixture") {
                ServerAddressNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--read-ahead-settings-fixture") {
                PlaybackReadAheadFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--skip-settings-fixture") {
                SkipSettingsFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--iptv-organization-fixture") {
                IPTVOrganizationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--category-search-fixture") {
                LiveTVCategorySearchFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--sync-erasure-fixture") {
                SyncErasureRemoteFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--preview-introduction-fixture") {
                LiveTVPreviewIntroductionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--sources-navigation-fixture") {
                LiveTVSourcesNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--channel-settings-fixture") {
                LibraryChannelSettingsFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--view-customization-fixture") {
                ViewCustomizationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--iptv-setup-fixture") {
                IPTVSetupFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--skip-marker-preview") {
                SkipMarkerPreviewFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--player-cast-focus-fixture") {
                PlayerCastFocusFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--share-folder-fixture") {
                ShareFolderBrowserFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--episode-breadcrumb-fixture") {
                EpisodeBreadcrumbFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--episode-row-fixture") {
                EpisodeRowRemoteFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--subtitle-style-input-fixture") {
                SubtitleStyleInputFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--home-layout-onboarding-fixture") {
                HomeLayoutOnboardingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--plex-home-onboarding-fixture") {
                PlexHomeOnboardingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--library-showcase-fixture") {
                LibraryShowcaseFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--library-held-scroll-fixture") {
                LibraryHeldScrollFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--family-guidance-fixture") {
                FamilyGuidanceFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--native-sidebar-handoff-fixture") {
                NativeSidebarHandoffFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--navigation-handoff-fixture") {
                NavigationDestinationHandoffFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--pinned-back-fixture") {
                PinnedNavigationBackFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--poster-caption-fixture") {
                PosterCaptionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--cast-focus-fixture") {
                CastFocusFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--guide-navigation-fixture") {
                GuideNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--channel-identity-fixture") {
                PlozzChannelIdentityFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--library-channel-actions") {
                LibraryChannelActionsFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--navigation-fixture") {
                NavigationRailFixture { Color.clear }
            } else if ProcessInfo.processInfo.arguments.contains("--production-home-fixture") {
                ProductionHomeFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--native-artwork-focus-comparison") {
                NativeArtworkFocusComparisonScreen()
            } else if ProcessInfo.processInfo.arguments.contains("--native-media-cell-comparison") {
                NativeMediaCellComparisonScreen()
            } else if ProcessInfo.processInfo.arguments.contains("--native-poster-comparison") {
                NativePosterComparisonScreen()
            } else if ProcessInfo.processInfo.arguments.contains("--focus-navigation-fixture") {
                SystemFocusNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--focus-style-fixture") {
                FocusStyleFixture()
            } else {
                Color.black
            }
        }
    }
}

private struct SkipSettingsFixture: View {
    @State private var playback: PlaybackSettingsModel
    @State private var navigation = SettingsPageNavigation<String>()

    init() {
        let store = PlaybackSettingsStore(namespace: "skip-settings-remote-fixture")
        store.save(.init(
            skipIntros: .autoInstant,
            skipMarkerRules: [.anime: [.intro: .init(mode: .on, automaticDelaySeconds: 5)]]
        ))
        _playback = State(initialValue: PlaybackSettingsModel(store: store))
    }

    var body: some View {
        SettingsPageStack(navigation: navigation, pageWidth: 960, onRootBack: {}) {
            SkipMarkerSettingsView(model: playback)
        } destination: { _ in EmptyView() }
        .environment(\.settingsInWorkspace, true)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .toggleStyle(SettingsSwitchToggleStyle())
        .background { SettingsPageBackground() }
    }
}

private struct HomeSectionWarningFixture: View {
    @State private var retries = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HomeSectionStatusView(issue: .init(
                choice: .init(
                    id: .server(accountID: "fixture", section: "picks"),
                    title: "Top picks", isProviderDefault: true
                ),
                reason: .failed(.serverUnreachable),
                serverName: "Living room server", providerKind: .jellyfin
            )) { retries += 1 }
            Text(verbatim: "Retries: \(retries)")
                .accessibilityIdentifier("section-warning-retries")
        }
        .padding(80)
    }
}

private struct HomeSectionsEditorFixture: View {
    @State private var visibility: HomeLibraryVisibilityModel

    init() {
        let visibility = HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(namespace: "home-section-remote-fixture")
        )
        visibility.useRowDefaults(.combined)
        if ProcessInfo.processInfo.arguments.contains("--single-home-row") {
            let choices = HomeRowChoice.shared
            visibility.applyRows(
                .init(
                    enabled: [.global(.continueWatching)],
                    disabled: choices.map(\.id).filter { $0 != .global(.continueWatching) }
                ),
                choices: choices
            )
        }
        _visibility = State(initialValue: visibility)
    }

    var body: some View {
        NavigationStack {
            HomeRowsSettingsView(libraries: [], accounts: [], visibility: visibility)
                .frame(width: SettingsFormMetrics.pageWidth)
        }
        .environment(HeroSettingsModel(store: InMemoryHeroSettingsStore()))
        .environment(HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore()))
        .environment(CardStyleSettingsModel())
    }
}

private struct ReorderInputFixture: View {
    @State private var sections = OrderedVisibilityList.Sections(enabled: Array(0..<24), disabled: [24, 25])
    @State private var isLifting = false
    @State private var positions: [Int] = []
    private var allowsHiding: Bool { ProcessInfo.processInfo.arguments.contains("--with-hidden-rows") }

    var body: some View {
        VStack(spacing: 24) {
            Button("Done") {}.disabled(isLifting)
            ScrollView {
                LiftableReorderList(
                    sections: .init(enabled: sections.enabled, disabled: allowsHiding ? sections.disabled : []),
                    disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden rows",
                    isLifting: $isLifting, allowsHiding: allowsHiding,
                    row: { .init(title: Text(verbatim: "Row \($0)")) },
                    onChange: {
                        sections = $0
                        if let index = $0.combined.firstIndex(of: 0) { positions.append(index) }
                    }
                )
                .padding(36)
            }
            Text(verbatim: "Position \(sections.combined.firstIndex(of: 0) ?? -1); hidden \(sections.disabled.contains(0))")
                .accessibilityIdentifier("reorder-fixture-position")
                .accessibilityValue(Text(verbatim: positions.map(String.init).joined(separator: ",")))
        }
        .frame(width: 960)
        .padding(.vertical, 60)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
    }
}

private struct SkipMarkerPreviewFixture: View {
    @State private var showsPreview = true

    var body: some View {
        if showsPreview {
            PlayerSkipMarkerPreview { showsPreview = false }
        } else {
            Text(verbatim: "Preview closed")
                .accessibilityIdentifier("marker-preview-closed")
        }
    }
}

private struct FocusStyleFixture: View {
    private var mode: String { ProcessInfo.processInfo.arguments.last ?? "" }

    private var artwork: some View {
        Color.red.frame(width: 240, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private var nativeImage: some View {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
        }
        return Image(uiImage: image).resizable().frame(width: 240, height: 360)
    }

    var body: some View {
        Group {
            if mode == "production" || mode == "production-circle" {
                ProductionFocusFixture(circular: mode == "production-circle")
            } else if mode == "uikit" || mode == "uikit-ancestor" {
                UIKitFocusReference(ownsFocus: mode == "uikit")
                    .frame(width: 240, height: 360)
                    .focusable(mode == "uikit-ancestor")
            } else if mode == "automatic" {
                Button {} label: {
                    nativeImage
                    Text("Focus reference")
                }
                .buttonStyle(.borderless)
            } else if mode == "card" {
                Button {} label: {
                    VStack {
                        nativeImage
                        Text("Focus reference")
                    }
                }

                .buttonStyle(.card)
            } else if mode == "native" {
                Button {} label: {
                    artwork.hoverEffect(.highlight)
                    Text("Focus reference")
                }
                .buttonStyle(.borderless)
            } else {
                VStack(spacing: 32) {
                    artwork.hoverEffect(mode == "highlight" ? .highlight : .lift)
                    Text("Focus reference")
                }
                .focusable()
                .focusEffectDisabled(false)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

private struct ProductionFocusFixture: View {
    let circular: Bool
    @PlozzCardFocus private var focused: Bool
    @State private var activations = 0

    var body: some View {
        let radius: CGFloat = circular ? 100 : 28
        VStack(spacing: 40) {
            Color.red
                .frame(width: circular ? 200 : 240, height: circular ? 200 : 360)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .plozzSystemCardProjection(cornerRadius: radius)
                .focusableCard(isFocused: $focused, cornerRadius: radius) { activations += 1 }
                .accessibilityLabel("System card")
                .contextMenu {
                    Button("Context action") { activations += 100 }
                }
            Text("Activated \(activations)")
        }
        .environment(\.plozzCardFocusStyle, .system)
    }
}

private struct UIKitFocusReference: UIViewRepresentable {
    var ownsFocus = true
    func makeUIView(context: Context) -> FocusContainer {
        let view = FocusContainer()
        view.ownsFocus = ownsFocus
        return view
    }
    func updateUIView(_ view: FocusContainer, context: Context) {}

    final class FocusContainer: UIView {
        let imageView = UIImageView()
        var ownsFocus = true
        override var canBecomeFocused: Bool { ownsFocus }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360)).image { _ in
                UIColor.red.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 240, height: 360), cornerRadius: 28).fill()
            }
            imageView.image = image
            imageView.adjustsImageWhenAncestorFocused = true
            imageView.masksFocusEffectToContents = true
            addSubview(imageView)
            isAccessibilityElement = true
            accessibilityLabel = "UIKit focus reference"
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
        }
    }
}
