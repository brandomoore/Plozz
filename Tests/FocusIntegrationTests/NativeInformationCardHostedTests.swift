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
    func testFocusedNativeInformationCardPaintsAboveAnOverlappingPeer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for button in [false, true] {
            let host = NativeInformationFocusHost(rootView: AnyView(
                NativeInformationStackingFixture(button: button)
                    .environment(\.plozzCardFocusStyle, .system)
                    .environment(\.plozzNativeInformationFocus, true)
                    .environment(\.themePalette, .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            ))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let cards = nativeCards(in: window).sorted {
                $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX
            }
            XCTAssertEqual(cards.count, 2)
            let front = try XCTUnwrap(cards.first)
            let back = try XCTUnwrap(cards.last)
            host.target = front
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
            let deadline = ContinuousClock.now + .seconds(3)
            while !front.isFocused, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(front.isFocused)
            try await Task.sleep(for: .milliseconds(350))
            let frontFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: front.contentView, in: window))
            let backFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: back.contentView, in: window))
            let overlap = frontFrame.intersection(backFrame)
            XCTAssertGreaterThan(overlap.width, 8, "The stacking test must actually overlap.")
            let image = DetailTransitionSnapshot.image(of: window)
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                x: overlap.midX, y: overlap.midY, width: 1, height: 1
            )))
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "information-focused-stacking-button-\(button)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(Int(rgba[0]), Int(rgba[2]) + 40,
                                 "The focused red card must paint above the later blue peer. button=\(button), pixel=\(rgba)")
        }
    }

    func testFocusedInformationCardsDoNotOverlapTheirNeighbors() async throws {
        for kind in [MediaItemKind.movie, .series] {
            for width in [CGFloat(1920), 1280] {
                try await checkInformationFocus(kind: kind, width: width)
            }
        }
    }

    private func checkInformationFocus(kind: MediaItemKind, width: CGFloat) async throws {
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
        model.item.kind = kind
        model.item.overview = String(repeating: "A film about friendship and unexpected choices. ", count: 9)
        model.item.ratings = [
            .init(source: .rottenTomatoes, value: 64, scale: .percent),
            .init(source: .rottenTomatoesAudience, value: 80, scale: .percent),
            .init(source: .imdb, value: 6.5, scale: .outOfTen),
            .init(source: .tmdb, value: 6.2, scale: .outOfTen)
        ]
        model.item.familyGuidance = FamilyGuidanceSummary(
            recommendedAge: 13, qualityRating: nil, overview: "A short content advisory."
        )
        let host = NativeInformationFocusHost(rootView: AnyView(
            NativeInformationRefreshView(model: model)
                .frame(width: width, height: 1080)
                .frame(maxWidth: .infinity, alignment: .leading)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.target = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        let cards = nativeCards(in: window)
        XCTAssertGreaterThanOrEqual(cards.count, 8)
        var samples: [String] = []
        for (index, card) in cards.enumerated() {
            host.target = card
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
            let until = ContinuousClock.now + .seconds(3)
            while !card.isFocused, ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(card.isFocused, "card \(index)")
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(45))
                let projected = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: card.contentView, in: window))
                samples.append("card=\(index) size=\(card.contentSize) increase=\(card.focusSizeIncrease) projected=\(projected)")
                XCTAssertLessThanOrEqual(projected.width, card.contentSize.width * 1.03 + 1, "card \(index)")
                XCTAssertLessThanOrEqual(projected.height, card.contentSize.height * 1.03 + 1, "card \(index)")
                for (otherIndex, other) in cards.enumerated() where other !== card {
                    let resting = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: other.contentView, in: window))
                    let overlap = projected.intersection(resting)
                    XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                                  "Focused card \(index) overlaps card \(otherIndex) by \(overlap)")
                }
            }
            let image = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            image.name = "focused-information-\(kind)-\(Int(width))-card-\(index)"
            image.lifetime = .keepAlways
            add(image)
        }
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.name = "information-native-focus-geometry-\(kind)-\(Int(width))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInformationFocusBudgetIsScopedAndRestoresNativeMediaDefaults() {
        let card = NativeTVCard<EmptyView>.Card()
        card.contentSize = CGSize(width: 1400, height: 800)
        let native = card.focusSizeIncrease
        card.updateFocusSize()
        XCTAssertEqual(card.focusSizeIncrease, native)
        card.usesInformationFocus = true
        card.updateFocusSize()
        XCTAssertEqual(card.focusSizeIncrease.leading, -6, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(card.focusSizeIncrease.top), 6)
        XCTAssertEqual(
            card.focusSizeIncrease.leading / card.contentSize.width,
            card.focusSizeIncrease.top / card.contentSize.height, accuracy: 0.0001
        )
        card.contentSize = CGSize(width: 250, height: 300)
        card.updateFocusSize()
        XCTAssertEqual(card.focusSizeIncrease.leading, -2.5, accuracy: 0.001)
        XCTAssertEqual(card.focusSizeIncrease.top, -3, accuracy: 0.001)
        card.usesInformationFocus = false
        card.updateFocusSize()
        XCTAssertEqual(card.focusSizeIncrease, native)
    }

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

    func testLoadingShimmerDoesNotAnimateSiblingNativeInformationText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let model = NativeInformationRefreshModel()
        window.rootViewController = UIHostingController(rootView: NativeInformationShimmerFixture(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(100))
        model.showsInformation = true
        try await Task.sleep(for: .seconds(3))
        let cards = nativeCards(in: window).filter { !$0.isFocused }
        XCTAssertGreaterThanOrEqual(cards.count, 4)
        let frames = cards.map { $0.contentView.convert($0.contentView.bounds, to: window).insetBy(dx: 12, dy: 12) }
        let baseline = try informationPixels(window)
        var counts: [Int] = []
        var shimmerCounts: [Int] = []
        let shimmerRegion = model.shimmerFrame.intersection(window.bounds).integral
        XCTAssertFalse(shimmerRegion.isEmpty)
        for sample in 0..<8 {
            try await Task.sleep(for: .milliseconds(300))
            let current = try informationPixels(window)
            var count = 0
            for frame in frames {
                let region = frame.intersection(window.bounds).integral
                for y in Int(region.minY)..<Int(region.maxY) {
                    for x in Int(region.minX)..<Int(region.maxX) {
                        let offset = (y * 1920 + x) * 4
                        if (0..<3).contains(where: { abs(Int(baseline[offset + $0]) - Int(current[offset + $0])) > 3 }) {
                            count += 1
                        }
                    }
                }
            }
            counts.append(count)
            var shimmerChanged = 0
            for y in Int(shimmerRegion.minY)..<Int(shimmerRegion.maxY) {
                for x in Int(shimmerRegion.minX)..<Int(shimmerRegion.maxX) {
                    let offset = (y * 1920 + x) * 4
                    if (0..<3).contains(where: { abs(Int(baseline[offset + $0]) - Int(current[offset + $0])) > 3 }) {
                        shimmerChanged += 1
                    }
                }
            }
            shimmerCounts.append(shimmerChanged)
            if sample == 1 || sample == 5 {
                let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
                attachment.name = "native-repeating-entry-\(sample)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let evidence = XCTAttachment(string: "Changed information pixels: \(counts); shimmer pixels: \(shimmerCounts)")
        evidence.name = "native-repeating-entry-counts"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertLessThanOrEqual(counts.max() ?? 0, 20)
        XCTAssertGreaterThan(shimmerCounts.max() ?? 0, 20, "Loading shimmer itself must keep animating.")

        func shimmerChanges(after pause: Duration) async throws -> Int {
            let before = try informationPixels(window)
            try await Task.sleep(for: pause)
            let after = try informationPixels(window)
            var changed = 0
            for y in Int(shimmerRegion.minY)..<Int(shimmerRegion.maxY) {
                for x in Int(shimmerRegion.minX)..<Int(shimmerRegion.maxX) {
                    let offset = (y * 1920 + x) * 4
                    if (0..<3).contains(where: { abs(Int(before[offset + $0]) - Int(after[offset + $0])) > 3 }) {
                        changed += 1
                    }
                }
            }
            return changed
        }

        model.shimmerActive = false
        try await Task.sleep(for: .milliseconds(400))
        let inactiveChanges = try await shimmerChanges(after: .milliseconds(400))
        XCTAssertEqual(inactiveChanges, 0)
        model.shimmerActive = true
        var resumedChanges = 0
        for _ in 0..<8 {
            resumedChanges = max(resumedChanges, try await shimmerChanges(after: .milliseconds(300)))
        }
        XCTAssertGreaterThan(resumedChanges, 20, "Loading shimmer must restart after becoming active again.")
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
            .environment(\.gradientBackgroundsEnabled, false)
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

private struct NativeInformationStackingFixture: View {
    let button: Bool

    var body: some View {
        HStack(spacing: -18) {
            ForEach(0..<2) { index in
                if button {
                    Button {} label: {
                        (index == 0 ? Color.red : Color.blue).frame(width: 240, height: 180)
                    }
                    .plozzCardButton(cornerRadius: 18, focusedScale: PlozzTheme.Metrics.readOnlyFocusedCardScale)
                    .frame(width: 240, height: 180)
                } else {
                    (index == 0 ? Color.red : Color.blue)
                        .frame(width: 240, height: 180)
                        .plozzFocusableCard(cornerRadius: 18)
                        .frame(width: 240, height: 180)
                }
            }
        }
    }
}

@MainActor
private final class NativeInformationFocusHost: UIHostingController<AnyView> {
    weak var target: UIView?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

@MainActor @Observable
private final class NativeInformationRefreshModel {
    var generation = 0
    var showsInformation = false
    var shimmerActive = true
    @ObservationIgnored var shimmerFrame = CGRect.zero
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

private struct NativeInformationShimmerFixture: View {
    let model: NativeInformationRefreshModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.showsInformation {
                NativeInformationRefreshView(model: model)
                    .transition(.identity)
            }
            Color.gray
                .frame(width: 200, height: 24)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.shimmerFrame = $0
                }
                .shimmering(active: model.shimmerActive)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
        }
    }
}
