import SwiftUI
import UIKit
import CoreUI
import CoreModels
import FeaturePlayback
@testable import FeatureSettings

@main
struct FocusHostApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--disc-review-fixture") {
                DiscReviewFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--detail-information-fixture") {
                DetailInformationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--discover-fixture") {
                DiscoverBrowseFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--profile-pin-transition-fixture") {
                ProfilePINTransitionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--large-native-navigation-fixture") {
                LargeNativeNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--reorder-input-fixture") {
                ReorderInputFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--home-section-warning-fixture") {
                HomeSectionWarningFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--home-section-editor-fixture") {
                HomeSectionsEditorFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--collection-row-editor-fixture") {
                CollectionRowEditorFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--playback-failure-fixture") {
                PlaybackFailureFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--setup-picker-fixture") {
                SetupPickerFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--setup-summary-fixture") {
                SetupSummaryFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--player-presentation-back-fixture") {
                PlayerPresentationBackFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--disc-menu-input-fixture") {
                DiscMenuInputFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--deep-link-resume-fixture") {
                DeepLinkResumeFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--server-address-fixture") {
                ServerAddressNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--read-ahead-settings-fixture") {
                PlaybackReadAheadFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--external-player-settings-fixture") {
                ExternalPlayerSettingsFixtureHost()
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
            } else if ProcessInfo.processInfo.arguments.contains("--empty-pinned-navigation-fixture") {
                EmptyPinnedNavigationFixture()
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
            } else if ProcessInfo.processInfo.arguments.contains("--live-jellyfin-home") {
                LiveJellyfinHomeFixture()
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

private struct ExternalPlayerSettingsFixtureHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ExternalPlayerFixtureController {
        ExternalPlayerFixtureController(rootView: ExternalPlayerSettingsFixture())
    }

    func updateUIViewController(_ controller: ExternalPlayerFixtureController, context: Context) {}
}

private final class ExternalPlayerFixtureController: UIHostingController<ExternalPlayerSettingsFixture> {
    var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

private struct ExternalPlayerSettingsFixture: View {
    @State private var model: ExternalPlayerSettingsModel = {
        let defaults = UserDefaults(suiteName: "external-player-settings-fixture")!
        defaults.removePersistentDomain(forName: "external-player-settings-fixture")
        let model = ExternalPlayerSettingsModel(defaults: defaults)
        model.settings.player = .nativePlayer
        return model
    }()
    @State private var failure: String?

    var body: some View {
        SettingsFormLayout(
            title: Text("External player"),
            rows: Array(ExternalPlayerSettingsRows.external(
                model: model, installedPlayers: Set(ExternalPlayer.supported)
            ).prefix(1))
        )
        .frame(width: SettingsFormMetrics.pageWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.themePalette, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .background(.black)
        .overlay(alignment: .top) {
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .task {
            do { try await verifyFocusPreview() }
            catch { failure = "Focus fixture failed: \(error)" }
        }
    }

    @MainActor private func verifyFocusPreview() async throws {
        let player: ExternalPlayer = ProcessInfo.processInfo.arguments.contains("--external-player-vlc") ? .vlc
            : ProcessInfo.processInfo.arguments.contains("--external-player-infuse") ? .infuse
            : ProcessInfo.processInfo.arguments.contains("--external-player-built-in") ? .builtIn : .nativePlayer
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow),
               let system = UIFocusSystem.focusSystem(for: window) {
                var containers: [any UIFocusItemContainer] = [window]
                var visited = Set<ObjectIdentifier>()
                var items: [ObjectIdentifier: any UIFocusItem] = [:]
                while let container = containers.popLast() {
                    guard visited.insert(ObjectIdentifier(container)).inserted else { continue }
                    for item in container.focusItems(in: container.coordinateSpace.convert(window.bounds, from: window)) {
                        if let child = item.focusItemContainer { containers.append(child) }
                        if let view = item as? UIView { containers.append(view) }
                        if item.canBecomeFocused, !(item is UIScrollView) { items[ObjectIdentifier(item)] = item }
                    }
                }
                let targets = items.values.compactMap { item -> ((any UIFocusItem), CGFloat)? in
                    var environment: (any UIFocusEnvironment)? = item
                    while let current = environment {
                        if let container = current.focusItemContainer {
                            return (item, container.coordinateSpace.convert(item.frame, to: window).minY)
                        }
                        environment = current.parentFocusEnvironment
                    }
                    return nil
                }.sorted { $0.1 < $1.1 }
                if targets.count == ExternalPlayer.supported.count,
                   let index = ExternalPlayer.supported.firstIndex(of: player),
                   let host = focusHost(in: window.rootViewController) {
                    let target = targets[index].0
                    host.target = target
                    system.requestFocusUpdate(to: host)
                    system.updateFocusIfNeeded()
                    try await Task.sleep(for: .milliseconds(400))
                    host.target = nil
                    guard system.focusedItem === target, model.settings.player == .nativePlayer else {
                        throw NSError(domain: "PlayerFocusFixture", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Focus did not reach \(player.rawValue) or selection changed."
                        ])
                    }
                    let report: [String: String] = ["focused": player.rawValue, "selected": model.settings.player.rawValue]
                    let url = URL.documentsDirectory.appendingPathComponent("external-player-focus.json")
                    try JSONEncoder().encode(report).write(to: url, options: .atomic)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "PlayerFocusFixture", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Player focus targets were not ready."
        ])
    }

    private func focusHost(in controller: UIViewController?) -> ExternalPlayerFixtureController? {
        guard let controller else { return nil }
        if let host = controller as? ExternalPlayerFixtureController { return host }
        return controller.children.lazy.compactMap { focusHost(in: $0) }.first
    }
}

private struct CollectionRowEditorFixture: View {
    @State private var visibility = HomeLibraryVisibilityModel(
        store: HomeLibraryVisibilityStore(namespace: "collection-row-editor-fixture")
    )
    @State private var navigation = SettingsPageNavigation<String>()
    @State private var provider: CollectionRowEditorProvider?

    var body: some View {
        SettingsPageStack(navigation: navigation, pageWidth: SettingsFormMetrics.pageWidth, onRootBack: {}) {
            if let provider {
                let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
                CollectionSectionSettingsView(
                    section: CollectionSection(
                        source: .init(
                            accountID: account.account.id, collectionID: "weekend", title: "Weekend picks",
                            serverUserID: provider.session.userID
                        ),
                        cardStyle: .landscape,
                        titleLogo: ProcessInfo.processInfo.arguments.contains("--collection-row-logo-on") ? .on : .default
                    ),
                    isNew: true, inventory: HomeSectionCatalogModel(), visibility: visibility,
                    libraries: [], accounts: [account]
                )
            } else {
                ProgressView()
            }
        } destination: { _ in EmptyView() }
        .environment(CardStyleSettingsModel())
        .environment(\.settingsInWorkspace, true)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .background { SettingsPageBackground() }
        .task {
            guard provider == nil else { return }
            let backgroundURL = URL(string: "https://collection-fixture.invalid/\(UUID())-background.png")!
            let logoURL = URL(string: "https://collection-fixture.invalid/\(UUID())-logo.png")!
            let background = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image {
                UIColor(red: 0.12, green: 0.24, blue: 0.36, alpha: 1).setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            }
            let logo = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 90)).image { _ in
                ("LOGO" as NSString).draw(at: CGPoint(x: 8, y: 2), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.white
                ])
            }
            guard let cache = ArtworkSession.shared.configuration.urlCache else {
                preconditionFailure("Collection fixture requires an artwork cache")
            }
            for (url, image) in [(backgroundURL, background), (logoURL, logo)] {
                guard let data = image.pngData() else { preconditionFailure("Fixture PNG encoding failed") }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
                )!
                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: data), for: URLRequest(url: url)
                )
            }
            provider = CollectionRowEditorProvider(background: backgroundURL, logo: logoURL)
        }
    }
}

private struct CollectionRowEditorProvider: MediaProvider {
    let background: URL
    let logo: URL
    let kind: ProviderKind = .jellyfin
    let session = UserSession(
        server: MediaServer(
            id: "fixture", name: "Sample library", baseURL: URL(string: "https://fixture.invalid")!,
            provider: .jellyfin
        ),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] {
        [("orbit", "Orbit"), ("crossing", "The Crossing")].map { id, title in
            MediaItem(
                id: id, title: title, kind: .movie, backdropURL: background, logoURL: logo,
                allowsTitleBasedMetadataMatching: false,
                artworkSelections: [.init(placement: .landscapeCard, references: [.remote(background)])]
            )
        }
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
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
            Group {
                if ProcessInfo.processInfo.arguments.contains("--row-style-page") {
                    HomeRowStyleSettingsView(libraries: [], accounts: [])
                } else if ProcessInfo.processInfo.arguments.contains("--spotlight-page") {
                    HomeHeroSettingsView(libraries: [], accounts: [], visibility: visibility)
                } else {
                    HomeRowsSettingsView(libraries: [], accounts: [], visibility: visibility)
                }
            }
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
