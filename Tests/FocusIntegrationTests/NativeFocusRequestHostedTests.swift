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
        diagnostic: (@MainActor () -> String)? = nil,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
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
