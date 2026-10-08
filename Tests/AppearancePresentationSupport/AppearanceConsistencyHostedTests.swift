import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class AppearanceConsistencyHostedTests: XCTestCase {
    func testPolicySelectedPrefetchedLogoPaintsBeforeAnyViewHasLoadedIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let library = try await servedLogo(color: .blue)
        let online = try await servedLogo(color: .red)
        defer {
            for url in [library, online] {
                ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
            }
        }
        for preference in [ArtworkPreference.recommended, .library, .online] {
            let item = MediaItem(id: UUID().uuidString, title: "Prefetched title", kind: .series)
            let fallback = HeroLogoFallback(for: item) { online }
            let policy = ArtworkPresentationPolicy(
                area: .continueWatching, settings: .init(preference: preference)
            )
            let key = HeroLogoMemo.key(
                for: [.remote(library)], fallback: fallback,
                prefersOnlineArtwork: policy.prefersOnlineArtwork,
                providerPolicyIdentity: policy.forPlacement(.logo).identity
            )
            XCTAssertNil(HeroLogoMemo.value(for: key))
            await HeroLogoPreloader.prepare(references: [.remote(library)], fallback: fallback, policy: policy)
            let prepared = try XCTUnwrap(HeroLogoMemo.value(for: key))
            if preference == .library {
                XCTAssertGreaterThan(prepared.blue, prepared.red)
            } else {
                XCTAssertGreaterThan(prepared.red, prepared.blue)
            }
            let renderer = ImageRenderer(content:
                HeroLogoArtwork(
                    references: [.remote(library)], asyncFallbackURL: fallback,
                    maxWidth: 300, maxHeight: 120, constrainsToBounds: true,
                    presentationPolicy: .whenResolved
                ) { Color.green }
                .environment(\.plozzArtworkArea, .continueWatching)
                .environment(\.plozzArtworkSettings, policy.settings)
                .frame(width: 300, height: 120)
                .background(.black)
            )
            let pixels = try rgba(XCTUnwrap(renderer.uiImage))
            let selected = countPixels(pixels) {
                preference == .library ? $2 > 100 && $0 < 30 && $1 < 30 : $0 > 100 && $1 < 30 && $2 < 30
            }
            XCTAssertGreaterThan(selected, 100, "The exact selected logo must render without running a view task.")
        }
    }

    func testCancelledLogoPreparationDoesNotSeedAMissOrAnotherPolicy() async throws {
        let lookup = PendingLogoLookup()
        defer { lookup.finish(nil) }
        let item = MediaItem(id: UUID().uuidString, title: "Cancelled prefetch", kind: .series)
        let fallback = HeroLogoFallback(for: item) { await lookup.resolve() }
        let policy = ArtworkPresentationPolicy(area: .continueWatching)
        let task = Task { await HeroLogoPreloader.prepare(references: [], fallback: fallback, policy: policy) }
        try await waitUntil { lookup.calls == 1 }
        task.cancel()
        lookup.finish(nil)
        await task.value
        let key = HeroLogoMemo.key(
            for: [], fallback: fallback, prefersOnlineArtwork: true, providerPolicyIdentity: policy.identity
        )
        XCTAssertNil(HeroLogoMemo.value(for: key))
    }

    func testPrefetchedLogoDoesNotRepeatMetadataLookupOnAppearance() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let logo = try await servedLogo(color: .red)
        let lookup = PendingLogoLookup()
        defer {
            lookup.finish(nil)
            ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: logo))
        }
        let fallback = HeroLogoFallback(
            for: MediaItem(id: UUID().uuidString, title: "Prewarmed logo", kind: .series)
        ) { await lookup.resolve() }
        let task = Task {
            await HeroLogoPreloader.prepare(
                references: [], fallback: fallback, policy: .init(area: .continueWatching)
            )
        }
        try await waitUntil { lookup.calls == 1 }
        lookup.finish(logo)
        await task.value
        fixture.host.rootView = AnyView(PendingLogoFixture(model: PendingLogoModel(fallback: fallback), isCard: true))
        try await waitUntil { (try? self.logoPixelCounts(fixture.window).logo) ?? 0 > 100 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(lookup.calls, 1, "Appearance must reuse the prepared policy winner, not ask for it again.")
    }

    func testBrowsingLogoWaitsForResolutionBeforeShowingText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let logo = try seedLogo(monochrome: false, color: .red)
        defer { ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: logo)) }

        for isCard in [false, true] {
            for animationsDisabled in [false, true] {
                let missing = PendingLogoLookup()
                let available = PendingLogoLookup()
                defer {
                    missing.finish(nil)
                    available.finish(nil)
                }
                let model = PendingLogoModel(fallback: HeroLogoFallback(
                    for: MediaItem(id: UUID().uuidString, title: "Missing logo", kind: .series)
                ) { await missing.resolve() })
                let content = PendingLogoFixture(model: model, isCard: isCard)
                    .transaction { $0.disablesAnimations = animationsDisabled }
                fixture.host.rootView = AnyView(content)
                try await waitUntil { missing.calls > 0 }
                XCTAssertEqual(try logoPixelCounts(fixture.window).text, 0,
                               "Do not show text during the initial lookup.")

                missing.finish(nil)
                try await waitUntil { (try? self.logoPixelCounts(fixture.window).text) ?? 0 > 100 }
                XCTAssertEqual(try logoPixelCounts(fixture.window).logo, 0)

                model.fallback = HeroLogoFallback(
                    for: MediaItem(id: UUID().uuidString, title: "Available logo", kind: .series)
                ) { await available.resolve() }
                try await waitUntil { available.calls > 0 }
                XCTAssertEqual(try logoPixelCounts(fixture.window).text, 0,
                               "The previous title's missing-logo result must not reveal the new title.")
                available.finish(logo)
                try await waitUntil { (try? self.logoPixelCounts(fixture.window).logo) ?? 0 > 100 }
                XCTAssertEqual(try logoPixelCounts(fixture.window).text, 0,
                               "A usable logo must never transition through the text fallback.")

                fixture.host.rootView = AnyView(content.id(UUID()))
                fixture.window.layoutIfNeeded()
                XCTAssertGreaterThan(try logoPixelCounts(fixture.window).logo, 100,
                                     "A cached logo must render immediately on a fresh view.")
                XCTAssertEqual(try logoPixelCounts(fixture.window).text, 0)
                attach(try capture(fixture.window), name: "resolved-logo-card-\(isCard)-animations-disabled-\(animationsDisabled)")

                model.fallback = nil
                try await waitUntil { (try? self.logoPixelCounts(fixture.window).text) ?? 0 > 100 }
                XCTAssertEqual(try logoPixelCounts(fixture.window).logo, 0,
                               "A title with no logo sources must use text, not a stale image.")
            }
        }
    }

    func testCancelledLogoMissCannotRevealTextForTheNextPendingTitle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for isCard in [false, true] {
            let previous = PendingLogoLookup()
            let current = PendingLogoLookup()
            defer {
                previous.finish(nil)
                current.finish(nil)
            }
            let model = PendingLogoModel(fallback: HeroLogoFallback(
                for: MediaItem(id: UUID().uuidString, title: "Previous title", kind: .series)
            ) { await previous.resolve() })
            fixture.host.rootView = AnyView(PendingLogoFixture(model: model, isCard: isCard))
            try await waitUntil { previous.calls > 0 }
            model.fallback = HeroLogoFallback(
                for: MediaItem(id: UUID().uuidString, title: "Current title", kind: .series)
            ) { await current.resolve() }
            try await waitUntil { current.calls > 0 }
            previous.finish(nil)
            try await waitUntil { previous.completed }
            XCTAssertEqual(try logoPixelCounts(fixture.window).text, 0)
            current.finish(nil)
            try await waitUntil { (try? self.logoPixelCounts(fixture.window).text) ?? 0 > 100 }
        }
    }

    @MainActor
    @Observable
    fileprivate final class PendingLogoModel {
        var fallback: HeroLogoFallback?

        init(fallback: HeroLogoFallback?) {
            self.fallback = fallback
        }
    }

    private struct PendingLogoFixture: View {
        let model: PendingLogoModel
        let isCard: Bool

        var body: some View {
            Color.black.overlay {
                if isCard {
                    ContinueWatchingSeriesLogo(
                        title: Text(verbatim: "Fallback title"), logoReferences: [],
                        artworkReferences: [], artworkVariant: .landscapeCard,
                        asyncFallbackURL: model.fallback
                    )
                    .frame(width: 300, height: 190)
                } else {
                    HeroLogoArtwork(
                        references: [], asyncFallbackURL: model.fallback,
                        maxWidth: 300, maxHeight: 120, constrainsToBounds: true,
                        presentationPolicy: .whenResolved
                    ) {
                        Text(verbatim: "Fallback title").foregroundStyle(.white)
                    }
                }
            }
            .environment(\.plozzArtworkArea, .continueWatching)
            .ignoresSafeArea()
        }
    }

    @MainActor
    private final class PendingLogoLookup {
        var calls = 0
        var completed = false
        private var continuation: CheckedContinuation<URL?, Never>?

        func resolve() async -> URL? {
            calls += 1
            let result = await withCheckedContinuation { continuation = $0 }
            completed = true
            return result
        }

        func finish(_ result: URL?) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private func logoPixelCounts(_ window: UIWindow) throws -> (text: Int, logo: Int) {
        let pixels = try rgba(capture(window))
        return (
            countPixels(pixels) { $0 > 200 && $1 > 200 && $2 > 200 },
            countPixels(pixels) { $0 > 100 && $1 < 30 && $2 < 30 }
        )
    }

    func testSharedHeroAppearanceReevaluatesChangedProviderPolicy() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let library = try seedArtwork(color: .red)
        let metadata = try seedArtwork(color: .blue)
        let appearanceID = UUID().uuidString
        for providerEnabled in [true, false, true] {
            let providers = MetadataProviderSettings(
                orderMode: .custom,
                enabledOrder: providerEnabled ? ["tmdb"] : [],
                disabledOrder: providerEnabled ? [] : ["tmdb"]
            )
            let policy = ArtworkPresentationPolicy(
                area: .details, providers: providers, placement: .detailBackdrop
            )
            let online = providerEnabled ? metadata : nil
            fixture.host.rootView = AnyView(
                VStack(spacing: 0) {
                    ForEach(0..<2) { index in
                        FallbackAsyncImage(
                            references: [.remote(library)], variant: .heroBackdrop,
                            artworkPolicy: policy, asyncFallbackURL: { online },
                            pinIdentity: "\(appearanceID)-\(index)",
                            sharedResolutionIdentity: appearanceID
                        ) { Color.clear }
                        .frame(height: 160)
                    }
                }
                .frame(width: 300, height: 320)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.black)
            )
            try await waitUntil("shared hero provider enabled=\(providerEnabled)") {
                guard let image = try? self.capture(fixture.window) else { return false }
                return [50.0, 220.0].allSatisfy { y in
                    guard let pixel = try? self.pixel(
                        image, x: 50 / fixture.window.bounds.width, y: y / fixture.window.bounds.height
                    ) else { return false }
                    return pixel[providerEnabled ? 2 : 0] > 100 && pixel[providerEnabled ? 0 : 2] < 20
                }
            }
        }
    }

    func testRecommendedDetailHeroesUseMetadataWithoutChangingRelatedCards() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let library = try seedArtwork(color: .red)
        let metadata = try seedArtwork(color: .blue)
        for settings in [
            ArtworkSettings.default, .init(preference: .library),
            .init(overrides: [.details: .library]), .init(preference: .online)
        ] {
            for hasMetadata in [true, false] {
                let online = hasMetadata ? metadata : nil
                let heroOnline = settings.preference(in: .details) != .library && hasMetadata
                let cardsOnline = settings.preference(in: .details) == .online && hasMetadata
                fixture.host.rootView = AnyView(
                    VStack(spacing: 0) {
                        HeroBackdropLayer(
                            references: [.remote(library)], asyncFallbackURL: { online },
                            height: 160, scrimTone: .clear, ignoresOverscan: false,
                            pinIdentity: UUID().uuidString
                        ) { EmptyView() }
                        FallbackAsyncImage(
                            references: [.remote(library)], variant: .posterCard,
                            asyncFallbackURL: { online }, pinIdentity: UUID().uuidString
                        ) { Color.clear }
                        .frame(height: 160)
                    }
                    .frame(width: 300, height: 320)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.black)
                    .environment(\.plozzArtworkArea, .details)
                    .environment(\.plozzArtworkSettings, settings)
                    .id(UUID())
                )
                try await waitUntil("hero settings=\(settings) metadata=\(hasMetadata)") {
                    guard let image = try? self.capture(fixture.window),
                          let hero = try? self.pixel(image, x: 50 / fixture.window.bounds.width, y: 50 / fixture.window.bounds.height),
                          let card = try? self.pixel(image, x: 50 / fixture.window.bounds.width, y: 220 / fixture.window.bounds.height)
                    else { return false }
                    return hero[heroOnline ? 2 : 0] > 100 && hero[heroOnline ? 0 : 2] < 20
                        && card[cardsOnline ? 2 : 0] > 100 && card[cardsOnline ? 0 : 2] < 20
                }
            }
        }
    }

    func testHeroLogosUseRecommendedSourcesAndRetainLibraryOverrides() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let library = try seedLogo(monochrome: false, color: .red)
        let metadata = try seedLogo(monochrome: false, color: .blue)
        defer {
            for url in [library, metadata] {
                ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
            }
        }
        for area in [ArtworkArea.home, .recommendedHero, .details, .homeRows, .browse] {
            for useLibrary in [false, true] {
                let settings = ArtworkSettings(overrides: useLibrary ? [area: .library] : [:])
                let expectsMetadata = !useLibrary && [.home, .recommendedHero, .details].contains(area)
                let item = MediaItem(id: UUID().uuidString, title: "Hero logo", kind: .movie)
                fixture.host.rootView = AnyView(
                    HeroLogoArtwork(
                        references: [.remote(library)],
                        asyncFallbackURL: HeroLogoFallback(for: item) { metadata },
                        maxWidth: 200, maxHeight: 120
                    ) { Color.clear }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .environment(\.plozzArtworkArea, area)
                    .environment(\.plozzArtworkSettings, settings)
                    .id(item.id)
                )
                try await waitUntil("logo area=\(area) library=\(useLibrary)") {
                    guard let image = try? self.capture(fixture.window),
                          let bytes = try? self.rgba(image) else { return false }
                    return self.countPixels(bytes) { red, green, blue in
                        green < 30 && (expectsMetadata ? blue > 100 && red < 30 : red > 100 && blue < 30)
                    } > 500
                }
            }
        }
    }

    #if os(iOS)
    func testSettingsScrollEdgesSpanTheNavigationBarWhileRowsStayInset() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for usesList in [true, false] {
            let probe = SettingsLayoutProbe()
            fixture.host.rootView = AnyView(SettingsLayoutFixture(usesList: usesList, probe: probe))
            try await waitUntil { !probe.firstRow.isEmpty }
            let scroll = try XCTUnwrap(firstView(UIScrollView.self, in: fixture.window))
            let bar = try XCTUnwrap(firstView(UINavigationBar.self, in: fixture.window))
            let barFrame = bar.convert(bar.bounds, to: fixture.window)
            let rowInset: CGFloat = usesList ? 40 : 24
            XCTAssertEqual(probe.firstRow.minX, barFrame.minX + rowInset, accuracy: 1)
            XCTAssertEqual(probe.firstRow.maxX, barFrame.maxX - rowInset, accuracy: 1)
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 220)

            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: 220), animated: false)
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let scrollFrame = scroll.convert(scroll.bounds, to: fixture.window)
            XCTAssertEqual(scrollFrame.minX, barFrame.minX, accuracy: 1,
                           "The native leading scroll-edge blur must reach the navigation edge.")
            XCTAssertEqual(scrollFrame.maxX, barFrame.maxX, accuracy: 1,
                           "The native trailing scroll-edge blur must reach the navigation edge.")
            attach(try capture(fixture.window), name: usesList ? "settings-list-scrolled" : "settings-panels-scrolled")
        }
    }

    private final class SettingsLayoutProbe {
        var firstRow = CGRect.zero
    }

    private struct SettingsLayoutFixture: View {
        let usesList: Bool
        let probe: SettingsLayoutProbe

        var body: some View {
            NavigationStack {
                Group {
                    if usesList {
                        SettingsPageList { rows }
                    } else {
                        SettingsPageScroll { rows }
                    }
                }
                .navigationTitle("Settings")
            }
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }
        }

        private var rows: some View {
            ForEach(0..<24, id: \.self) { index in
                SettingsSectionGroup {
                    Text(verbatim: "Settings row \(index)")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if index == 0 { probe.firstRow = frame }
                }
            }
        }
    }

    private func firstView<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.firstView(type, in: $0) }.first
    }
    #endif

    func testContinueWatchingLogosStayTheSameAcrossThemesWhileHeroInkAdapts() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for monochrome in [true, false] {
            let url = try seedLogo(monochrome: monochrome)
            defer { ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url)) }
            let references = [ArtworkReference.remote(url)]
            let key = HeroLogoMemo.key(for: references)
            var baseline: [UInt8]?
            for theme in [AppTheme.dark, .light, .pureBlack] {
                let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
                fixture.host.rootView = AnyView(LogoFixture(
                    references: references, palette: palette, isCard: true,
                    width: fixture.window.bounds.width, height: fixture.window.bounds.height
                ))
                fixture.window.layoutIfNeeded()
                try await waitUntil { HeroLogoMemo.value(for: key) != nil }
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(try XCTUnwrap(HeroLogoMemo.value(for: key)).isMonochrome, monochrome)
                let image = try capture(fixture.window)
                let pixels = try rgba(image)
                if let baseline {
                    XCTAssertEqual(pixels.count, baseline.count)
                    let averageDifference = zip(pixels, baseline).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
                        / Double(pixels.count)
                    XCTAssertLessThan(averageDifference, 0.5, "The artwork-card logo must not follow the page theme.")
                } else {
                    baseline = pixels
                }
                if monochrome {
                    XCTAssertGreaterThan(countPixels(pixels) { $0 > 235 && $1 > 235 && $2 > 235 }, 100,
                                         "A missing or blackened wordmark is not a theme-independent logo.")
                } else {
                    XCTAssertGreaterThan(countPixels(pixels) { $0 > 170 && $1 < 100 && $2 < 100 }, 100)
                }
                attach(image, name: "\(theme.rawValue)-continue-watching-\(monochrome ? "monochrome" : "colour")")
            }

            if monochrome {
                for theme in [AppTheme.dark, .light] {
                    let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
                    fixture.host.rootView = AnyView(LogoFixture(
                        references: references, palette: palette, isCard: false,
                        width: fixture.window.bounds.width, height: fixture.window.bounds.height
                    ))
                    fixture.window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(350))
                    let image = try capture(fixture.window)
                    let pixels = try rgba(image)
                    if theme == .light {
                        XCTAssertGreaterThan(countPixels(pixels) { $0 < 15 && $1 < 15 && $2 < 15 }, 100,
                                             "Light heroes must keep their dark monochrome wordmarks.")
                    } else {
                        XCTAssertGreaterThan(countPixels(pixels) { $0 > 235 && $1 > 235 && $2 > 235 }, 100)
                    }
                    attach(image, name: "\(theme.rawValue)-hero-logo")
                }
            }
        }
    }

    func testSettingsPanelsRevealTheGradientAndRestoreSolidAccessibilitySurfaces() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for theme in [AppTheme.dark, .pureBlack, .light] {
            let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
            let state = SurfaceFixtureState()
            fixture.host.rootView = AnyView(SurfaceFixture(state: state, palette: palette))
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let translucent = try capture(fixture.window)
            let points: [(CGFloat, CGFloat)] = [
                (0.2, 0.2), (0.4, 0.2), (0.6, 0.2), (0.8, 0.2),
                (0.2, 0.45), (0.4, 0.45), (0.6, 0.45), (0.8, 0.45)
            ]
            let samples = try points.map { try pixel(translucent, x: $0.0, y: $0.1) }
            let variation = try (0..<3).reduce(0) { total, channel in
                let values = samples.map { $0[channel] }
                return total + (try XCTUnwrap(values.max()) - XCTUnwrap(values.min()))
            }
            XCTAssertGreaterThan(variation, 2, "The gradient must remain visible across the panel in \(theme.rawValue).")
            attach(translucent, name: "\(theme.rawValue)-translucent-settings")

            state.reduceTransparency = true
            try await Task.sleep(for: .milliseconds(150))
            let solid = try capture(fixture.window)
            let solidSamples = try points.map { try pixel(solid, x: $0.0, y: $0.1) }
            XCTAssertTrue(solidSamples.allSatisfy { $0 == solidSamples[0] },
                          "Reduce Transparency restores an opaque panel without a residual gradient.")

            state.gradient = false
            state.reduceTransparency = false
            try await Task.sleep(for: .milliseconds(150))
            let disabled = try capture(fixture.window)
            XCTAssertEqual(try pixel(disabled, x: 0.3, y: 0.3), try pixel(solid, x: 0.3, y: 0.3))
        }
    }

    @MainActor @Observable
    final class SurfaceFixtureState {
        var gradient = true
        var reduceTransparency = false
    }

    private struct SurfaceFixture: View {
        let state: SurfaceFixtureState
        let palette: ThemePalette

        var body: some View {
            NavigationStack {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Spacer(minLength: 0)
                            Text("Profile").font(.title2.bold())
                            PlozzDivider()
                            Text("Appearance").font(.headline)
                            Text("Theme, navigation, and cards").foregroundStyle(palette.secondaryText)
                        }
                        .foregroundStyle(palette.primaryText)
                        .padding(28)
                        .frame(width: geometry.size.width * 0.84, height: geometry.size.height * 0.84)
                        .settingsGroupSurface(cornerRadius: 24)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, geometry.size.height * 0.08)
                    }
                }
                #if os(iOS)
                // SettingsPageSurface paints inside the mobile navigation stack.
                .background { SettingsPageBackground() }
                .toolbarBackground(.hidden, for: .navigationBar)
                #endif
            }
            .background { SettingsPageBackground() }
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            .environment(\.gradientBackgroundsEnabled, state.gradient)
            .environment(\.plozzReduceTransparency, state.reduceTransparency)
            .transaction { $0.disablesAnimations = true }
            .ignoresSafeArea()
        }
    }

    private struct LogoFixture: View {
        let references: [ArtworkReference]
        let palette: ThemePalette
        let isCard: Bool
        let width: CGFloat
        let height: CGFloat

        var body: some View {
            Group {
                if isCard {
                    Color(red: 0.20, green: 0.13, blue: 0.10)
                        .overlay {
                            ContinueWatchingSeriesLogo(
                                title: Text(verbatim: ""), logoReferences: references,
                                artworkReferences: [], artworkVariant: .landscapeCard, asyncFallbackURL: nil
                            )
                        }
                } else {
                    palette.backgroundBase.overlay {
                        HeroLogoArtwork(
                            references: references, maxWidth: width * 0.75, maxHeight: height * 0.4,
                            constrainsToBounds: true, alignment: .center
                        ) { EmptyView() }
                    }
                }
            }
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            .transaction { $0.disablesAnimations = true }
            .ignoresSafeArea()
        }
    }

    private func seedLogo(monochrome: Bool, color: UIColor? = nil) throws -> URL {
        try seedImage(logoImage(monochrome: monochrome, color: color))
    }

    private func servedLogo(color: UIColor) async throws -> URL {
        let bytes = try XCTUnwrap(logoImage(monochrome: false, color: color).pngData())
        let server = try IPTVTestHTTPServer { _ in
            .init(data: bytes, headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"])
        }
        addTeardownBlock { await server.stop() }
        return try await server.start().appendingPathComponent("\(UUID()).png")
    }

    private func logoImage(monochrome: Bool, color: UIColor? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 100), format: format).image { context in
            (monochrome ? UIColor.white : color ?? UIColor.red).setFill()
            context.fill(CGRect(x: 20, y: 15, width: 25, height: 70))
            context.fill(CGRect(x: 20, y: 60, width: 140, height: 25))
            if !monochrome {
                (color ?? UIColor.blue).setFill()
                context.fill(CGRect(x: 120, y: 15, width: 40, height: 30))
            }
        }
        return image
    }

    private func seedArtwork(color: UIColor) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 100)).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 180, height: 100))
        }
        let url = try seedImage(image)
        addTeardownBlock {
            ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
        }
        return url
    }

    private func seedImage(_ image: UIImage) throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://appearance-fixture.example.test/\(UUID()).png"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())), for: URLRequest(url: url)
        )
        return url
    }

    @MainActor
    private struct Fixture {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let previous: UIWindow?

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: min(960, scene.coordinateSpace.bounds.width),
                              height: min(640, scene.coordinateSpace.bounds.height))
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        return Fixture(window: window, host: host, previous: previous)
    }

    private func capture(_ window: UIWindow) throws -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func rgba(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }

    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> [Int] {
        let cg = try XCTUnwrap(image.cgImage)
        let offset = (Int(CGFloat(cg.height) * y) * cg.width + Int(CGFloat(cg.width) * x)) * 4
        let bytes = try rgba(image)
        return bytes[offset..<(offset + 3)].map(Int.init)
    }

    private func countPixels(_ bytes: [UInt8], matching predicate: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { total, offset in
            total + (predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2]) ? 1 : 0)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ context: String = "", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Appearance fixture did not finish resolving. \(context)")
    }
}
