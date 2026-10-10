@testable import CoreUI
@testable import AppShell
import Observation
import SwiftUI
import UIKit
import TVUIKit
import XCTest
import CoreModels

@MainActor
final class NativeFocusRequestHostedTests: XCTestCase {
    func testNavigationCallbackRefreshKeepsIdentityAndUsesLatestRoute() async throws {
        let fixture = try await makeFixture()
        let state = NavigatorRefreshState()
        defer {
            state.navigator = nil
            fixture.close()
        }
        let menus = CountingMenuHandler()
        fixture.window.rootViewController = UIHostingController(
            rootView: NavigatorRefreshFixture(
                state: state,
                content: Button("Menu") {}
                    .mediaItemContextMenu(for: state.item)
                    .background(NavigatorProbe(state: state))
            ).mediaItemActionHandler(menus)
        )
        fixture.window.layoutIfNeeded()
        try await waitUntil { menus.builds.count == 1 && state.navigator != nil }
        try await Task.sleep(for: .milliseconds(300))
        let before = state.navigator
        state.revision = 1
        try await Task.sleep(for: .milliseconds(100))
        let item = MediaItem(id: "menu", title: "Menu", kind: .movie)
        state.navigator?(item)
        XCTAssertEqual(state.receivedRevision, 1, "The stable router must dispatch the latest callback, not a stale capture.")
        XCTAssertEqual(state.navigator, before, "Callback updates must not invalidate the navigator environment value.")
        state.enabled = false
        try await waitUntil { state.navigator == nil }
        state.receivedRevision = nil
        before?(item)
        XCTAssertNil(state.receivedRevision, "A retained router must not dispatch after navigation is disabled.")
        state.enabled = true
        state.revision = 2
        try await waitUntil { state.navigator != nil }
        state.navigator?(item)
        XCTAssertEqual(state.receivedRevision, 2)
    }

    @Observable final class NavigatorRefreshState {
        let item = MediaItem(id: "menu", title: "Menu", kind: .movie)
        var revision = 0
        var enabled = true
        @ObservationIgnored var navigator: MediaItemNavigator?
        @ObservationIgnored var receivedRevision: Int?
    }

    private struct NavigatorRefreshFixture<Content: View>: View {
        let state: NavigatorRefreshState
        let content: Content
        var body: some View {
            content
                .mediaItemNavigator(state.enabled ? { [revision = state.revision] _ in
                    state.receivedRevision = revision
                } : nil)
        }
    }

    private struct NavigatorProbe: View {
        let state: NavigatorRefreshState
        @Environment(\.mediaItemNavigator) private var navigator
        var body: some View {
            state.navigator = navigator
            return Color.clear
        }
    }

    func testNavigatorReleasesReplacedCallbacksAndRemovedScope() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let state = NavigatorLifetimeState()
        var first: NavigatorLifetimeToken? = NavigatorLifetimeToken()
        weak var firstReference = first
        state.route = { [token = first!] _ in token.calls += 1 }
        first = nil
        fixture.window.rootViewController = UIHostingController(rootView: NavigatorLifetimeFixture(state: state))
        fixture.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        var second: NavigatorLifetimeToken? = NavigatorLifetimeToken()
        weak var secondReference = second
        state.route = { [token = second!] _ in token.calls += 1 }
        second = nil
        try await waitUntil { firstReference == nil }
        fixture.close()
        state.route = nil
        try await waitUntil { secondReference == nil }
    }

    @Observable final class NavigatorLifetimeState {
        var route: ((MediaItem) -> Void)?
    }

    private final class NavigatorLifetimeToken {
        var calls = 0
    }

    private struct NavigatorLifetimeFixture: View {
        let state: NavigatorLifetimeState
        var body: some View {
            Color.clear.mediaItemNavigator(state.route)
        }
    }

    func testCallbackOnlyRowFocusDoesNotRebuildItsCardInputs() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var builds: [String: Int] = [:]
        var selected: [String] = []
        let menus = CountingMenuHandler()
        let host = PreferredPosterHost(rootView: AnyView(
            VStack(spacing: 60) {
                ForEach(0..<2) { row in
                    MediaRowView(
                        title: Text("Row \(row)"),
                        items: (0..<3).map {
                            MediaItem(id: "r\(row)-\($0)", title: "Item \(row)-\($0)", kind: .movie)
                        },
                        style: .landscape,
                        onFocusChange: { if let item = $0 { selected.append(item.id) } },
                        onCardFocused: { _ in },
                        statusCue: {
                            builds[$0.id, default: 0] += 1
                            return nil
                        },
                        onSelect: { _ in }
                    )
                }
            }
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .mediaItemActionHandler(menus)
        ))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        try await waitUntil { self.lockups(in: host.view).count == 6 }
        let posters = lockups(in: host.view)
        let first = try XCTUnwrap(posters.first { $0.accessibilityLabel == "Item 0-0" })
        let second = try XCTUnwrap(posters.first { $0.accessibilityLabel == "Item 1-0" })
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
        host.target = first
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await waitUntil { first.isFocused && selected.contains("r0-0") }
        try await Task.sleep(for: .milliseconds(200))
        let before = builds
        let menusBefore = menus.builds
        host.target = second
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await waitUntil { second.isFocused && selected.contains("r1-0") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(builds, before, "Focus callbacks and prefetch bookkeeping must not rebuild all card inputs.")
        XCTAssertEqual(menus.builds, menusBefore, "Focus alone must not rebuild card actions.")
    }

    private final class CountingMenuHandler: MediaItemActionHandling {
        var builds: [String: Int] = [:]
        func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
            builds[item.id, default: 0] += 1
            return [.markWatched, .addToWatchlist]
        }
        func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
    }

    private final class PreferredPosterHost: UIHostingController<AnyView> {
        weak var target: UIView?
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    func testNativeFocusMovementDoesNotRebuildUnfocusedPosterOwners() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let counts = (0..<3).map { _ in FocusReadCounts() }
        let host = UIHostingController(rootView:
            HStack(spacing: 100) {
                ForEach(0..<3) { index in
                    NativeFocusReadOwner(counts: counts[index], title: "\(index)")
                }
            }
            .environment(\.plozzCardFocusStyle, .system)
        )
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        let posters = lockups(in: host.view)
        XCTAssertEqual(posters.count, 3)
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
        system.requestFocusUpdate(to: posters[0])
        system.updateFocusIfNeeded()
        try await waitUntil { posters[0].isFocused }
        try await Task.sleep(for: .milliseconds(100))
        let before = counts.map(\.ownerEvaluations)
        try XCTUnwrap(counts[1].focus).focusState.wrappedValue = true
        try await waitUntil { posters[1].isFocused }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counts[2].ownerEvaluations, before[2], "An unrelated card must not rebuild.")
        XCTAssertEqual(counts[0].ownerEvaluations, before[0], "Only the old card's focus reader must update.")
        XCTAssertEqual(counts[1].ownerEvaluations, before[1], "Only the new card's focus reader must update.")
    }

    private struct NativeFocusReadOwner: View {
        let counts: FocusReadCounts
        let title: String
        @PlozzCardFocus private var focused

        var body: some View {
            counts.ownerEvaluations += 1
            return NativeTVPoster(
                image: nil, treatment: .original, aspectRatio: 2,
                fallbackWidth: 300, title: .content(title), subtitle: nil,
                overlay: FocusReadChild(counts: counts, focus: $focused),
                focus: $focused, action: {}
            )
            .focused($focused.focusState)
            .frame(width: 300, height: 150)
            .onAppear { counts.focus = $focused }
        }
    }

    func testNativeFocusObservationInvalidatesOnlyItsReader() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let counts = FocusReadCounts()
        fixture.window.rootViewController = UIHostingController(rootView: FocusReadOwner(counts: counts))
        fixture.window.layoutIfNeeded()
        try await waitUntil { counts.focus != nil }
        let initial = counts.ownerEvaluations
        let focus = try XCTUnwrap(counts.focus)
        focus.observation.isFocused = true
        try await waitUntil { counts.observedFocus }
        focus.observation.isFocused = false
        try await waitUntil { !counts.observedFocus }
        XCTAssertEqual(
            counts.ownerEvaluations, initial,
            "Native focus must not rebuild the artwork/menu owner when only a child reads focus."
        )
    }

    final class FocusReadCounts {
        var ownerEvaluations = 0
        var observedFocus = false
        var focus: PlozzCardFocus.Binding?
    }

    private struct FocusReadOwner: View {
        let counts: FocusReadCounts
        @PlozzCardFocus private var focused

        var body: some View {
            counts.ownerEvaluations += 1
            return FocusReadChild(counts: counts, focus: $focused)
                .onAppear { counts.focus = $focused }
                .environment(\.plozzCardFocusStyle, .system)
        }
    }

    private struct FocusReadChild: View {
        let counts: FocusReadCounts
        let focus: PlozzCardFocus.Binding

        var body: some View {
            Color.clear
                .onChange(of: focus.isFocused, initial: true) { _, value in
                    counts.observedFocus = value
                }
        }
    }

    func testPosterOverlayCacheKeepsLiveContentAndDisplayScale() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = RasterOverlayModel()
        let host = UIHostingController(rootView: RasterOverlayFixture(model: model))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        let poster = try XCTUnwrap(lockups(in: host.view).compactMap { $0 as? TVPosterView }.first)
        let overlay = try XCTUnwrap(poster.imageView.overlayContentView.subviews.first)
        try await waitUntil { !overlay.bounds.isEmpty }
        XCTAssertTrue(overlay.layer.shouldRasterize)
        XCTAssertEqual(overlay.layer.rasterizationScale, 1)
        func pixels() throws -> Data {
            let image = UIGraphicsImageRenderer(bounds: overlay.bounds).image { _ in
                XCTAssertTrue(overlay.drawHierarchy(in: overlay.bounds, afterScreenUpdates: true))
            }
            return try XCTUnwrap(image.pngData())
        }
        let before = try pixels()
        model.updated = true
        model.scale = 2
        try await waitUntil { overlay.layer.rasterizationScale == 2 }
        fixture.window.layoutIfNeeded()
        XCTAssertTrue(poster.imageView.overlayContentView.subviews.first === overlay)
        XCTAssertNotEqual(try pixels(), before, "Cached overlays must repaint updated watch/progress content.")
    }

    @Observable
    final class RasterOverlayModel {
        var updated = false
        var scale: CGFloat = 1
    }

    private struct RasterOverlayFixture: View {
        let model: RasterOverlayModel
        @PlozzCardFocus private var focused

        var body: some View {
            NativeTVPoster(
                image: nil, treatment: .original, aspectRatio: 2,
                fallbackWidth: 400, title: .content("Overlay"), subtitle: nil,
                overlay: model.updated ? Color.green : Color.red,
                focus: $focused, action: {}
            )
            .frame(width: 400, height: 200)
            .environment(\.displayScale, model.scale)
        }
    }

    func testLoadingCardFocusStyleAndPresentationMatrix() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var count = 0
        for focusStyle in CardFocusStyle.allCases {
            for cardStyle in CardStyle.allCases {
                for (name, style, seriesArtwork, caption) in [
                    ("series", SkeletonCardView.Style.landscape, true, false),
                    ("series-caption", .landscape, true, true),
                    ("episode-caption", .landscape, false, true),
                    ("episode-no-caption", .landscape, false, false),
                    ("poster-caption", .poster, false, true),
                    ("poster-no-caption", .poster, false, false)
                ] {
                    let label = "\(focusStyle.rawValue)-\(cardStyle.rawValue)-\(name)"
                    let model = SkeletonFocusMatrixModel()
                    defer {
                        model.focus = nil
                        model.focusAnchor = nil
                    }
                    let host = UIHostingController(rootView:
                        SkeletonFocusMatrixView(
                            model: model, style: style,
                            seriesArtwork: seriesArtwork, caption: caption
                        )
                        .environment(\.plozzCardStyle, cardStyle)
                        .environment(\.plozzCardFocusStyle, focusStyle)
                        .environment(\.themePalette, .dark)
                    )
                    host.overrideUserInterfaceStyle = .dark
                    fixture.window.rootViewController = host
                    fixture.window.layoutIfNeeded()
                    try await waitUntil { model.focus != nil && model.frame.width > 0 }
                    model.focusAnchor?()
                    try await waitUntil { model.anchorFocused }
                    let resting = model.frame
                    let neighbor = model.neighborFrame
                    model.focus?.requestFocus(animated: false)
                    try await waitUntil(diagnostic: { label }) { model.isFocused }
                    try await Task.sleep(for: .milliseconds(300))
                    XCTAssertEqual(model.frame.width, resting.width, accuracy: 0.5, label)
                    XCTAssertEqual(model.frame.height, resting.height, accuracy: 0.5, label)
                    XCTAssertEqual(model.neighborFrame, neighbor, label)
                    XCTAssertNotNil(UIFocusSystem.focusSystem(for: fixture.window)?.focusedItem, label)

                    let controls = lockups(in: host.view)
                    if focusStyle.usesSystemEffect {
                        let control = try XCTUnwrap(controls.first(where: \.isEnabled), label)
                        XCTAssertTrue(control.isFocused, label)
                        XCTAssertEqual(controls.filter(\.isEnabled).count, 1, label)
                        if cardStyle == .borderless {
                            let poster = try XCTUnwrap(control as? TVPosterView, label)
                            let aspect: CGFloat = style == .poster ? 2 / 3
                                : seriesArtwork ? ContinueWatchingCardShape.aspectRatio : 16 / 9
                            XCTAssertEqual(poster.imageView.bounds.width / poster.imageView.bounds.height,
                                           aspect, accuracy: 0.01, label)
                            let surface = poster.imageView.overlayContentView
                            let hosted = try XCTUnwrap(surface.subviews.first, label)
                            let projected = hosted.convert(hosted.bounds, to: poster.imageView)
                            XCTAssertEqual(projected, surface.convert(surface.bounds, to: poster.imageView), label)
                            XCTAssertEqual(projected.midX, poster.imageView.bounds.midX, accuracy: 0.5, label)
                            XCTAssertEqual(projected.midY, poster.imageView.bounds.midY, accuracy: 0.5, label)
                        } else {
                            XCTAssertTrue(control is TVCardView, label)
                        }
                    } else {
                        XCTAssertTrue(controls.isEmpty, "Custom focus must not also apply a system effect: \(label)")
                    }
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    let image = UIGraphicsImageRenderer(size: fixture.window.bounds.size, format: format).image { _ in
                        XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "loading-focus-\(label)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    model.focusAnchor?()
                    try await waitUntil { model.anchorFocused && !model.isFocused }
                    XCTAssertEqual(model.frame, resting, label)
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, CardFocusStyle.allCases.count * CardStyle.allCases.count * 6)
    }

    private func lockups(in view: UIView) -> [TVLockupView] {
        (view as? TVLockupView).map { [$0] } ?? view.subviews.flatMap(lockups(in:))
    }

    func testFractionalPosterHeightCannotRoundDownIntoItsCaption() {
        let poster = NativeTVPoster<EmptyView>.Poster(image: nil)
        let size = CGSize(width: 388, height: 218.25)
        poster.contentSize = size
        let container = NativeTVPoster<EmptyView>.Container(poster: poster)
        XCTAssertEqual(container.intrinsicContentSize, CGSize(width: 388, height: 219))
        XCTAssertEqual(poster.contentSize, size, "Rounding the layout slot must not enlarge the image.")
    }

    func testNativePosterLayoutSlotDoesNotChangeWhenFocusMarginsSettle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let size = CGSize(width: 388, height: 264)
        let image = UIGraphicsImageRenderer(size: size).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(origin: .zero, size: size))
        }
        let poster = NativeTVPoster<EmptyView>.Poster(image: image)
        poster.contentSize = size
        _ = poster.imageView.overlayContentView
        let container = NativeTVPoster<EmptyView>.Container(poster: poster)
        let initial = container.intrinsicContentSize
        container.frame = CGRect(origin: CGPoint(x: 200, y: 200), size: initial)
        let controller = UIViewController()
        fixture.window.rootViewController = controller
        controller.view.addSubview(container)
        container.layoutIfNeeded()
        poster.layoutIfNeeded()
        container.layoutIfNeeded()
        XCTAssertEqual(container.intrinsicContentSize, initial,
                       "Native focus clearance must not change the lazy row's height after realization.")
        XCTAssertEqual(container.intrinsicContentSize, size,
                       "Both axes of the layout slot describe artwork, not native focus margins.")
        let artwork = poster.imageView.convert(poster.imageView.bounds, to: container)
        XCTAssertEqual(artwork.midX, container.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(artwork.midY, container.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(poster.imageView.bounds.height, size.height, accuracy: 0.5)
    }

    private final class BitmapProbe {
        var createdImages: [UIImage?] = []
    }

    private struct BitmapCreationProbe: UIViewRepresentable {
        let image: UIImage?
        let probe: BitmapProbe

        func makeUIView(context: Context) -> UIView {
            probe.createdImages.append(image)
            return UIView()
        }

        func updateUIView(_ view: UIView, context: Context) {}
    }

    private final class LogoHostProbe {
        var updates = 0
        weak var view: UIView?
    }

    private struct LogoHostFixture: UIViewRepresentable {
        let logo: ContinueWatchingSeriesLogo
        let probe: LogoHostProbe

        func makeUIView(context: Context) -> UIView {
            let view = UIHostingConfiguration { logo }.margins(.all, 0).makeContentView()
            probe.view = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {
            guard let content = view as? any UIContentView else {
                XCTFail("Expected the logo's SwiftUI hosting content view")
                return
            }
            probe.updates += 1
            content.configuration = UIHostingConfiguration { logo }.margins(.all, 0)
        }
    }

    func testContinueWatchingLogoResolutionStaysInsideItsHostedOverlay() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try XCTUnwrap(URL(string: "https://logo-scope.example.test/\(UUID()).png"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 10, y: 10, width: 140, height: 60))
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let request = URLRequest(url: url)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
            for: request
        )
        defer { cache.removeCachedResponse(for: request) }
        let references = [ArtworkReference.remote(url)]
        let key = HeroLogoMemo.key(
            for: references,
            providerPolicyIdentity: ArtworkPresentationPolicy().forPlacement(.logo).identity
        )
        XCTAssertNil(HeroLogoMemo.value(for: key))
        let probe = LogoHostProbe()
        let host = UIHostingController(rootView: LogoHostFixture(
            logo: ContinueWatchingSeriesLogo(
                title: Text(verbatim: "Series logo"),
                logoReferences: references,
                artworkReferences: references,
                artworkVariant: .landscapeCard,
                asyncFallbackURL: nil
            ),
            probe: probe
        ).frame(width: 388, height: 264))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        let overlay = try XCTUnwrap(probe.view)
        let initialBounds = overlay.bounds
        let initialUpdates = probe.updates
        XCTAssertGreaterThan(initialUpdates, 0)
        try await waitUntil { HeroLogoMemo.value(for: key) != nil }
        let sample = await HeroBackgroundSampler.sample(
            references: references, region: ContinueWatchingCardShape.logoSampleRegion,
            variant: .landscapeCard
        )
        XCTAssertNotNil(sample)
        try await Task.sleep(for: .milliseconds(350))
        fixture.window.layoutIfNeeded()
        XCTAssertEqual(probe.updates, initialUpdates, "Logo and backdrop tones must not reconfigure their UIKit host.")
        XCTAssertTrue(probe.view === overlay)
        XCTAssertEqual(overlay.bounds, initialBounds)
    }

    @Observable
    fileprivate final class BitmapFixtureModel {
        var references: [ArtworkReference] = []
        var focus: PlozzCardFocus.Binding?
    }

    private struct BitmapFixture: View {
        let model: BitmapFixtureModel
        let artworkPolicy: ArtworkPresentationPolicy
        @PlozzCardFocus private var focused

        var body: some View {
            FallbackAsyncImage(
                references: model.references, variant: .posterCard, artworkPolicy: artworkPolicy,
                pinIdentity: "native-bitmap-fixture",
                content: { _ in EmptyView() }, placeholder: { EmptyView() }
            )
            .resolvedBitmap { image in
                NativeTVPoster(
                    image: image, treatment: .original, aspectRatio: 2.0 / 3,
                    fallbackWidth: 280, title: .content("Native artwork"), subtitle: nil,
                    overlay: EmptyView(), focus: $focused, action: {}
                )
                .focused($focused.focusState)
            }
            .frame(width: 280)
            .onAppear { model.focus = $focused }
        }
    }

    private actor StalledThenRecoveredArtworkLoader: ArtworkNetworkFileLoading {
        let data: Data
        private var calls = 0
        private var released = false
        private var blocked: CheckedContinuation<Void, Never>?

        init(data: Data) { self.data = data }

        func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data {
            calls += 1
            if calls == 1, !released {
                await withCheckedContinuation { blocked = $0 }
            }
            return data
        }

        func release() {
            released = true
            blocked?.resume()
            blocked = nil
        }
    }

    func testVisiblePosterRecoversAfterSharedLoadExpiresWithoutRecreationOrFocusLoss() async throws {
        let fixture = try await makeFixture()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let loader = StalledThenRecoveredArtworkLoader(data: try XCTUnwrap(image.jpegData(compressionQuality: 0.9)))
        let cache = ArtworkImageCache.shared
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer {
            fixture.close()
            cache.configure(networkFileService: nil)
            Task { await loader.release() }
        }
        let account = UUID().uuidString
        let reference = ArtworkReference.networkFile(try NetworkArtworkReference(
            accountID: account,
            credentialRevision: CredentialRevision(),
            catalogArtworkID: "hosted-recovery",
            representation: RemoteFileRepresentation(
                size: 1_024,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                consistency: .changeDetecting
            ),
            sourceRevision: UUID().uuidString
        ))
        let model = BitmapFixtureModel()
        model.references = [reference]
        let host = UIHostingController(rootView: BitmapFixture(model: model, artworkPolicy: .init())
            .environment(\.plozzCardFocusStyle, .system))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        try await waitUntil {
            model.focus != nil && cache.inFlightTaskForTesting(reference: reference, variant: .posterCard) != nil
        }
        let original = try XCTUnwrap(nativePoster(in: host.view))
        let oldWork = cache.inFlightTaskForTesting(reference: reference, variant: .posterCard)
        model.focus?.requestFocus(animated: false)
        try await waitUntil { original.isFocused }
        XCTAssertNil(cache.cachedImage(for: reference, variant: .posterCard))
        try await waitUntil(timeout: .seconds(45)) {
            guard let resolved = cache.cachedImage(for: reference, variant: .posterCard) else { return false }
            return original.image?.cgImage === resolved.cgImage
        }
        XCTAssertTrue(nativePoster(in: host.view) === original)
        XCTAssertTrue(original.isFocused)
        await loader.release()
        await oldWork?.value
        await cache.purgeNetworkArtwork(accountID: account)
    }

    func testCachedBitmapReachesNativeContentBeforeAppearanceCallbacks() throws {
        let reference = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://example.test/native-warm.png")))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let identity = UUID().uuidString
        let policy = ArtworkPresentationPolicy()
        let key = ArtworkResolveKey.make(
            references: [reference], variant: .posterCard, maxAspectRatio: nil,
            pinIdentity: identity,
            providerPolicyIdentity: policy.identity
        )
        ArtworkSeedMemo.store(image, reference: reference, for: key)
        let probe = BitmapProbe()
        let host = UIHostingController(rootView: FallbackAsyncImage(
            references: [reference], variant: .posterCard, artworkPolicy: policy, pinIdentity: identity,
            content: { _ in EmptyView() }, placeholder: { EmptyView() }
        ).resolvedBitmap { value in
            BitmapCreationProbe(image: value, probe: probe)
        })
        _ = host.sizeThatFits(in: CGSize(width: 280, height: 420))
        XCTAssertEqual(probe.createdImages.count, 1)
        XCTAssertTrue(probe.createdImages.first.flatMap { $0 } === image)
    }

    func testBitmapArrivalPreservesTheNativeFocusOwner() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = BitmapFixtureModel()
        let policy = ArtworkPresentationPolicy()
        let outerResolution = ArtworkResolutionState()
        let host = UIHostingController(rootView: BitmapFixture(model: model, artworkPolicy: policy)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.artworkResolutionState, outerResolution))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        try await waitUntil { model.focus != nil && self.nativePoster(in: host.view) != nil }
        let original = try XCTUnwrap(nativePoster(in: host.view))
        model.focus?.requestFocus(animated: false)
        try await waitUntil { original.isFocused }
        let reference = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://example.test/native-arrival.png")))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let key = ArtworkResolveKey.make(
            references: [reference], variant: .posterCard, maxAspectRatio: nil,
            pinIdentity: "native-bitmap-fixture",
            providerPolicyIdentity: policy.identity
        )
        ArtworkSeedMemo.store(image, reference: reference, for: key)
        model.references = [reference]
        try await waitUntil { original.image?.cgImage === image.cgImage }
        XCTAssertTrue(nativePoster(in: host.view) === original)
        XCTAssertTrue(original.isFocused)
        XCTAssertNil(outerResolution.image, "Native cards must not publish into an ancestor artwork bridge.")
        XCTAssertFalse(outerResolution.isResolved)
    }

    private struct SurfaceProbe: View {
        @Environment(\.plozzNativeFocusSurface) private var nativeSurface
        @Environment(\.plozzNativeArtworkSurface) private var nativeArtworkSurface
        let record: (Bool, Bool) -> Void

        var body: some View {
            Color.clear.onAppear { record(nativeSurface, nativeArtworkSurface) }
        }
    }

    private struct SurfaceFixture: View {
        @PlozzCardFocus private var cardFocused
        @PlozzCardFocus private var posterFocused
        let card: (Bool, Bool) -> Void
        let poster: (Bool, Bool) -> Void

        var body: some View {
            VStack {
                SurfaceProbe(record: card)
                    .frame(width: 300, height: 140)
                    .focusableCard(
                        isFocused: $cardFocused, cornerRadius: 12,
                        accessibilityLabel: "Library", accessibilityValue: "Server", action: {}
                    )
                NativeTVPoster(
                    image: nil, treatment: .original, aspectRatio: 1.5,
                    fallbackWidth: 300, title: nil, subtitle: nil,
                    overlay: SurfaceProbe(record: poster), focus: $posterFocused, action: {}
                )
                .frame(width: 300)
            }
        }
    }

    func testNativeHostedContentReceivesTheNativeSurfaceEnvironment() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var card: Bool?
        var poster: Bool?
        var cardArtwork: Bool?
        var posterArtwork: Bool?
        let host = UIHostingController(rootView: SurfaceFixture(
            card: { card = $0; cardArtwork = $1 },
            poster: { poster = $0; posterArtwork = $1 }
        ).environment(\.plozzCardFocusStyle, .system))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        try await waitUntil { card != nil && poster != nil }
        XCTAssertEqual(card, true)
        XCTAssertEqual(poster, true)
        XCTAssertEqual(cardArtwork, false, "A generic native card still needs clipping within its artwork region.")
        XCTAssertEqual(posterArtwork, true)
        func nativeCard(in view: UIView) -> TVCardView? {
            if let card = view as? TVCardView { return card }
            return view.subviews.lazy.compactMap { nativeCard(in: $0) }.first
        }
        let native = try XCTUnwrap(nativeCard(in: host.view))
        XCTAssertTrue(native.isAccessibilityElement)
        XCTAssertEqual(native.accessibilityLabel, "Library")
        XCTAssertEqual(native.accessibilityValue, "Server")
        XCTAssertTrue(native.accessibilityTraits.contains(.button))
    }

    private final class CountingCaption: SystemPosterCaption.CaptionView {
        var invalidations = 0

        override func invalidateIntrinsicContentSize() {
            invalidations += 1
            super.invalidateIntrinsicContentSize()
        }
    }

    func testCaptionFocusDoesNotInvalidateUnchangedRowGeometry() {
        let caption = CountingCaption()
        caption.setFocused(false, travel: 16, animated: false)
        let initialSize = caption.intrinsicContentSize
        caption.invalidations = 0
        for index in 0..<30 {
            caption.setFocused(index.isMultiple(of: 2), travel: 16, animated: true)
            XCTAssertEqual(caption.intrinsicContentSize, initialSize)
        }
        XCTAssertEqual(caption.invalidations, 0, "Focus translates the caption; it must not remeasure its containing lazy rows.")
        caption.setFocused(true, travel: 20, animated: false)
        XCTAssertEqual(caption.invalidations, 1)
        XCTAssertEqual(caption.intrinsicContentSize.height, initialSize.height + 4)
    }

    func testMediaPostersKeepLibraryCaptionClearanceAtRestAndFocus() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            if let match = view as? T { return [match] }
            return view.subviews.flatMap { descendants(type, in: $0) }
        }
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics(density: density)
            for style in [PosterCardView.Style.poster, .landscape] {
                let width = metrics.cardSlotWidth(for: style, cardStyle: .borderless)
                let host = PreferredPosterHost(rootView: AnyView(
                    HStack(alignment: .top, spacing: 100) {
                        ForEach(0..<2) { index in
                            PosterCardView(
                                item: MediaItem(
                                    id: "caption-\(index)", title: "Media title", kind: .movie,
                                    productionYear: 2020, allowsTitleBasedMetadataMatching: false
                                ),
                                style: style, enablesAsyncArtworkFallback: false,
                                action: {}
                            )
                            .frame(width: width)
                        }
                    }
                    .environment(\.plozzMetrics, metrics)
                    .environment(\.plozzCardStyle, .borderless)
                    .environment(\.plozzCardFocusStyle, .system)
                    .environment(\.plozzCardCaptionsHidden, false)
                ))
                fixture.window.rootViewController = host
                fixture.window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let posters = descendants(TVPosterView.self, in: host.view)
                let captions = descendants(SystemPosterCaption.CaptionView.self, in: host.view)
                XCTAssertEqual(posters.count, 2)
                XCTAssertEqual(captions.count, 2)
                guard posters.count == 2, captions.count == 2 else { continue }
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
                host.target = posters[0]
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                try await waitUntil { posters[0].isFocused }
                try await Task.sleep(for: .milliseconds(250))
                let poster = posters[1]
                let caption = captions[1]
                let slot = caption.convert(caption.bounds, to: fixture.window)
                let bitmap = poster.image
                let title = try XCTUnwrap(descendants(UILabel.self, in: caption.title).first)
                let context = "\(density), \(style)"
                for focused in [false, true, false] {
                    host.target = posters[focused ? 1 : 0]
                    system.requestFocusUpdate(to: host)
                    system.updateFocusIfNeeded()
                    try await waitUntil { poster.isFocused == focused }
                    try await Task.sleep(for: .milliseconds(250))
                    let artwork = try XCTUnwrap(
                        NativeFocusProjection.artworkFrame(of: poster.imageView, in: fixture.window)
                    )
                    let text = try XCTUnwrap(
                        NativeFocusProjection.artworkFrame(of: title, in: fixture.window)
                    )
                    XCTAssertEqual(caption.convert(caption.bounds, to: fixture.window), slot,
                                   "Focus must not move the caption's layout slot: \(context)")
                    XCTAssertTrue(poster.image === bitmap, "Spacing must not regenerate artwork: \(context)")
                    if !focused {
                        XCTAssertEqual(slot.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing, accuracy: 1,
                                       "Media captions need the same resting gap as libraries: \(context)")
                    }
                    XCTAssertGreaterThanOrEqual(text.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing - 1,
                                                "Focused artwork must stay clear of its title: \(context)")
                }
            }
        }
    }

    func testNativePosterArtworkKeepsPreCaptionSeparationSizing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let metrics = PlozzMetrics.standard
        for (style, series) in [(PosterCardView.Style.poster, false), (.landscape, false), (.landscape, true)] {
            let width = style == .poster ? metrics.posterWidth :
                metrics.cardSlotWidth(for: .landscape, cardStyle: .framed, showsSeriesArtwork: series)
            let aspect: CGFloat = style == .poster ? 2.0 / 3 : series ? ContinueWatchingCardShape.aspectRatio : 16.0 / 9
            let items = (0..<3).map {
                MediaItem(id: "sizing-\($0)", title: "Poster sizing", kind: .movie, productionYear: 2020,
                          allowsTitleBasedMetadataMatching: false)
            }
            let host = UIHostingController(rootView: VStack(spacing: 50) {
                HStack(spacing: metrics.cardSpacing) {
                    ForEach(0..<3) { _ in
                        LegacyPosterSizing(aspect: aspect, title: series ? nil : "Poster sizing")
                            .padding(.horizontal, metrics.borderlessCardSideMargin)
                            .frame(width: width)
                    }
                }
                MediaRowView(title: nil, items: items, style: style,
                             showsSeriesArtwork: series, onSelect: { _ in })
            }
            .environment(\.plozzMetrics, metrics)
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system))
            fixture.window.rootViewController = host
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            func posters(in view: UIView) -> [TVPosterView] {
                if let poster = view as? TVPosterView { return [poster] }
                return view.subviews.flatMap { posters(in: $0) }
            }
            let views = posters(in: host.view)
            XCTAssertEqual(views.count, 6)
            guard views.count == 6 else { continue }
            let old = views[1], current = views[4]
            let description = "\(style), series \(series): slot=\(width), old bounds=\(old.bounds) content=\(old.contentSize) image=\(old.imageView.frame) intrinsic=\(old.intrinsicContentSize); current bounds=\(current.bounds) content=\(current.contentSize) image=\(current.imageView.frame) intrinsic=\(current.intrinsicContentSize)"
            let evidence = XCTAttachment(string: description)
            evidence.name = "poster-layout-\(style)-series-\(series)"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertEqual(current.imageView.bounds.width, old.imageView.bounds.width, accuracy: 0.5, description)
            XCTAssertEqual(current.contentSize.height, old.contentSize.height, accuracy: 0.5, description)
            XCTAssertEqual(current.imageView.bounds.height, old.imageView.bounds.height, accuracy: 1, description)
            func artworkFrame(_ index: Int) -> CGRect {
                views[index].imageView.convert(views[index].imageView.bounds, to: fixture.window)
            }
            let oldGap = artworkFrame(2).minX - artworkFrame(1).maxX
            let currentGap = artworkFrame(5).minX - artworkFrame(4).maxX
            XCTAssertEqual(currentGap, oldGap, accuracy: 0.5, "Production row gap must match the original layout.")
            XCTAssertGreaterThanOrEqual(currentGap, metrics.cardSpacing, "Native margins must not consume the row gap.")
        }
    }

    func testCaptionFocusDropReversesFromPresentationAndNeverChangesLayout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let caption = SystemPosterCaption.CaptionView()
        caption.title.configure(text: "Title", font: .systemFont(ofSize: 28), color: .white, scrolls: false)
        caption.subtitle.configure(text: "2020", font: .systemFont(ofSize: 20), color: .gray, scrolls: false)
        caption.setFocused(false, travel: 16, animated: false)
        let size = caption.intrinsicContentSize
        caption.frame = CGRect(x: 100, y: 100, width: 280, height: size.height)
        fixture.window.addSubview(caption)
        caption.layoutIfNeeded()
        let content = try XCTUnwrap(caption.title.superview)
        for _ in 0..<5 {
            caption.setFocused(true, travel: 16, animated: true)
            try await Task.sleep(for: .milliseconds(40))
            let position = try XCTUnwrap(content.layer.presentation()).transform.m42
            XCTAssertGreaterThan(position, 0)
            XCTAssertLessThan(position, 16)
            caption.setFocused(false, travel: 16, animated: true)
            let key = try XCTUnwrap(content.layer.animationKeys()?.first)
            let animation = try XCTUnwrap(content.layer.animation(forKey: key) as? CABasicAnimation)
            XCTAssertEqual(try XCTUnwrap(animation.fromValue as? CGFloat), position, accuracy: 1)
            XCTAssertLessThanOrEqual(animation.duration, 0.2)
            XCTAssertEqual(content.layer.transform.m42, 0)
            XCTAssertEqual(caption.intrinsicContentSize, size)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try XCTUnwrap(content.layer.presentation()).transform.m42, 0, accuracy: 0.5)
        caption.setFocused(true, travel: 16, animated: false)
        XCTAssertEqual(content.layer.transform.m42, 16)
        XCTAssertNil(content.layer.animationKeys())
        caption.removeFromSuperview()
    }

    func testNativeCardVisibleSurfaceFillsItsSwiftUILayoutSlot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        func findCard(in view: UIView) -> TVCardView? {
            if let card = view as? TVCardView { return card }
            return view.subviews.lazy.compactMap { findCard(in: $0) }.first
        }
        let card = try XCTUnwrap(findCard(in: fixture.window))
        XCTAssertFalse(card.isFocused)
        let slot = try XCTUnwrap(card.superview)
        let expected = slot.convert(slot.bounds, to: fixture.window)
        let visible = card.contentView.convert(card.contentView.bounds, to: fixture.window)
        XCTAssertEqual(visible.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(visible.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(visible.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(visible.height, expected.height, accuracy: 0.5)
    }

    private struct LegacyPosterSizing: UIViewRepresentable {
        let aspect: CGFloat
        let title: String?

        func makeUIView(context: Context) -> TVPosterView {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 280, height: 280 / aspect)).image {
                UIColor.darkGray.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 280, height: 280 / aspect))
            }
            let poster = TVPosterView(image: image)
            poster.contentSize = image.size
            return poster
        }

        func updateUIView(_ poster: TVPosterView, context: Context) {
            poster.title = title
            poster.subtitle = title == nil ? nil : "2020"
            poster.footerView?.titleLabel?.font = .systemFont(ofSize: PlozzMetrics.standard.cardTitleFontSize, weight: .semibold)
            poster.footerView?.subtitleLabel?.font = .systemFont(ofSize: PlozzMetrics.standard.cardSubtitleFontSize)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: TVPosterView, context: Context) -> CGSize? {
            let width = proposal.width ?? 280
            guard width > 0, width.isFinite else { return nil }
            uiView.contentSize = CGSize(width: width, height: width / aspect)
            var insets = uiView.contentViewInsets
            insets.bottom = title == nil ? 0 : -(PlozzMetrics.standard.nativePosterCaptionSpacing + max(0, -uiView.focusSizeIncrease.bottom))
            uiView.contentViewInsets = insets
            return uiView.intrinsicContentSize
        }
    }

    func testNativeImageKeepsAccessibleMetadataWithoutAnAnimatedFooter() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let poster = try XCTUnwrap(nativePoster(in: fixture.window))
        let restingSize = poster.intrinsicContentSize
        XCTAssertNil(poster.footerView)
        XCTAssertEqual(poster.accessibilityLabel, "Target poster")
        XCTAssertTrue(poster.isAccessibilityElement)
        fixture.model.cardFocus?.requestFocus(animated: false)
        try await waitUntil { fixture.model.cardFocused }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(poster.footerView)
        XCTAssertEqual(poster.intrinsicContentSize, restingSize)
    }

    func testContinueWatchingCardsExposeTheirTitleWithoutAddingACaption() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let movie = MediaItem(
            id: "accessible-movie", title: "Movie title", kind: .movie,
            allowsTitleBasedMetadataMatching: false
        )
        var episode = MediaItem(
            id: "accessible-episode", title: "Episode title", kind: .episode,
            allowsTitleBasedMetadataMatching: false
        )
        episode.parentTitle = "Series title"
        for (item, title) in [(movie, "Movie title"), (episode, "Series title")] {
            let host = UIHostingController(rootView:
                PosterCardView(
                    item: item, style: .landscape, showsSeriesArtwork: true,
                    enablesAsyncArtworkFallback: false
                ) {}
                .frame(width: 400)
                .environment(\.plozzCardStyle, .borderless)
                .environment(\.plozzCardFocusStyle, .system)
            )
            fixture.window.rootViewController = host
            fixture.window.layoutIfNeeded()
            try await waitUntil { self.nativePoster(in: host.view) != nil }
            let poster = try XCTUnwrap(nativePoster(in: host.view))
            XCTAssertTrue(poster.isAccessibilityElement)
            XCTAssertEqual(poster.accessibilityLabel, title)
            XCTAssertTrue(poster.accessibilityTraits.contains(.button))
            XCTAssertNil(poster.footerView)
        }
    }

    func testCaptionMarqueeKeepsItsRestingModelAndStopsWithoutMotionOrAWindow() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let caption = SystemPosterCaption.CaptionView()
        let text = "A long caption that needs to scroll beyond this narrow card"
        let font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        caption.title.configure(text: text, font: font, color: .white, scrolls: true)
        caption.subtitle.configure(text: " ", font: .systemFont(ofSize: 20), color: .gray, scrolls: false)
        caption.frame = CGRect(x: 100, y: 100, width: 180, height: caption.intrinsicContentSize.height)
        fixture.window.addSubview(caption)
        caption.layoutIfNeeded()
        let label = try XCTUnwrap(caption.title.subviews.compactMap { $0 as? UILabel }.first)
        func animation() throws -> CAKeyframeAnimation {
            let key = try XCTUnwrap(label.layer.animationKeys()?.first)
            return try XCTUnwrap(label.layer.animation(forKey: key) as? CAKeyframeAnimation)
        }
        let forward = try animation()
        XCTAssertLessThan(try XCTUnwrap(forward.values?[2] as? NSNumber).doubleValue, 0)
        XCTAssertEqual(forward.repeatCount, .infinity)
        XCTAssertEqual(label.frame.minX, 0)
        XCTAssertTrue(CATransform3DIsIdentity(label.layer.transform))
        let height = caption.intrinsicContentSize.height
        caption.title.configure(text: text, font: font, color: .gray, scrolls: false)
        caption.title.layoutIfNeeded()
        XCTAssertNil(label.layer.animationKeys())
        XCTAssertEqual(label.frame.minX, 0)
        XCTAssertEqual(caption.intrinsicContentSize.height, height)
        XCTAssertFalse(label.isAccessibilityElement)

        caption.semanticContentAttribute = .forceRightToLeft
        caption.title.configure(text: text, font: font, color: .white, scrolls: true)
        caption.title.layoutIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(animation().values?[2] as? NSNumber).doubleValue, 0)
        XCTAssertEqual(label.frame.maxX, caption.bounds.width, accuracy: 0.5)
        caption.removeFromSuperview()
        XCTAssertNil(label.layer.animationKeys())
        fixture.window.addSubview(caption)
        caption.title.layoutIfNeeded()
        XCTAssertNotNil(label.layer.animationKeys())
        caption.removeFromSuperview()
    }

    private func nativePoster(in view: UIView) -> TVPosterView? {
        if let poster = view as? TVPosterView { return poster }
        return view.subviews.lazy.compactMap { self.nativePoster(in: $0) }.first
    }

    func testRepeatedNativeRequestsDoNotRequireABooleanReset() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for _ in 0..<3 {
            fixture.model.cardFocus?.requestFocus(animated: false)
            try await waitUntil(diagnostic: fixture.describe) { fixture.model.cardFocused }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(fixture.model.cardFocused, fixture.describe())
            XCTAssertFalse(try XCTUnwrap(fixture.model.cardFocus).request.wrappedValue.wantsFocus)
            fixture.model.focusHero?()
            try await waitUntil { fixture.model.heroFocused && !fixture.model.cardFocused }
        }
    }

    func testNativeRequestWaitsForTheCardToBeMounted() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.showsCard = false
        try await Task.sleep(for: .milliseconds(50))
        fixture.model.cardFocus?.requestFocus(animated: false)
        XCTAssertTrue(try XCTUnwrap(fixture.model.cardFocus).request.wrappedValue.wantsFocus)
        fixture.model.showsCard = true
        try await waitUntil(diagnostic: fixture.describe) { fixture.model.cardFocused }
    }

    func testNativeRequestWaitsForFocusEligibility() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.cardEnabled = false
        try await Task.sleep(for: .milliseconds(50))
        fixture.model.cardFocus?.requestFocus(animated: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fixture.model.cardFocused)
        XCTAssertTrue(try XCTUnwrap(fixture.model.cardFocus).request.wrappedValue.wantsFocus)
        fixture.model.cardEnabled = true
        try await waitUntil(diagnostic: fixture.describe) { fixture.model.cardFocused }
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene)
        try await waitUntil { fixture.model.cardFocus != nil }
        XCTAssertTrue(try XCTUnwrap(fixture.model.cardFocus).usesNativeFocus)
        fixture.model.focusHero?()
        try await waitUntil { fixture.model.heroFocused }
        return fixture
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        timeout: Duration = .seconds(5),
        diagnostic: (@MainActor () -> String)? = nil,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), diagnostic?() ?? "", file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let model = NativeFocusRequestModel()
        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(
                rootView: NativeFocusRequestView(model: model).environment(\.plozzCardFocusStyle, .system)
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }
        func close() {
            model.cardFocus = nil
            model.focusHero = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func describe() -> String {
            var views = [window as UIView]
            var lines = ["request=\(String(describing: model.cardFocus?.request.wrappedValue))",
                         "focus=\(String(describing: UIFocusSystem.focusSystem(for: window)?.focusedItem))"]
            if let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem {
                lines.append("focused frame=\(String(describing: NavigationRowFocusRequester.frame(of: focused, relativeTo: window)))")
            }
            while let view = views.popLast() {
                if let card = view as? TVLockupView {
                    lines.append("native frame=\(card.convert(card.bounds, to: window)) enabled=\(card.isEnabled) eligible=\(card.canBecomeFocused) focused=\(card.isFocused) window=\(card.window != nil)")
                }
                views.append(contentsOf: view.subviews)
            }
            return lines.joined(separator: "\n")
        }
    }
}

@MainActor @Observable
private final class SkeletonFocusMatrixModel {
    @ObservationIgnored var focus: PlozzCardFocus.Binding?
    @ObservationIgnored var focusAnchor: (() -> Void)?
    var isFocused = false
    var anchorFocused = false
    var frame = CGRect.zero
    var neighborFrame = CGRect.zero
}

private struct SkeletonFocusMatrixView: View {
    let model: SkeletonFocusMatrixModel
    let style: SkeletonCardView.Style
    let seriesArtwork: Bool
    let caption: Bool
    @PlozzCardFocus private var focused
    @FocusState private var anchorFocused: Bool
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        let width = style == .poster ? metrics.posterWidth : metrics.cardSlotWidth(
            for: .landscape, cardStyle: .framed, showsSeriesArtwork: seriesArtwork
        )
        VStack(spacing: 80) {
            Button("Anchor") {}
                .focused($anchorFocused)
            HStack(alignment: .top, spacing: 80) {
                SkeletonCardView(
                    style: style, showsCaption: caption, showsSeriesArtwork: seriesArtwork,
                    isFocused: focused, showsProgress: true, focus: $focused
                )
                .frame(width: width)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.frame = $0 }
                SkeletonCardView(style: style, showsCaption: caption, showsSeriesArtwork: seriesArtwork)
                    .frame(width: width)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.neighborFrame = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onAppear {
            model.focus = $focused
            let anchor = $anchorFocused
            model.focusAnchor = { anchor.wrappedValue = true }
        }
        .onChange(of: focused) { _, value in model.isFocused = value }
        .onChange(of: anchorFocused) { _, value in model.anchorFocused = value }
    }
}

@MainActor @Observable
private final class NativeFocusRequestModel {
    @ObservationIgnored var cardFocus: PlozzCardFocus.Binding?
    @ObservationIgnored var focusHero: (() -> Void)?
    var showsCard = true
    var cardEnabled = true
    var cardFocused = false
    var heroFocused = false
}

private struct NativeFocusRequestView: View {
    let model: NativeFocusRequestModel
    @PlozzCardFocus private var cardFocused: Bool
    @FocusState private var heroFocused: Bool

    var body: some View {
        VStack(spacing: 100) {
            Button("Hero") {}
                .focused($heroFocused)
            NativeFocusDecoy()
            if model.showsCard {
                NativeTVPoster(
                    image: nil, treatment: .original, aspectRatio: 2,
                    fallbackWidth: 400, title: .content("Target poster"), subtitle: nil,
                    overlay: Color.clear, focus: $cardFocused, action: {}
                )
                    .frame(width: 400, height: 250)
                    .focused($cardFocused.focusState)
                    .disabled(!model.cardEnabled)
            }
        }

        .defaultFocus($heroFocused, true, priority: .userInitiated)
        .environment(\.plozzCardFocusStyle, .system)
        .onAppear {
            model.cardFocus = $cardFocused
            model.focusHero = { heroFocused = true }
        }
        .onChange(of: cardFocused) { _, focused in model.cardFocused = focused }
        .onChange(of: heroFocused, initial: true) { _, focused in model.heroFocused = focused }
    }
}

private struct NativeFocusDecoy: View {
    @PlozzCardFocus private var focused: Bool

    var body: some View {
        Text("Other native card")
            .frame(width: 400, height: 100)
            .focusableCard(isFocused: $focused, cornerRadius: 20, action: {})
    }
}
