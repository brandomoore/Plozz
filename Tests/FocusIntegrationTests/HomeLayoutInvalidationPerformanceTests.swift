#if os(tvOS) && DEBUG
import CoreModels
@testable import CoreUI
@testable import FeatureHome
@testable import HeroUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeLayoutInvalidationPerformanceTests: XCTestCase {
    func testShowcaseFocusDiscoveryFollowsAdjacentRowsAfterReorder() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        try await fixture.prepare()
        var scannedRows = Set<String>()
        fixture.probe.measurement.onFocusScan = { id, _ in scannedRows.insert(id) }
        defer { fixture.probe.measurement.onFocusScan = nil }

        for (row, expected) in [(0, Set(["row-1"])), (1, Set(["row-0", "row-2"])), (0, Set(["row-1"]))] {
            let card = try fixture.poster(named: "Layout \(row)-1")
            fixture.host.target = card
            fixture.focusSystem.requestFocusUpdate(to: fixture.host)
            fixture.focusSystem.updateFocusIfNeeded()
            try await Fixture.waitUntil { fixture.focusSystem.focusedItem === card }
            scannedRows.removeAll()
            NotificationCenter.default.post(name: UIFocusSystem.didUpdateNotification, object: fixture.focusSystem)
            XCTAssertEqual(scannedRows, expected, "Unrelated rows must not query UIKit's focus hierarchy.")
        }
        fixture.state.rows.swapAt(1, 4)
        try await Fixture.waitUntil {
            fixture.window.layoutIfNeeded()
            scannedRows.removeAll()
            NotificationCenter.default.post(name: UIFocusSystem.didUpdateNotification, object: fixture.focusSystem)
            return scannedRows == ["row-4"]
        }
        XCTAssertEqual((fixture.focusSystem.focusedItem as? UIView)?.accessibilityLabel, "Layout 0-1")
        let loaded = fixture.state.rows[1]
        fixture.state.rows[1] = FocusHeroRow(id: loaded.id, itemIDs: [], leadItem: nil, isPlaceholder: true)
        try await Fixture.waitUntil {
            fixture.window.layoutIfNeeded()
            scannedRows.removeAll()
            NotificationCenter.default.post(name: UIFocusSystem.didUpdateNotification, object: fixture.focusSystem)
            return scannedRows == ["row-2"]
        }
        fixture.state.rows[1] = FocusHeroRow(
            id: loaded.id, itemIDs: loaded.itemIDs, leadItem: loaded.leadItem,
            items: loaded.items, isPlaceholder: true
        )
        try await Fixture.waitUntil {
            fixture.window.layoutIfNeeded()
            scannedRows.removeAll()
            NotificationCenter.default.post(name: UIFocusSystem.didUpdateNotification, object: fixture.focusSystem)
            return scannedRows == ["row-4"]
        }
        XCTAssertEqual((fixture.focusSystem.focusedItem as? UIView)?.accessibilityLabel, "Layout 0-1")
    }

    func testPerformanceShowcaseFocusDiscovery() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        try await fixture.prepare()
        try await PerformanceProbe.measure(self, scenario: "home-focus-discovery") {
            var scans = 0
            var queries = 0
            fixture.probe.measurement.onFocusScan = { _, count in
                scans += 1
                queries += count
            }
            defer { fixture.probe.measurement.onFocusScan = nil }
            var moves = 0
            for row in [0, 1, 2, 1] {
                for index in [1, 2, 3, 2, 1, 0] {
                    let card = try fixture.poster(named: "Layout \(row)-\(index)")
                    fixture.host.target = card
                    fixture.focusSystem.requestFocusUpdate(to: fixture.host)
                    fixture.focusSystem.updateFocusIfNeeded()
                    try await Fixture.waitUntil { fixture.focusSystem.focusedItem === card }
                    moves += 1
                }
            }
            XCTAssertEqual(moves, 24)
            XCTAssertGreaterThan(scans, 0)
            XCTAssertGreaterThan(queries, 0)
            return ["focusMoves": moves, "rowScans": scans, "containerQueries": queries]
        }
        let first = try fixture.poster(named: "Layout 0-0")
        fixture.host.target = first
        fixture.focusSystem.requestFocusUpdate(to: fixture.host)
        fixture.focusSystem.updateFocusIfNeeded()
        try await Fixture.waitUntil { fixture.focusSystem.focusedItem === first }
        try await fixture.checkContentAndFocus()
    }

    func testPerformanceArtworkPublicationLayout() async throws {
        try PerformanceProbe.requireEnabled()
        try await run(duplicates: false)
    }

    func testPerformanceDuplicateArtworkPublicationLayout() async throws {
        try PerformanceProbe.requireEnabled()
        try await run(duplicates: true)
    }

    func testPerformanceColdHomeArtworkLayout() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        try await fixture.prepare()
        try await PerformanceProbe.measure(self, scenario: "home-artwork-layout-cold") {
            let before = fixture.probe.counts
            fixture.probe.fitting = FittingCounts()
            let realized = try await fixture.remountAndWaitForArtwork()
            let work = fixture.probe.counts - before
            XCTAssertGreaterThan(fixture.probe.fitting.rowCalls, 0, "Cold rows must reach the actual host fitter.")
            XCTAssertGreaterThan(fixture.probe.fitting.columnCalls, 0, "The cold hero column must be fitted.")
            XCTAssertGreaterThan(fixture.probe.fitting.rowNanoseconds, 0)
            XCTAssertGreaterThan(fixture.probe.fitting.columnNanoseconds, 0)
            var counters = fixture.probe.fitting.counters
            counters.merge([
                "realizedArtworkHosts": realized,
                "rowContentSizeQueries": work.sizeQueries,
                "rowContentPlacements": work.placements,
                "cardInputBuilds": work.cardInputs,
                "outerHostLayoutPasses": work.hostLayouts
            ]) { _, new in new }
            return counters
        }
    }

    private func run(duplicates: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        try await fixture.prepare()
        try await PerformanceProbe.measure(
            self, scenario: duplicates ? "home-artwork-layout-duplicate" : "home-artwork-layout"
        ) {
            let before = fixture.probe.counts
            fixture.probe.fitting = FittingCounts()
            let focus = fixture.focusSystem.focusedItem
            let sizes = fixture.probe.rowSizes
            var publications = 0
            var samples = 0
            var palettes = 0
            for index in 0..<12 {
                let result = try await fixture.adopt(duplicates ? 1 : index % 2)
                publications += result.publications
                samples += result.samples
                palettes += result.palettes
            }
            XCTAssertEqual(publications, duplicates ? 0 : 12)
            XCTAssertEqual(samples, duplicates ? 0 : 12)
            XCTAssertEqual(palettes, duplicates ? 0 : 12)
            XCTAssertTrue(fixture.focusSystem.focusedItem === focus, "Artwork must not move native focus.")
            fixture.assertSizes(equalTo: sizes)
            let work = fixture.probe.counts - before
            var counters = fixture.probe.fitting.counters
            counters.merge([
                "artworkPublications": publications,
                "backgroundSamples": samples,
                "paletteUpdates": palettes,
                "rowContentSizeQueries": work.sizeQueries,
                "rowContentPlacements": work.placements,
                "cardInputBuilds": work.cardInputs,
                "outerHostLayoutPasses": work.hostLayouts
            ]) { _, new in new }
            return counters
        }
        try await fixture.checkContentAndFocus()
    }

    private struct Counts {
        var sizeQueries = 0
        var placements = 0
        var cardInputs = 0
        var hostLayouts = 0

        static func - (lhs: Self, rhs: Self) -> Self {
            Self(sizeQueries: lhs.sizeQueries - rhs.sizeQueries,
                 placements: lhs.placements - rhs.placements,
                 cardInputs: lhs.cardInputs - rhs.cardInputs,
                 hostLayouts: lhs.hostLayouts - rhs.hostLayouts)
        }
    }

    @MainActor
    private struct FittingCounts {
        var rowCalls = 0
        var columnCalls = 0
        var maskCalls = 0
        var rowNanoseconds: UInt64 = 0
        var columnNanoseconds: UInt64 = 0
        var maximumNanoseconds: UInt64 = 0
        var reentrantCalls = 0

        mutating func record(_ sample: FocusHeroLayoutMeasurement.Sample) {
            switch sample.surface {
            case .row:
                rowCalls += 1
                rowNanoseconds += sample.fittingNanoseconds
            case .column:
                columnCalls += 1
                columnNanoseconds += sample.fittingNanoseconds
            case .mask:
                maskCalls += 1
            }
            maximumNanoseconds = max(maximumNanoseconds, sample.fittingNanoseconds)
            if sample.nestingDepth > 0 { reentrantCalls += 1 }
        }

        // Durations are inclusive host-call time, not independent work to sum
        // across nesting. Reentrant calls are reported explicitly.
        var counters: [String: Int] {
            [
                "motionSizeThatFitsCalls": rowCalls + columnCalls + maskCalls,
                "rowHostFitCalls": rowCalls,
                "columnHostFitCalls": columnCalls,
                "maskSizeThatFitsCalls": maskCalls,
                "rowHostFittingNanoseconds": Int(rowNanoseconds),
                "columnHostFittingNanoseconds": Int(columnNanoseconds),
                "hostFittingMaxNanoseconds": Int(maximumNanoseconds),
                "hostFittingReentrantCalls": reentrantCalls
            ]
        }
    }

    @MainActor
    private final class Probe {
        var counts = Counts()
        var fitting = FittingCounts()
        let measurement = FocusHeroLayoutMeasurement()
        var rowSizes: [String: CGSize] = [:]
        var environments: [String: RowEnvironment] = [:]
        var artwork: HeroArtworkDisplayState?
        var ambient: AmbientBackdropModel?

        init() {
            measurement.onMeasure = { [weak self] sample in self?.fitting.record(sample) }
        }
    }

    private struct RowEnvironment: Equatable {
        let density: UIDensity
        let colorScheme: ColorScheme
        let palette: ThemePalette
        let dynamicType: DynamicTypeSize
        let leadingInset: CGFloat
    }

    @MainActor @Observable
    fileprivate final class ContentState {
        var rows: [FocusHeroRow]
        var density = UIDensity.standard
        var colorScheme = ColorScheme.dark
        var dynamicType = DynamicTypeSize.large
        var leadingInset: CGFloat = 64

        init(poster: URL, backdrop: URL, logo: URL) {
            rows = (0..<8).map { row in
                let items = (0..<75).map { index in
                    MediaItem(
                        id: "layout-\(row)-\(index)", title: "Layout \(row)-\(index)", kind: .movie,
                        posterURL: poster, backdropURL: backdrop, logoURL: logo,
                        allowsTitleBasedMetadataMatching: false
                    )
                }
                return FocusHeroRow(id: "row-\(row)", itemIDs: items.map(\.stablePresentationID),
                                    leadItem: items.first, items: items)
            }
        }
    }

    private struct Home: View {
        let state: ContentState
        let probe: Probe

        var body: some View {
            FocusHeroHomeView(
                rows: state.rows, settings: .default, spoilerSettings: .default,
                navigationStyle: .rail, isFrontmost: true
            ) { row, reporter in
                MeasuredRow(probe: probe, id: row.id) {
                    MediaRowView(
                        title: Text(verbatim: row.id), items: row.items,
                        style: row.id == "row-0" ? .landscape : .poster,
                        onFocusEntered: reporter.entered,
                        onFocusChange: { if let item = $0 { reporter.focusedItem(item) } },
                        onCardFocused: reporter.cardFocused,
                        statusCue: { _ in probe.counts.cardInputs += 1; return nil },
                        loadingPlaceholderCount: row.isPlaceholder ? 5 : 0,
                        reservesLoadingFocus: row.id == state.rows.first?.id,
                        onSelect: { _ in }
                    )
                    .background(EnvironmentCapture(probe: probe, rowID: row.id))
                }
            }
            .background(EnvironmentCapture(probe: probe, rowID: nil).frame(width: 0, height: 0))
            .artworkGradientBackground(scope: ObjectIdentifier(state), isVisible: true)
            .background { AppBackground(palette: state.colorScheme == .dark ? .dark : .light) }
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.plozzMetrics, PlozzMetrics(density: state.density, dynamicTypeSize: state.dynamicType))
            .environment(\.plozzNavigationContentInset, state.leadingInset)
            .environment(\.plozzPinnedSidebarActive, true)
            .environment(\.colorScheme, state.colorScheme)
            .environment(\.themePalette, state.colorScheme == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, state.dynamicType)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.gradientBackgroundsEnabled, true)
            .environment(\.focusHeroLayoutMeasurement, probe.measurement)
        }
    }

    /// Pass through the production row's proposal/result unchanged. This counts
    /// inner SwiftUI row queries, not all calls to the outer representable.
    private struct MeasuredRow: Layout {
        let probe: Probe
        let id: String

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            MainActor.assumeIsolated { probe.counts.sizeQueries += 1 }
            return subviews[0].sizeThatFits(proposal)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            MainActor.assumeIsolated {
                probe.counts.placements += 1
                probe.rowSizes[id] = bounds.size
            }
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }

    private struct EnvironmentCapture: UIViewRepresentable {
        let probe: Probe
        let rowID: String?

        func makeUIView(context: Context) -> UIView {
            capture(context.environment)
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {
            capture(context.environment)
        }

        private func capture(_ environment: EnvironmentValues) {
            if let rowID {
                probe.environments[rowID] = RowEnvironment(
                    density: environment.plozzMetrics.density, colorScheme: environment.colorScheme,
                    palette: environment.themePalette,
                    dynamicType: environment.dynamicTypeSize,
                    leadingInset: environment.plozzNavigationContentInset
                )
            } else {
                // Read the scope identity only, never its observable properties:
                // the measurement view must not create another artwork consumer.
                probe.artwork = environment.heroArtworkDisplayState
                probe.ambient = environment.ambientBackdropModel
            }
        }
    }

    private final class Host: UIHostingController<Home> {
        let probe: Probe
        weak var target: (any UIFocusEnvironment)?

        init(state: ContentState, probe: Probe) {
            self.probe = probe
            super.init(rootView: Home(state: state, probe: probe))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            probe.counts.hostLayouts += 1
        }
    }

    @MainActor
    private final class ChangeCounter {
        var count = 0
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        var host: Host
        let state: ContentState
        let probe = Probe()
        let server: LibraryArtworkServer
        let artwork: [FirstPaintArtwork]
        let owner = UUID()
        var backdrop: HeroWipeContainerView?
        var reporter: HeroArtworkDisplayReporter?
        var itemID = ""
        var focusSystem: UIFocusSystem!

        private init(scene: UIWindowScene, server: LibraryArtworkServer, state: ContentState,
                     artwork: [FirstPaintArtwork]) {
            self.server = server
            self.state = state
            self.artwork = artwork
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            host = Host(state: state, probe: probe)
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        static func make() async throws -> Fixture {
            try await waitUntil {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            func image(_ color: UIColor, size: CGSize) -> UIImage {
                UIGraphicsImageRenderer(size: size).image {
                    color.setFill()
                    $0.fill(CGRect(origin: .zero, size: size))
                }
            }
            let red = image(.red, size: CGSize(width: 320, height: 180))
            let blue = image(.blue, size: CGSize(width: 320, height: 180))
            let logo = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 60)).image { context in
                UIColor(red: 0.04, green: 0.05, blue: 0.18, alpha: 1).setFill()
                context.fill(CGRect(x: 10, y: 10, width: 100, height: 40))
                UIColor(red: 0.45, green: 0.03, blue: 0.04, alpha: 1).setFill()
                context.fill(CGRect(x: 130, y: 10, width: 100, height: 40))
                UIColor.white.setFill()
                context.fill(CGRect(x: 30, y: 20, width: 10, height: 10))
            }
            let server = try LibraryArtworkServer(images: [
                "red": try XCTUnwrap(red.pngData()), "blue": try XCTUnwrap(blue.pngData()),
                "poster": try XCTUnwrap(image(.white, size: CGSize(width: 120, height: 180)).pngData()),
                "logo": try XCTUnwrap(logo.pngData())
            ])
            do {
                let port = try await server.start()
                let namespace = UUID().uuidString
                func url(_ name: String) throws -> URL {
                    try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(name)/\(namespace)"))
                }
                let poster = try url("poster"), logo = try url("logo"), redURL = try url("red")
                let blueURL = try url("blue")
                for reference in [poster, logo, redURL, blueURL] {
                    for variant in [ArtworkImageVariant.posterPreview, .posterCard, .landscapeCard, .heroPreview, .heroBackdrop, .original] {
                        let decoded = await ArtworkImageCache.shared.image(for: reference, variant: variant)
                        _ = try XCTUnwrap(decoded, "Prewarm artwork before the measured publication boundary.")
                    }
                }
                return Fixture(
                    scene: scene, server: server, state: ContentState(poster: poster, backdrop: redURL, logo: logo),
                    artwork: [
                        FirstPaintArtwork(
                            image: try XCTUnwrap(ArtworkImageCache.shared.cachedImage(for: redURL, variant: .heroBackdrop)),
                            reference: .remote(redURL), variant: .heroBackdrop
                        ),
                        FirstPaintArtwork(
                            image: try XCTUnwrap(ArtworkImageCache.shared.cachedImage(for: blueURL, variant: .heroBackdrop)),
                            reference: .remote(blueURL), variant: .heroBackdrop
                        )
                    ]
                )
            } catch {
                server.stop()
                throw error
            }
        }

        func prepare() async throws {
            try await Self.waitUntil {
                self.window.layoutIfNeeded()
                return self.descendants(NativePosterButton.self, in: self.window)
                    .contains { $0.accessibilityLabel == "Layout 0-0" }
            }
            focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let first = try poster(named: "Layout 0-0")
            host.target = first
            focusSystem.requestFocusUpdate(to: host)
            focusSystem.updateFocusIfNeeded()
            try await Self.waitUntil { self.focusSystem.focusedItem === first }
            try await Self.waitUntil {
                self.window.layoutIfNeeded()
                return self.probe.rowSizes.count == self.state.rows.count
                    && self.probe.artwork?.backgroundSample != nil
                    && self.probe.artwork?.displayed?.artwork.variant == .heroBackdrop
            }
            try await Task.sleep(for: .milliseconds(650))
            backdrop = try XCTUnwrap(descendants(HeroWipeContainerView.self, in: window).first)
            let display = try XCTUnwrap(probe.artwork)
            itemID = try XCTUnwrap(display.displayed?.itemID)
            XCTAssertTrue(display.displayed?.artwork.image === backdrop?.frontImage,
                          "Start from the production renderer's real reported bitmap.")
            display.activate(owner: owner, itemID: itemID)
            reporter = HeroArtworkDisplayReporter(state: display, owner: owner, itemID: itemID, isActive: true)
            XCTAssertGreaterThan(probe.counts.sizeQueries, 0)
            XCTAssertGreaterThan(probe.counts.cardInputs, 0)
            XCTAssertGreaterThan(probe.fitting.rowCalls, 0, "The scoped hook must see the production row hosts.")
            XCTAssertGreaterThan(probe.fitting.columnCalls, 0)
            XCTAssertGreaterThan(probe.fitting.maskCalls, 0)
            // Warm both ambient keys, including their deliberate 180 ms first-use delay.
            _ = try await adopt(0)
            let redPixel = try pixel(at: CGPoint(x: 1700, y: 220))
            _ = try await adopt(1)
            let bluePixel = try pixel(at: CGPoint(x: 1700, y: 220))
            XCTAssertGreaterThan(redPixel[0] - redPixel[2], 50, "The real Home backdrop must paint red.")
            XCTAssertGreaterThan(bluePixel[2] - bluePixel[0], 50, "The real Home backdrop must paint blue.")
            try await Task.sleep(for: .milliseconds(950))
        }

        /// Cold view graph with already-decoded artwork, not a cold network or
        /// four-minute provider refresh. The interval includes initial layout
        /// and automatic renderer publication, unlike the settled-artwork probe.
        func remountAndWaitForArtwork() async throws -> Int {
            let previousArtwork = probe.artwork
            probe.artwork?.release(owner: owner)
            reporter = nil
            backdrop = nil
            window.rootViewController = nil
            probe.artwork = nil
            probe.ambient = nil
            probe.rowSizes.removeAll()
            probe.environments.removeAll()
            host = Host(state: state, probe: probe)
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            focusSystem.requestFocusUpdate(to: host)
            focusSystem.updateFocusIfNeeded()
            try await Self.waitUntil {
                self.window.layoutIfNeeded()
                guard self.probe.rowSizes.count == self.state.rows.count,
                      let display = self.probe.artwork,
                      display !== previousArtwork,
                      display.backgroundSample != nil,
                      display.displayed?.artwork.variant == .heroBackdrop else { return false }
                guard let focused = self.focusSystem.focusedItem as? NativePosterButton else { return false }
                return focused.isDescendant(of: self.host.view)
            }
            let display = try XCTUnwrap(probe.artwork)
            let front = try XCTUnwrap(descendants(HeroWipeContainerView.self, in: window).first)
            XCTAssertTrue(display.displayed?.artwork.image === front.frontImage,
                          "Measure real production bitmap adoption and reporting, not a test-only notification.")
            XCTAssertEqual((focusSystem.focusedItem as? NSObject)?.accessibilityLabel, "Layout 0-0")
            return display !== previousArtwork && display.displayed?.artwork.image === front.frontImage ? 1 : 0
        }

        func adopt(_ index: Int) async throws -> (publications: Int, samples: Int, palettes: Int) {
            let display = try XCTUnwrap(probe.artwork)
            let ambient = try XCTUnwrap(probe.ambient)
            let next = artwork[index]
            let changed = display.displayed?.artwork.image !== next.image
            let publications = ChangeCounter(), samples = ChangeCounter(), palettes = ChangeCounter()
            withObservationTracking { _ = display.displayed } onChange: {
                MainActor.assumeIsolated { publications.count += 1 }
            }
            // The sampler clears its previous answer first; count the eventual
            // matching answer below rather than mistaking that reset for work done.
            withObservationTracking { _ = ambient.colors } onChange: {
                MainActor.assumeIsolated { palettes.count += 1 }
            }
            // Exactly the existing same-slide bitmap adoption/report boundary.
            // No rootView replacement, focus move, or row mutation is timed here.
            backdrop?.frontImage = next.image
            reporter?.publish(next, itemID: itemID)
            try await Task.sleep(for: .milliseconds(1))
            try await Self.waitUntil {
                self.window.layoutIfNeeded()
                CATransaction.flush()
                guard display.displayed?.artwork.image === next.image,
                      let sample = display.sample(for: self.itemID),
                      let color = ambient.colors?.first else { return false }
                let components = Self.components(UIColor(color))
                return index == 0
                    ? sample.red > 0.95 && components[0] > 0.95
                    : sample.blue > 0.95 && components[2] > 0.95
            }
            if changed, display.sample(for: itemID) != nil { samples.count += 1 }
            XCTAssertTrue(backdrop?.frontImage === next.image)
            XCTAssertEqual(publications.count, changed ? 1 : 0)
            XCTAssertEqual(palettes.count, changed ? 1 : 0)
            return (publications.count, samples.count, palettes.count)
        }

        func assertSizes(equalTo expected: [String: CGSize]) {
            XCTAssertEqual(Set(probe.rowSizes.keys), Set(expected.keys))
            for (id, size) in expected {
                XCTAssertEqual(probe.rowSizes[id]?.width ?? 0, size.width, accuracy: 0.5, id)
                XCTAssertEqual(probe.rowSizes[id]?.height ?? 0, size.height, accuracy: 0.5, id)
            }
        }

        func checkContentAndFocus() async throws {
            let first = try poster(named: "Layout 0-0")
            var items = state.rows[0].items
            items[0].title = "Edited 0-0"
            state.rows[0] = FocusHeroRow(
                id: "row-0", itemIDs: items.map(\.stablePresentationID), leadItem: items.first, items: items
            )
            try await Self.waitUntil { first.accessibilityLabel == "Edited 0-0" }
            XCTAssertTrue(focusSystem.focusedItem === first, "A real title update must preserve native focus.")
            let last = try poster(named: "Layout 1-6")
            host.target = last
            focusSystem.requestFocusUpdate(to: host)
            focusSystem.updateFocusIfNeeded()
            try await Self.waitUntil { self.focusSystem.focusedItem === last }
            try await Task.sleep(for: .milliseconds(650))
            let frame = last.convert(last.bounds, to: window)
            XCTAssertTrue(window.bounds.intersects(frame), "Native row handoff must reveal its focused card.")
            let firstPortrait = try poster(named: "Layout 1-0")
            var ancestor = firstPortrait.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            let scroll = try XCTUnwrap(ancestor as? UIScrollView)
            let middlePortrait = try poster(named: "Layout 1-3")
            host.target = middlePortrait
            focusSystem.requestFocusUpdate(to: host)
            focusSystem.updateFocusIfNeeded()
            try await Self.waitUntil { self.focusSystem.focusedItem === middlePortrait }
            try await Task.sleep(for: .milliseconds(950))
            let start = firstPortrait.convert(firstPortrait.bounds, to: window)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x + start.maxX - 60, y: 0), animated: false)
            try await Task.sleep(for: .milliseconds(150))
            let visible = firstPortrait.convert(firstPortrait.bounds, to: window)
            XCTAssertEqual(visible.maxX, 60, accuracy: 1)
            let point = CGPoint(x: 30, y: visible.midY)
            let white = try pixel(at: point)
            let originalImage = try XCTUnwrap(firstPortrait.image)
            let originalPreparation = firstPortrait.prepareArtwork
            let black = UIGraphicsImageRenderer(size: originalImage.size).image {
                UIColor.black.setFill()
                $0.fill(CGRect(origin: .zero, size: originalImage.size))
            }
            defer {
                firstPortrait.prepareArtwork = originalPreparation
                firstPortrait.updateImage(originalImage)
            }
            firstPortrait.prepareArtwork = { _ in black }
            firstPortrait.updateImage(black)
            let dark = try pixel(at: point)
            XCTAssertEqual(firstPortrait.convert(firstPortrait.bounds, to: window), visible)
            XCTAssertTrue(focusSystem.focusedItem === middlePortrait)
            // PinnedSidebarFeather deliberately retains only 10% beneath the
            // icons. Subtract the same background instead of requiring opacity.
            XCTAssertEqual(Double(white[0] - dark[0]), 255 * 0.1, accuracy: 5,
                           "The overscan gutter must paint the real bitmap through the 10% sidebar feather.")
        }

        func poster(named title: String) throws -> NativePosterButton {
            try XCTUnwrap(descendants(NativePosterButton.self, in: window).first { $0.accessibilityLabel == title })
        }

        private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
        }

        private func pixel(at point: CGPoint) throws -> [Int] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes {
                let context = try XCTUnwrap(CGContext(
                    data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes.map(Int.init)
        }

        private static func components(_ color: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            _ = color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b]
        }

        static func waitUntil(
            file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard condition() else {
                XCTFail("Production Home did not reach the required artwork/layout state.", file: file, line: line)
                throw FixtureError.timeout
            }
        }

        func close() {
            probe.artwork?.release(owner: owner)
            reporter = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            server.stop()
        }
    }

    private enum FixtureError: Error { case timeout }
}
#endif
