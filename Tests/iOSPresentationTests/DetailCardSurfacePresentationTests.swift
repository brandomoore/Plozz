#if os(iOS)
import CoreModels
@testable import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class DetailCardSurfacePresentationTests: XCTestCase {
    func testRatingUnitsBalanceVisibleMarginsOnPhoneAndTablet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let ratings: [ExternalRating] = [
            .init(source: .rottenTomatoes, value: 98, scale: .percent),
            .init(source: .rottenTomatoesAudience, value: 88, scale: .percent),
            .init(source: .imdb, value: 8.3, scale: .outOfTen, ratingCount: 123456),
            .init(source: .tmdb, value: 8.1, scale: .outOfTen),
            .init(source: .metacritic, value: 73, scale: .outOfHundred)
        ]
        for (width, sizeClass, iconSize) in [
            (CGFloat(148), UserInterfaceSizeClass.compact, CGFloat(24)),
            (CGFloat(240), UserInterfaceSizeClass.regular, CGFloat(28))
        ] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 140)
            for rating in ratings {
                host.rootView = AnyView(
                    RatingValue(rating: rating)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(.black)
                        .environment(\.horizontalSizeClass, sizeClass)
                        .environment(\.themePalette, .dark)
                        .environment(\.colorScheme, .dark)
                        .dynamicTypeSize(.large)
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let image = snapshot(window)
                let attachment = XCTAttachment(image: image)
                attachment.name = "centered-rating-\(rating.source)-\(width)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let pairRegion = CGRect(x: 0, y: 0, width: width, height: iconSize * 1.5)
                let mark = try paintedBounds(image, in: pairRegion, colored: true)
                XCTAssertFalse(mark.isNull)
                guard !mark.isNull else { continue }
                let score = try paintedBounds(image, in: CGRect(
                    x: mark.maxX + 1, y: 0, width: width - mark.maxX - 1, height: pairRegion.height
                ), colored: false)
                XCTAssertFalse(score.isNull)
                guard !score.isNull else { continue }
                XCTAssertEqual((mark.minX + score.maxX) / 2, width / 2, accuracy: 2,
                               "Center the visible pair, not a padded icon slot.")
                XCTAssertEqual(score.minX - mark.maxX, iconSize / 2, accuracy: 2,
                               "\(rating.source) at \(width)pt must preserve its visible icon-to-score gap.")
                let label = try paintedBounds(image, in: CGRect(
                    x: 0, y: pairRegion.maxY, width: width, height: 40
                ), colored: false)
                XCTAssertFalse(label.isNull)
                XCTAssertEqual(label.midX, width / 2, accuracy: 2,
                               "The source and any vote count must be centered beneath the pair.")
            }
        }
    }

    func testGuidanceCompletesRatingRowsWithoutStretchingScores() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let sizes: [(CGFloat, CGFloat?)] = [(340, nil), (720, nil), (340, 200), (720, 200)]
        for (width, allocatedHeight) in sizes {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            for scoreCount in 0...5 {
                for hasGuidance in [false, true] where scoreCount > 0 || hasGuidance {
                    let count = scoreCount + (hasGuidance ? 1 : 0)
                    var frames: [Int: CGRect] = [:]
                    host.rootView = AnyView(
                        ProportionalWrapLayout(
                            preferredColumns: 4, minimumCellWidth: 128, spacing: 16,
                            lastSubviewFillsRemainingColumns: hasGuidance,
                            fillsProposedHeight: allocatedHeight != nil
                        ) {
                            ForEach(0..<count, id: \.self) { index in
                                Color.white.frame(minHeight: 40, maxHeight: .infinity)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("ratings")) } action: {
                                        frames[index] = $0
                                    }
                            }
                        }
                        .coordinateSpace(name: "ratings")
                        .frame(height: allocatedHeight, alignment: .top)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .id("\(width)-\(scoreCount)-\(hasGuidance)-\(allocatedHeight ?? 0)")
                    )
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    XCTAssertEqual(frames.count, count)
                    let columns = width == 340 ? 2 : 4
                    let cellWidth = (width - CGFloat(columns - 1) * 16) / CGFloat(columns)
                    let rows = (count + columns - 1) / columns
                    let rowHeight = allocatedHeight.map { ($0 - CGFloat(rows - 1) * 16) / CGFloat(rows) } ?? 40
                    for index in 0..<scoreCount {
                        XCTAssertEqual(try XCTUnwrap(frames[index]).width, cellWidth, accuracy: 0.5)
                    }
                    for rowY in Set(frames.values.map(\.minY)) {
                        let row = frames.values.filter { $0.minY == rowY }.sorted { $0.minX < $1.minX }
                        let leading = try XCTUnwrap(row.first)
                        let trailing = try XCTUnwrap(row.last)
                        XCTAssertEqual(leading.minX, 0, accuracy: 0.5)
                        for (index, frame) in row.enumerated() {
                            XCTAssertEqual(frame.height, rowHeight, accuracy: 0.5)
                            if index > 0 {
                                XCTAssertEqual(frame.minX - row[index - 1].maxX, 16, accuracy: 0.5)
                            }
                        }
                        if hasGuidance {
                            XCTAssertEqual(trailing.maxX, width, accuracy: 0.5,
                                           "Guidance must complete the grid's last row without a blank cell.")
                        }
                    }
                    if hasGuidance {
                        let guide = try XCTUnwrap(frames[scoreCount])
                        let expectedColumn = scoreCount % columns
                        XCTAssertEqual(guide.minX, CGFloat(expectedColumn) * (cellWidth + 16), accuracy: 0.5)
                        XCTAssertEqual(guide.width, width - guide.minX, accuracy: 0.5)
                        XCTAssertEqual(guide.minY, CGFloat(scoreCount / columns) * (rowHeight + 16), accuracy: 0.5)
                    }
                }
            }
        }
    }

    func testInlineMorePreservesEarlierLinesAndClearsBehindLargeLabels() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            var images: [[UInt8]] = []
            for stage in 0..<3 {
                host.rootView = AnyView(
                    DetailInlineMoreLabel(isTruncated: stage > 0, fadeWidth: 100, textFont: .body) {
                        Text(verbatim: String(repeating: "gypqy", count: 80))
                            .font(.body)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 400, alignment: .leading)
                            .foregroundStyle(stage == 2 ? .clear : .white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.black)
                    .dynamicTypeSize(typeSize)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                let image = snapshot(window)
                let cgImage = try XCTUnwrap(image.cgImage)
                guard cgImage.width == 400, cgImage.height == 400,
                      cgImage.bitsPerPixel == 32, cgImage.bytesPerRow == 1600 else {
                    XCTFail("The pixel fixture must use a 400pt standard-range surface.")
                    return
                }
                images.append(Array(try XCTUnwrap(cgImage.dataProvider?.data) as Data))
                if stage == 1 {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "inline-more-\(typeSize)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            let rows = (0..<400).filter { y in
                (0..<400).contains { x in images[0][(y * 400 + x) * 4] > 30 }
            }
            let lineStarts = rows.enumerated().compactMap { index, y in
                index == 0 || y > rows[index - 1] + 1 ? y : nil
            }
            XCTAssertEqual(lineStarts.count, 3, "The fixture must render three lines with descenders.")
            guard lineStarts.count == 3 else { continue }
            let earlierEnd = try XCTUnwrap(rows.last { $0 < lineStarts[2] })
            var earlierChanges = 0
            for y in 0...earlierEnd {
                for x in 0..<400 {
                    let offset = (y * 400 + x) * 4
                    if abs(Int(images[0][offset]) - Int(images[1][offset])) > 3 { earlierChanges += 1 }
                }
            }
            XCTAssertLessThanOrEqual(earlierChanges, 20, "MORE must leave preceding glyphs intact at \(typeSize).")
            let labelPixels = (0..<(400 * 400)).filter { images[2][$0 * 4] > 30 }
            XCTAssertGreaterThan(labelPixels.count, 50, "The reference must contain the visible MORE label.")
            let minX = try XCTUnwrap(labelPixels.map { $0 % 400 }.min())
            let maxX = try XCTUnwrap(labelPixels.map { $0 % 400 }.max())
            let minY = try XCTUnwrap(labelPixels.map { $0 / 400 }.min())
            let maxY = try XCTUnwrap(labelPixels.map { $0 / 400 }.max())
            var labelChanges = 0
            for y in minY...maxY {
                for x in minX...maxX {
                    let offset = (y * 400 + x) * 4
                    if abs(Int(images[1][offset]) - Int(images[2][offset])) > 3 { labelChanges += 1 }
                }
            }
            XCTAssertLessThanOrEqual(labelChanges, 20, "Text must fade completely before the MORE label begins.")
        }
    }

    func testCompactDetailMetadataDoesNotCoverThePageGradient() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let trailer = HeroTrailerController()
        let settings = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
            HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
        ))
        let item = MediaItem(id: "gradient-fixture", title: "Fixture", kind: .series)
        for width in [CGFloat(390), 507] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            for palette in [ThemePalette.dark, .pureBlack, .light] {
                for gradientEnabled in [false, true] {
                    for reduceTransparency in [false, true] {
                        let background = LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
                        let stage = PlozziOSHeroStage(
                            item: item,
                            presentation: HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .detail),
                            style: .compactPortrait, surfaceRole: .detail, isActive: false,
                            showsBackdrop: false, trailerController: trailer,
                            backgroundSettings: settings, trailerResolver: { _ in nil }
                        ) {
                            Color.white.frame(width: 40, height: 120)
                        }
                        host.rootView = AnyView(
                            ScrollView {
                                stage
                                Color.clear.frame(height: 1000)
                            }
                            .background(background)
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.gradientBackgroundsEnabled, gradientEnabled)
                            .environment(\.plozzReduceTransparency, reduceTransparency)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(150))
                        let actual = snapshot(window)
                        let attachment = XCTAttachment(image: actual)
                        attachment.name = "detail-band-\(width)-\(palette)-\(gradientEnabled)-\(reduceTransparency)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        let revealsGradient = gradientEnabled && !reduceTransparency
                        host.rootView = AnyView(
                            Group {
                                if revealsGradient { background }
                                else { palette.backgroundBase }
                            }
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                        let reference = snapshot(window)
                        for y in [CGFloat(40), 120, 200] {
                            let point = CGPoint(x: 8, y: y)
                            for (rendered, expected) in zip(try pixel(actual, at: point), try pixel(reference, at: point)) {
                                XCTAssertLessThanOrEqual(abs(rendered - expected), 2,
                                                         "The metadata/action band must reveal the same page gradient, without a flat rectangle.")
                            }
                        }
                    }
                }
            }
        }
    }

    func testReadOnlyAndButtonCardsRevealTheirBackdropOnPhoneAndTablet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            window.frame = CGRect(origin: .zero, size: size)
            for palette in [ThemePalette.dark, .pureBlack, .light] {
                for (gradientEnabled, reduceTransparency) in [(true, false), (false, false), (true, true)] {
                    let gradientSurface = gradientEnabled && !reduceTransparency
                    for style in ["read-only", "button", "settings", "detail"] {
                        let fillOpacity = style == "detail" ? 0.12 : 0.05
                        let label = Color.white.frame(width: 40, height: 40)
                            .frame(width: 240, height: 120)
                        host.rootView = AnyView(
                            ZStack {
                                Color.blue
                                if style == "button" {
                                    Button {} label: { label }.plozzCardButton(cornerRadius: 20)
                                } else if style == "settings" {
                                    Button {} label: { label }.buttonStyle(SettingsCardButtonStyle())
                                } else {
                                    label.plozzFocusableCard(cornerRadius: 20)
                                }
                            }
                            .plozzAdaptiveCardSurface(fillOpacity: style == "detail"
                                ? ThemePalette.detailGradientSurfaceFillOpacity
                                : ThemePalette.gradientSurfaceFillOpacity)
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.gradientBackgroundsEnabled, gradientEnabled)
                            .environment(\.plozzReduceTransparency, reduceTransparency)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(150))
                        let actual = snapshot(window)
                        XCTAssertEqual(try pixel(actual, at: CGPoint(x: size.width / 2, y: size.height / 2)),
                                       [255, 255, 255], "Surface opacity must not fade card content.")
                        let fill = gradientSurface
                            ? (palette.isLight ? Color.black : .white).opacity(fillOpacity)
                            : palette.raised.fill
                        host.rootView = AnyView(fill.background(.blue)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark))
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                        let point = CGPoint(x: size.width / 2 + 80, y: size.height / 2)
                        for (rendered, reference) in zip(try pixel(actual, at: point),
                                                         try pixel(snapshot(window), at: point)) {
                            XCTAssertLessThanOrEqual(abs(rendered - reference), 2,
                                                     "\(size), \(palette), gradient=\(gradientEnabled), reduceTransparency=\(reduceTransparency), style=\(style)")
                        }
                    }
                }
            }
        }
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func paintedBounds(_ image: UIImage, in region: CGRect, colored: Bool) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let rowBytes = cgImage.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * cgImage.height)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        var bounds = CGRect.null
        for y in max(0, Int(region.minY))..<min(cgImage.height, Int(region.maxY)) {
            for x in max(0, Int(region.minX))..<min(cgImage.width, Int(region.maxX)) {
                let offset = y * rowBytes + x * 4
                let channels = bytes[offset..<(offset + 3)]
                let high = Int(channels.max() ?? 0)
                let low = Int(channels.min() ?? 0)
                // Include the colored marks' antialiased edges against this fixture's black backdrop.
                if colored ? high > 80 && high - low > 45 : low > 140 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }
}
#endif
