import CoreModels
@testable import CoreUI
import Observation
import SwiftUI
import TVUIKit
import UIKit
import Vision
import XCTest

@MainActor
final class NativeInformationCardHostedTests: XCTestCase {
    func testInformationTextDoesNotReplayDuringUnrelatedAnimatedUpdates() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let model = NativeInformationRefreshModel()
        let host = UIHostingController(rootView: NativeInformationRefreshView(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        let cards = nativeCards(in: window).filter { !$0.isFocused }
        XCTAssertGreaterThanOrEqual(cards.count, 4)
        let frames = cards.map { $0.contentView.convert($0.contentView.bounds, to: window).insetBy(dx: 12, dy: 12) }
        let baseline = try informationPixels(window)
        var changes: [Int] = []
        for tick in 1...12 {
            withAnimation(.easeInOut(duration: 0.3)) { model.generation = tick }
            try await Task.sleep(for: .milliseconds(50))
            let current = try informationPixels(window)
            var changedPixels = 0
            for frame in frames {
                let region = frame.intersection(window.bounds).integral
                for y in Int(region.minY)..<Int(region.maxY) {
                    for x in Int(region.minX)..<Int(region.maxX) {
                        let offset = (y * 1920 + x) * 4
                        if (0..<3).contains(where: { abs(Int(baseline[offset + $0]) - Int(current[offset + $0])) > 3 }) {
                            changedPixels += 1
                        }
                    }
                }
            }
            changes.append(changedPixels)
            if tick == 3 || tick == 10 {
                let screenshot = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
                screenshot.name = "information-refresh-\(tick)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let evidence = XCTAttachment(string: "Changed text/surface pixels per unrelated update: \(changes)")
        evidence.name = "information-refresh-pixel-changes"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertLessThanOrEqual(changes.max() ?? 0, 20, "Unchanged information must not fade or reveal partial text again.")
    }

    func testMinimumSizeProbesDoNotResizeAnAlreadyPlacedNativeCard() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let model = NativeInformationRefreshModel()
        window.rootViewController = UIHostingController(rootView:
            NativeInformationSizingProbeView(model: model)
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.themePalette, .dark)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        let card = try XCTUnwrap(nativeCards(in: window).first)
        let baseline = try informationPixels(window)
        let region = card.contentView.convert(card.contentView.bounds, to: window).insetBy(dx: 12, dy: 12).integral
        var sizes: [CGSize] = []
        var changedPixels: [Int] = []
        for tick in 0..<8 {
            withAnimation(.easeInOut(duration: 0.3)) { model.generation = tick }
            try await Task.sleep(for: .milliseconds(60))
            sizes.append(card.contentSize)
            XCTAssertEqual(card.contentSize.width, 300, accuracy: 1)
            XCTAssertEqual(card.contentSize.height, 280, accuracy: 1)
            XCTAssertEqual(card.contentView.bounds.width, 300, accuracy: 1)
            XCTAssertEqual(card.contentView.bounds.height, 280, accuracy: 1)
            let current = try informationPixels(window)
            var changed = 0
            for y in Int(region.minY)..<Int(region.maxY) {
                for x in Int(region.minX)..<Int(region.maxX) {
                    let offset = (y * 1920 + x) * 4
                    if (0..<3).contains(where: { abs(Int(baseline[offset + $0]) - Int(current[offset + $0])) > 3 }) {
                        changed += 1
                    }
                }
            }
            changedPixels.append(changed)
        }
        let evidence = XCTAttachment(string: "Visible native content sizes: \(sizes); changed pixels: \(changedPixels)")
        evidence.name = "native-information-sizing-probes"
        evidence.lifetime = .keepAlways
        add(evidence)
        let screenshot = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        screenshot.name = "native-information-sizing-probes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThanOrEqual(changedPixels.max() ?? 0, 20, "Sizing probes must not animate unchanged text.")

        model.item.ratings[2] = .init(source: .community, value: 8.9, scale: .outOfTen)
        try await Task.sleep(for: .milliseconds(400))
        let image = try XCTUnwrap(DetailTransitionSnapshot.image(of: window))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(recognized.contains { $0.contains("8.9") },
                      "Real rating updates must remain visible rather than being frozen to suppress animation: \(recognized)")
    }

    private func informationPixels(_ window: UIWindow) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        XCTAssertEqual(cgImage.bytesPerRow, 1920 * 4)
        return Array(try XCTUnwrap(cgImage.dataProvider?.data) as Data)
    }

    func testInformationGridSettlesWithoutBlockingTheMainThread() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var item = MediaItem(id: "native-information", title: "A documentary series", kind: .series)
        item.overview = String(repeating:
            "Two collectors travel across the country looking for unusual objects and the stories behind them. ",
            count: 12
        )
        item.ratings = [
            ExternalRating(source: .imdb, value: 7.9, scale: .outOfTen),
            ExternalRating(source: .tmdb, value: 8.1, scale: .outOfTen),
            ExternalRating(source: .rottenTomatoes, value: 96, scale: .percent),
            ExternalRating(source: .rottenTomatoesAudience, value: 88, scale: .percent)
        ]
        item.genres = ["Documentary", "Reality"]
        let host = UIHostingController(rootView:
            ScrollView {
                DetailInformationSections(item: item, horizontalInset: 80)
            }
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
        )
        window.rootViewController = host
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(2))
        let cards = nativeCards(in: window)
        XCTAssertFalse(cards.isEmpty)
        for card in cards {
            XCTAssertEqual(card.cardBackgroundColor, UIColor(ThemePalette.dark.raised.fill))
        }
        let before = cards.map { $0.convert($0.bounds, to: window) }
        try await Task.sleep(for: .seconds(1))
        let after = cards.map { $0.convert($0.bounds, to: window) }
        for (index, frame) in after.enumerated() {
            XCTAssertGreaterThan(frame.width, 100)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThan(frame.height, 1080)
            XCTAssertEqual(frame.height, before[index].height, accuracy: 1)
            XCTAssertEqual(frame.width, before[index].width, accuracy: 1)
            XCTAssertEqual(cards[index].intrinsicContentSize.width, frame.width, accuracy: 1)
        }
        let attachment = XCTAttachment(string: after.map(String.init(describing:)).joined(separator: "\n"))
        attachment.name = "native-information-card-frames"
        attachment.lifetime = .keepAlways
        add(attachment)
        let screenshot = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        screenshot.name = "native-information-themed-surfaces"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNativeTextSurfacePreservesTheSelectedTheme() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            let scheme: ColorScheme = palette.isLight ? .light : .dark
            var observedPalette: ThemePalette?
            var observedScheme: ColorScheme?
            window.rootViewController = UIHostingController(rootView:
                NativeInformationThemeProbe { observedPalette = $0; observedScheme = $1 }
                    .padding(24)
                    .plozzFocusableCard(cornerRadius: 24)
                    .frame(width: 600)
                    .environment(\.plozzCardFocusStyle, .system)
                    .environment(\.themePalette, palette)
                    .environment(\.colorScheme, scheme)
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(3)
            while observedPalette == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let card = try XCTUnwrap(nativeCards(in: window).first)
            XCTAssertEqual(card.cardBackgroundColor, UIColor(palette.raised.fill))
            XCTAssertEqual(observedPalette, palette)
            XCTAssertEqual(observedScheme, scheme)
        }
    }

    private func nativeCards(in view: UIView) -> [TVCardView] {
        (view as? TVCardView).map { [$0] } ?? view.subviews.flatMap(nativeCards(in:))
    }

    private struct NativeInformationThemeProbe: View {
        let observe: (ThemePalette, ColorScheme) -> Void
        @Environment(\.themePalette) private var palette
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            Text("Credits and license information")
                .plozzForeground(.primary)
                .onAppear { observe(palette, scheme) }
        }
    }
}

@MainActor @Observable
private final class NativeInformationRefreshModel {
    var generation = 0
    var item: MediaItem = {
        var item = MediaItem(id: "information-refresh", title: "A summer story", kind: .movie)
        item.overview = "Two people meet while working together. Their friendship grows through shared stories, unexpected choices, and an eventful summer in the city."
        item.productionYear = 2009
        item.runtime = 5_700
        item.officialRating = "PG-13"
        item.genres = ["Comedy", "Drama", "Romance"]
        item.tags = ["friendship", "city", "summer", "memories", "choices", "work"]
        item.studios = ["Fictional Pictures"]
        item.ratings = [
            .init(source: .critic, value: 8, scale: .outOfTen),
            .init(source: .tmdb, value: 7.3, scale: .outOfTen),
            .init(source: .community, value: 7.3, scale: .outOfTen)
        ]
        return item
    }()
}

private struct NativeInformationRefreshKey: EnvironmentKey {
    static let defaultValue = 0
}

private extension EnvironmentValues {
    var nativeInformationRefresh: Int {
        get { self[NativeInformationRefreshKey.self] }
        set { self[NativeInformationRefreshKey.self] = newValue }
    }
}

private struct NativeInformationRefreshView: View {
    let model: NativeInformationRefreshModel

    var body: some View {
        ScrollView {
            DetailInformationSections(
                item: model.item, horizontalInset: 80,
                selectedSource: MediaSourceRef(
                    accountID: "fixture", itemID: model.item.id,
                    providerKind: .jellyfin, serverName: "Fixture server", locality: .local
                )
            )
        }
        .environment(\.nativeInformationRefresh, model.generation)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzNativeFocusSurface, true)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
    }
}

private struct NativeInformationSizingProbeView: View {
    let model: NativeInformationRefreshModel

    var body: some View {
        NativeInformationSizingProbe(generation: model.generation) {
            RatingTile(rating: model.item.ratings[2])
        }
        .frame(width: 300, height: 280)
    }
}

private struct NativeInformationSizingProbe: Layout {
    let generation: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        _ = subviews[0].sizeThatFits(.zero)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: proposal)
    }
}
