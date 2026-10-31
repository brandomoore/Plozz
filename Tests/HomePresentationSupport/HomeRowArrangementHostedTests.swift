import CoreImage
import CoreModels
@testable import CoreUI
import FeatureHomeCore
import HeroUI
import MetadataKit
#if os(tvOS)
@testable import FeatureHome
#elseif os(iOS)
@testable import AppShelliOS
#endif
@testable import FeatureSettings
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

#if os(tvOS)
@MainActor
extension HomeRowArrangementHostedTests {
    func testHomeBrowseActionMatchesMediaCardAndOwnsNativeFocus() async throws {
        for cardStyle in CardStyle.allCases {
            for style: PosterCardView.Style in [.poster, .landscape] {
                let width = PlozzMetrics.standard.cardSlotWidth(for: style, cardStyle: cardStyle)
                var mediaFrame = CGRect.zero
                var browseFrame = CGRect.zero
                var activated = 0
                var entered = 0
                try await withWindow {
                    HStack(alignment: .top, spacing: 40) {
                        PosterCardView(item: MediaItem(id: "one", title: "First title", kind: .movie), style: style) {}
                            .frame(width: width)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mediaFrame = $0 }
                        MediaRowBrowseCard(width: width, style: style, onFocus: { entered += 1 }, action: { activated += 1 })
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { browseFrame = $0 }
                    }
                    .environment(\.plozzCardStyle, cardStyle)
                    .environment(\.plozzMetrics, .standard)
                    .environment(\.plozzCardFocusStyle, .system)
                } inspect: { window in
                    _ = try await self.snapshot(window, name: "Home browse \(cardStyle) \(style)")
                    XCTAssertEqual(mediaFrame.width, browseFrame.width, accuracy: 1)
                    XCTAssertEqual(mediaFrame.height, browseFrame.height, accuracy: 1)
                    let point = CGPoint(x: browseFrame.midX, y: browseFrame.minY + 40)
                    let target = try XCTUnwrap(self.focusableItem(at: point, in: window))
                    try await self.focus(target, in: window)
                    XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === target)
                    XCTAssertGreaterThan(entered, 0)
                    let control = try XCTUnwrap(target as? UIControl)
                    control.sendActions(for: .primaryActionTriggered)
                    XCTAssertEqual(activated, 1)
                }
            }
        }
    }

    func testHomeBrowseFeaturedActionMatchesFeaturedDimensions() async throws {
        let size = FeaturedCardLayout.size(viewportWidth: 1776, television: true)
        var frame = CGRect.zero
        try await withWindow {
            MediaRowBrowseCard(width: size.width, featuredSize: size, action: {})
                .environment(\.plozzCardFocusStyle, .system)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        } inspect: { window in
            _ = try await self.snapshot(window, name: "Featured browse action")
            XCTAssertEqual(frame.size, size)
            let target = try XCTUnwrap(self.focusableItem(at: CGPoint(x: frame.midX, y: frame.midY), in: window))
            try await self.focus(target, in: window)
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === target)
        }
    }

    func testHomeBrowseNavigationReturnsFocusToAction() async throws {
        let route = HomeBrowseNavigationProbe()
        var actionFrame = CGRect.zero
        let model = HomeRowBrowseModel(
            title: "Complete shelf", snapshot: [MediaItem(id: "one", title: "One", kind: .movie)]
        )
        try await withWindow {
            NavigationStack {
                MediaRowBrowseCard(width: 240, action: { route.browser = model })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actionFrame = $0 }
                    .navigationDestination(item: Binding(
                        get: { route.browser }, set: { route.browser = $0 }
                    )) { browser in
                        HomeRowBrowseView(model: browser, columns: [GridItem(.flexible())]) { item in
                            Button(item.title) {}
                        }
                    }
            }
            .environment(\.plozzCardFocusStyle, .system)
        } inspect: { window in
            _ = try await self.snapshot(window, name: "Home browse before navigation")
            let point = CGPoint(x: actionFrame.midX, y: actionFrame.minY + 40)
            let action = try XCTUnwrap(self.focusableItem(at: point, in: window))
            try await self.focus(action, in: window)
            let host = try XCTUnwrap(window.rootViewController as? HomeRowsFocusHost)
            host.target = nil
            try XCTUnwrap(action as? UIControl).sendActions(for: .primaryActionTriggered)
            let destination = try await self.capture(window, name: "Home browse destination")
            XCTAssertTrue(destination.contains { $0.0.contains("Complete shelf") })
            route.browser = nil
            _ = try await self.snapshot(window, name: "Home browse returned")
            let restored = try XCTUnwrap(self.focusableItem(at: point, in: window))
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let returned = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in system.focusedItem === restored }, object: nil
            )
            await fulfillment(of: [returned], timeout: 3)
            XCTAssertTrue(system.focusedItem === restored,
                          "Expected \(restored); focused \(String(describing: system.focusedItem))")
        }
    }

    func testFeaturedTVLayoutKeepsWholePointFourByFiveGeometry() {
        for width: CGFloat in [390, 1024, 1696, 1760.25, 1776, 1920] {
            let size = FeaturedCardLayout.size(viewportWidth: width, television: true)
            let unalignedWidth = min(560, max(280, (width - 96) / 3.15))
            XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 4), 0)
            XCTAssertEqual(size.height, size.height.rounded())
            XCTAssertEqual(size.height / size.width, 1.25)
            XCTAssertGreaterThanOrEqual(size.width, unalignedWidth)
            XCTAssertLessThan(size.width - unalignedWidth, 4)
            for scale: CGFloat in [1, 2] {
                XCTAssertEqual(size.width * scale, (size.width * scale).rounded())
                XCTAssertEqual(size.height * scale, (size.height * scale).rounded())
            }
        }
        XCTAssertEqual(
            FeaturedCardLayout.size(viewportWidth: 1776, television: true),
            CGSize(width: 536, height: 670),
            "The pinned-navigation case must not retain a half-point width or distort the aspect ratio."
        )
        XCTAssertEqual(
            FeaturedCardLayout.size(viewportWidth: 393, television: false),
            CGSize(width: 345, height: 388.125),
            "TV alignment must not change the mobile layout."
        )
    }

    func testFeaturedLabelDefersItsOnlyClipToTheNativeCard() async throws {
        for nativeClipping in [false, true] {
            var frame = CGRect.zero
            try await withWindow {
                FeaturedCardArtwork(
                    item: MediaItem(id: "clip-owner", title: "Clip owner", kind: .movie),
                    size: CGSize(width: 520.25, height: 650.3125),
                    usesNativeClipping: nativeClipping
                ) {
                    Color.white
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            } inspect: { window in
                let image = try await self.snapshot(window, name: "Featured clip ownership native \(nativeClipping)")
                let bitmap = try XCTUnwrap(image.cgImage)
                let pixels = try self.rgba(bitmap)
                XCTAssertGreaterThan(frame.width, 500)
                let corners = frame.insetBy(dx: 2, dy: 2)
                for x in [corners.minX, corners.maxX] {
                    for y in [corners.minY, corners.maxY] {
                        let value = pixels[(Int(y) * bitmap.width + Int(x)) * 4]
                        if nativeClipping {
                            XCTAssertGreaterThan(value, 20, "The native card must receive opaque, untrimmed content.")
                        } else {
                            XCTAssertLessThan(value, 12, "Standalone previews must retain their own rounded clip.")
                        }
                    }
                }
            }
        }
    }

    func testFeaturedFocusedShadowClearsTheFollowingRow() async throws {
        let controller = HeroTrailerController()
        let coordinator = FeaturedTrailerCoordinator()
        defer { coordinator.stop() }
        try await withWindow(colorScheme: .light) {
            ZStack {
                Color.white.ignoresSafeArea()
                VStack(spacing: 0) {
                    FeaturedMediaRow(
                        title: Text("Featured"),
                        items: [MediaItem(id: "shadow", title: "Shadow", kind: .movie)],
                        scope: ObjectIdentifier(controller), coordinator: coordinator, controller: controller,
                        settings: .default, resolver: { _ in nil }, isActive: false, onSelect: { _ in }
                    )
                    Text("Following row").frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 100)
                }
            }
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.plozzNavigationContentInset, 64)
            .environment(\.plozzPinnedSidebarActive, true)
        } inspect: { window in
            let lines = try await self.capture(window, name: "Featured shadow baseline")
            let label = try XCTUnwrap(lines.first { $0.0 == "Shadow" }).1
            let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
            let card = try XCTUnwrap(self.focusableItem(at: point, in: window))
            try await self.focus(card, in: window)
            let image = try await self.snapshot(window, name: "Featured focused shadow")
            let bitmap = try XCTUnwrap(image.cgImage)
            let pixels = try self.rgba(bitmap)
            let frame = try XCTUnwrap(self.focusTarget(at: point, in: window)).frame
            let x = Int(frame.midX)
            // Focus-item bounds exclude the system's visual lift.
            let paintedBottom = try XCTUnwrap(
                (Int(frame.maxY)..<min(Int(frame.maxY) + 60, bitmap.height)).first { y in
                    pixels[(y * bitmap.width + x) * 4] > 100
                })
            let start = paintedBottom + 5
            let end = min(start + 95, bitmap.height)
            let values = (start..<end).map { y in Int(pixels[(y * bitmap.width + x) * 4]) }
            XCTAssertLessThan(try XCTUnwrap(values.min()), 245, "The sampled region must contain the real shadow.")
            let jump = zip(values, values.dropFirst()).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(jump, 8, "The shadow must fade smoothly rather than ending at the rail's clip.")
            let attachment = XCTAttachment(string: "\(frame): \(values)")
            attachment.name = "Featured shadow samples"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    func testFeaturedSeeAllKeepsTheTrailingTitleSafeInset() async throws {
        let controller = HeroTrailerController()
        let coordinator = FeaturedTrailerCoordinator()
        defer { coordinator.stop() }
        try await withWindow {
            GeometryReader { geometry in
                ScrollView {
                    FeaturedMediaRow(
                        title: Text("Featured"), items: [], scope: ObjectIdentifier(controller),
                        coordinator: coordinator, controller: controller, settings: .default,
                        resolver: { _ in nil }, isActive: false, onSeeAll: {}, onSelect: { _ in }
                    )
                }
                .ignoresSafeArea(.container, edges: .trailing)
                .environment(\.mediaRowHeaderTrailingInset, geometry.safeAreaInsets.trailing)
                .environment(\.plozzNavigationContentInset, 64)
                .environment(\.plozzPinnedSidebarActive, true)
            }
        } inspect: { window in
            let lines = try await self.capture(window, name: "Featured full-bleed header", scale: 2)
            let action = try XCTUnwrap(lines.first { $0.0.hasPrefix("See all") }, lines.map(\.0).joined(separator: " | ")).1
            XCTAssertGreaterThan(window.safeAreaInsets.right, 0)
            XCTAssertLessThanOrEqual(
                action.maxX * window.bounds.width,
                window.bounds.width - window.safeAreaInsets.right + 3)
        }
    }

    private func focus(_ target: any UIFocusItem, in window: UIWindow) async throws {
        let host = try XCTUnwrap(window.rootViewController as? HomeRowsFocusHost)
        host.target = target
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        if system.focusedItem !== target {
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in system.focusedItem === target }, object: nil)
            await fulfillment(of: [focused], timeout: 3)
        }
        try await Task.sleep(for: .milliseconds(400))
    }

}
#endif

@MainActor
@Observable
private final class HomeBrowseNavigationProbe {
    var browser: HomeRowBrowseModel?
}

final class HomeRowsFocusHost: UIHostingController<AnyView> {
    weak var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}
@MainActor
final class HomeRowArrangementHostedTests: XCTestCase {
    func testHomeRowBrowserShowsSourceTitleAndFullFixedShelf() async throws {
        let items = (0..<35).map {
            MediaItem(id: "\($0)", title: String(format: "Shelf title %02d", $0), kind: .movie)
        }
        let model = HomeRowBrowseModel(title: "Library picks", snapshot: items)
        try await withWindow {
            NavigationStack {
                HomeRowBrowseView(model: model, columns: [GridItem(.flexible())]) { item in
                    Text(verbatim: item.title).frame(maxWidth: .infinity, minHeight: 65)
                }
            }
        } inspect: { window in
            let headings = try await self.capture(window, name: "Full Home shelf", scale: 2)
            XCTAssertTrue(headings.contains { $0.0.contains("Library picks") })
            #if os(tvOS)
            XCTAssertTrue(headings.contains { $0.0.contains("Default") })
            let title = try XCTUnwrap(headings.first { $0.0.contains("Library picks") }).1
            let sort = try XCTUnwrap(headings.first { $0.0.contains("Default") }).1
            let filter = try XCTUnwrap(headings.first { $0.0.hasSuffix("All") }, "\(headings.map(\.0))").1
            for control in [sort, filter] {
                XCTAssertGreaterThan(control.minX, title.maxX)
                XCTAssertGreaterThan(control.midX, 0.5)
                XCTAssertEqual(control.midY, title.midY, accuracy: 0.02)
            }
            #endif
            try self.scrollToBottom(window)
            let bottom = try await self.capture(window, name: "Full Home shelf final item")
            XCTAssertTrue(bottom.contains { $0.0.contains("Shelf title 34") }, bottom.map(\.0).joined(separator: " | "))
            XCTAssertEqual(model.items.count, 35)
        }
    }

    #if os(iOS)
    func testHomeBrowseControlsUseTrailingToolbar() async throws {
        let model = HomeRowBrowseModel(
            title: "Library picks", snapshot: (0..<40).map {
                MediaItem(id: "\($0)", title: "Shelf title \($0)", kind: .movie)
            }
        )
        for (width, textSize): (CGFloat, DynamicTypeSize) in [(320, .accessibility3), (1024, .large)] {
            try await withWindow(size: CGSize(width: width, height: 900)) {
                NavigationStack {
                    HomeRowBrowseView(model: model, columns: [GridItem(.flexible())]) {
                        Text($0.title).frame(height: 80)
                    }
                }
                .environment(\.dynamicTypeSize, textSize)
            } inspect: { window in
                _ = try await self.snapshot(window, name: "Home browse trailing toolbar \(width)")
                func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
                let bar = try XCTUnwrap(views(window).compactMap { $0 as? UINavigationBar }.first)
                let controls = views(bar).compactMap { $0 as? UIButton }
                XCTAssertEqual(controls.count, 2, "Both menus must be navigation-bar actions")
                for control in controls {
                    let frame = control.convert(control.bounds, to: window)
                    XCTAssertGreaterThan(frame.midX, window.bounds.midX)
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
                    XCTAssertLessThanOrEqual(frame.maxY, bar.convert(bar.bounds, to: window).maxY)
                }
                let before = controls.map { $0.convert($0.bounds, to: window) }
                try self.scrollToBottom(window)
                _ = try await self.snapshot(window, name: "Home browse toolbar after scrolling \(width)")
                let after = views(bar).compactMap { $0 as? UIButton }.map { $0.convert($0.bounds, to: window) }
                XCTAssertEqual(after.count, before.count)
                for (initial, scrolled) in zip(before, after) {
                    XCTAssertEqual(scrolled.midX, initial.midX, accuracy: 1)
                    XCTAssertEqual(scrolled.midY, initial.midY, accuracy: 1)
                }
            }
        }
    }

    func testHomeBrowseHeadingHasSingleAccessibleTouchTarget() async throws {
        var headingFrame = CGRect.zero
        try await withWindow(size: CGSize(width: 390, height: 844)) {
            VStack(alignment: .leading) {
                PlozziOSMediaSection(title: Text("Library picks"), onBrowse: {}) {
                    Text(verbatim: "Shelf content")
                }
                BrowseRowHeading(title: Text("Recently Added in a library with a long title")) {}
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { headingFrame = $0 }
            }
            .environment(\.dynamicTypeSize, .accessibility3)
            .padding(20)
        } inspect: { window in
            let labels = try await self.capture(window, name: "Home browse title chevron")
            XCTAssertTrue(labels.contains { $0.0.contains("Library picks") })
            XCTAssertFalse(labels.contains { $0.0.contains("See all") })
            XCTAssertGreaterThanOrEqual(headingFrame.height, 44)
            XCTAssertLessThanOrEqual(headingFrame.width, 350)
        }
    }
    #endif

    func testExhaustedRowsHideBothBrowseAndLegacyActions() async throws {
        let controller = HeroTrailerController()
        let coordinator = FeaturedTrailerCoordinator()
        defer { coordinator.stop() }
        for featured in [false, true] {
            for count in [0, 1] {
                let items = (0..<count).map { MediaItem(id: "\($0)", title: "Only title", kind: .movie) }
                try await withWindow {
                    ScrollView {
                        if featured {
                            FeaturedMediaRow(
                                title: Text("Complete collection"), items: items, scope: ObjectIdentifier(controller),
                                coordinator: coordinator, controller: controller, settings: .default,
                                resolver: { _ in nil }, isActive: false, onSeeAll: {}, onSelect: { _ in }
                            )
                            .browsingRow(nil)
                        } else {
                            MediaRowView(
                                title: Text("Complete collection"), items: items, onSeeAll: {}, onSelect: { _ in }
                            )
                            .browsingRow(nil)
                        }
                    }
                } inspect: { window in
                    let lines = try await self.capture(window, name: "Exhausted collection \(featured)-\(count)")
                    XCTAssertTrue(lines.contains { $0.0.contains("Complete collection") })
                    XCTAssertFalse(lines.contains { $0.0.localizedCaseInsensitiveContains("See all") })
                    if count == 0 {
                        XCTAssertTrue(lines.contains { $0.0.localizedCaseInsensitiveContains("No titles in this collection") },
                                      "Keep the empty-collection explanation: \(lines.map(\.0))")
                    }
                }
            }
        }
    }

    func testEveryCardLabelIllustrationRendersAcrossStylesVisibilityAndDirection() throws {
        #if os(tvOS)
        let width: CGFloat = CardLabelScopePreview.illustrationWidth
        let metrics = PlozzMetrics(density: .standard)
        #else
        let width: CGFloat = 340
        let metrics = PlozzMetrics.touch(density: .standard)
        #endif
        for style in CardStyle.allCases {
            for showsLabels in [true, false] {
                for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                    let palette: ThemePalette = direction == .leftToRight ? .dark : .light
                    let content = Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 24) {
                        ForEach(0..<3) { line in
                            GridRow(alignment: .top) {
                                ForEach(Array(CardCaptionSettingsPage.allCases[(line * 3)..<(line * 3 + 3)]), id: \.self) { page in
                                    CardLabelScopePreview(
                                        preview: CardLabelScopePreview.snapshot(
                                            page: page, editing: page.firstControl,
                                            settings: .init(preference: showsLabels ? .show : .hide),
                                            isShowcase: false, seriesArtwork: true, layout: .landscape
                                        ),
                                        style: style
                                    )
                                    .frame(width: width)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .background(palette.settingsBackground)
                    .environment(\.themePalette, palette)
                    .environment(\.plozzMetrics, metrics)
                    .environment(\.layoutDirection, direction)
                    .environment(\.horizontalSizeClass, direction == .leftToRight ? .compact : .regular)
                    .environment(\.dynamicTypeSize, direction == .leftToRight ? .large : .accessibility1)
                    .environment(\.colorScheme, palette.isLight ? .light : .dark)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.uiImage)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    for page in CardCaptionSettingsPage.allCases {
                        XCTAssertTrue(text.contains(String(localized: page.title)), "\(page): \(text)")
                    }
                    XCTAssertTrue(text.contains("Recently Added"), text)
                    XCTAssertFalse(text.contains("Card labels"), "Do not invent a Card labels row on Home.")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "label-illustrations-\(style.rawValue)-\(showsLabels)-\(direction)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testArtworkAndPickerIllustrationsContactSheet() throws {
        let areas = ArtworkArea.allCases
        let renderer = ImageRenderer(content:
            VStack(spacing: 24) {
                Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                    ForEach(0..<Int(ceil(Double(areas.count) / 4))) { line in
                        GridRow {
                            ForEach(Array(areas.dropFirst(line * 4).prefix(4)), id: \.self) { area in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: area.rawValue).font(.caption).foregroundStyle(.white)
                                    ArtworkScopeDiagram(area: area)
                                        .frame(width: 320, height: 180)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 20) {
                    ForEach(NavigationStyle.allCases, id: \.self) { style in
                        NavigationStyleSwatch(style: style).frame(width: 320, height: 180)
                    }
                }
                HStack(spacing: 20) {
                    ForEach(HeroStyle.allCases, id: \.self) { style in
                        HomeLayoutSwatch(style: style).frame(width: 320, height: 180)
                    }
                    DisplaySizeSwatch(density: .standard).frame(width: 320, height: 180)
                }
                HStack(spacing: 20) {
                    CardStyleSwatch(style: .framed).frame(width: 320, height: 180)
                    CardStyleSwatch(style: .borderless).frame(width: 320, height: 180)
                    ContinueWatchingArtworkSwatch(style: .logoAndArtwork, showsCaptions: true)
                        .frame(width: 320, height: 180)
                }
            }
            .padding(24)
            .background(ThemePalette.dark.settingsBackground)
            .environment(\.themePalette, .dark)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 800)
        let attachment = XCTAttachment(image: image)
        attachment.name = "artwork-and-picker-illustrations"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNavigationIllustrationsFitCompleteChromeAndThreePosters() throws {
        let sizes = [
            CGSize(width: 160, height: 124), CGSize(width: 254, height: 210),
            CGSize(width: 320, height: 180), CGSize(width: 320, height: 200),
            CGSize(width: 640, height: 360)
        ]
        for size in sizes {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                for style in NavigationStyle.allCases {
                    let renderer = ImageRenderer(content:
                        NavigationStyleSwatch(style: style)
                            .frame(width: size.width, height: size.height)
                            .environment(\.layoutDirection, direction)
                            .background(.black)
                    )
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.uiImage)
                    if size.width <= 254, direction == .leftToRight {
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "Navigation \(style.rawValue) at \(Int(size.width))"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                    let bitmap = try XCTUnwrap(image.cgImage)
                    let pixels = try rgba(bitmap)
                    let context = "\(style) \(size) \(direction)"
                    var chrome = CGRect.null
                    for y in 0..<bitmap.height {
                        for x in 0..<bitmap.width {
                            let offset = (y * bitmap.width + x) * 4
                            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                            if r >= 60, abs(r - g) <= 2, b - r > 5 {
                                chrome = chrome.union(CGRect(x: x, y: y, width: 1, height: 1))
                            }
                        }
                    }
                    XCTAssertFalse(chrome.isNull, context)
                    XCTAssertTrue(
                        CGRect(x: 4, y: 4, width: bitmap.width - 8, height: bitmap.height - 8).contains(chrome),
                        "Chrome must fit without clipping: \(context) \(chrome)"
                    )
                    let screenHeight = min(size.height, size.width * 9 / 16) * renderer.scale
                    switch style {
                    case .tabBar:
                        XCTAssertEqual(chrome.midX, CGFloat(bitmap.width) / 2, accuracy: 2, context)
                        XCTAssertGreaterThan(chrome.width, chrome.height * 4, context)
                    case .sidebar:
                        XCTAssertGreaterThan(chrome.height, chrome.width * 1.3, "Show stacked tabs, not a symbol: \(context)")
                        XCTAssertLessThan(chrome.height, screenHeight * 0.65, context)
                    case .rail:
                        XCTAssertGreaterThan(chrome.height, screenHeight * 0.75, context)
                        XCTAssertLessThan(chrome.width, chrome.height / 3, context)
                    }

                    func isPoster(x: Int, y: Int) -> Bool {
                        let offset = (y * bitmap.width + x) * 4
                        let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                        return r > 50 && r < 110 && max(r, max(g, b)) - min(r, min(g, b)) <= 3
                    }
                    var posters: [ClosedRange<Int>] = []
                    var start: Int?
                    for x in 0...bitmap.width {
                        if x < bitmap.width, isPoster(x: x, y: bitmap.height / 2) {
                            if start == nil { start = x }
                        } else if let first = start {
                            if x - first > 4 { posters.append(first...(x - 1)) }
                            start = nil
                        }
                    }
                    XCTAssertEqual(posters.count, 3, "All three posters must remain visible: \(context)")
                    for poster in posters {
                        let x = (poster.lowerBound + poster.upperBound) / 2
                        // Measure the connected tile, not the separate gray window border.
                        var top = bitmap.height / 2
                        var bottom = top
                        while top > 0, isPoster(x: x, y: top - 1) { top -= 1 }
                        while bottom + 1 < bitmap.height, isPoster(x: x, y: bottom + 1) { bottom += 1 }
                        let height = bottom - top + 1
                        XCTAssertEqual(CGFloat(height) / CGFloat(poster.count), 1.5, accuracy: 0.08, context)
                        XCTAssertGreaterThan(poster.lowerBound, 4, context)
                        XCTAssertLessThan(poster.upperBound, bitmap.width - 4, context)
                        if let first = posters.first {
                            XCTAssertLessThanOrEqual(abs(poster.count - first.count), 2, context)
                        }
                    }
                }
            }
        }
    }

    func testNavigationPickerRestoresMiniatureIllustrations() async throws {
        var frame = CGRect.zero
        try await withWindow {
            VStack(alignment: .leading, spacing: 24) {
                Text("App navigation").font(.title.bold())
                CompactNavigationPicker(selection: .constant(.tabBar))
            }
            .frame(width: 880)
            .padding(32)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        } inspect: { window in
            let image = try await self.snapshot(window, name: "Restored navigation illustrations")
            let cropped = try XCTUnwrap(image.cgImage?.cropping(to: frame.integral))
            let attachment = XCTAttachment(image: UIImage(cgImage: cropped))
            attachment.name = "Restored navigation picker"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    func testFeaturedLogosUseOnDarkTreatmentInEveryPageTheme() async throws {
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let artworkURL = try XCTUnwrap(URL(string: "https://featured-contrast.invalid/\(UUID())/artwork.png"))
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 338)).image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 338))
        }
        func seed(_ image: UIImage, at url: URL) throws {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
            ))
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
                for: URLRequest(url: url)
            )
        }
        try seed(artwork, at: artworkURL)
        defer { cache.removeCachedResponse(for: URLRequest(url: artworkURL)) }
        let loadedArtwork = await ArtworkImageCache.shared.image(for: .remote(artworkURL), variant: .posterCard)
        XCTAssertNotNil(loadedArtwork)
        for (name, color, colored) in [
            ("black", UIColor.black, false), ("white", UIColor.white, false),
            ("bronze", UIColor(red: 0.25, green: 0.12, blue: 0.04, alpha: 1), true)
        ] {
            let url = try XCTUnwrap(URL(string: "https://featured-contrast.invalid/\(UUID())/logo.png"))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 70)).image { _ in
                ("LOGO" as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 54), .foregroundColor: color
                ])
            }
            try seed(image, at: url)
            defer { cache.removeCachedResponse(for: URLRequest(url: url)) }
            let item = MediaItem(
                id: UUID().uuidString, title: "Unresolved logo", kind: .movie,
                backdropURL: artworkURL, logoURL: url, allowsTitleBasedMetadataMatching: false
            )
            let policy = ArtworkPresentationPolicy().forPlacement(.logo)
            let key = HeroLogoMemo.key(
                for: [.remote(url)], fallback: HeroLogoFallback(for: item) { nil },
                prefersOnlineArtwork: policy.prefersOnlineArtwork, providerPolicyIdentity: policy.identity
            )
            for scheme in [ColorScheme.light, .dark] {
                var frame = CGRect.zero
                try await withWindow(colorScheme: scheme) {
                    FeaturedCardArtwork(item: item, size: CGSize(width: 300, height: 340))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                } inspect: { window in
                    let resolved = XCTNSPredicateExpectation(
                        predicate: NSPredicate { _, _ in HeroLogoMemo.value(for: key) != nil }, object: nil
                    )
                    await self.fulfillment(of: [resolved], timeout: 5)
                    let shot = try await self.snapshot(window, name: "Featured \(name) logo \(scheme)")
                    let bitmap = try XCTUnwrap(shot.cgImage)
                    let pixels = try self.rgba(bitmap)
                    var readableInk = 0
                    for y in Int(frame.midY)..<Int(frame.maxY) {
                        for x in Int(frame.minX)..<Int(frame.maxX) {
                            let offset = (y * bitmap.width + x) * 4
                            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                            if colored {
                                if red > 100, red > green * 3 / 2, blue < 80 { readableInk += 1 }
                            } else if min(red, green, blue) > 235 {
                                readableInk += 1
                            }
                        }
                    }
                    XCTAssertGreaterThan(readableInk, 300,
                                         "\(name) must stay readable over the dark card in \(scheme), without bleaching coloured ink.")
                }
            }
        }
    }

    private func rgba(_ bitmap: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }
        return pixels
    }

    func testCollectionChooserShowsBrandedLibrarySourceLines() async throws {
        let accounts = [ProviderKind.plex, .jellyfin].map { kind in
            let provider = HomeSettingsLibraryProvider(
                name: kind == .plex ? "Plex server" : "Jellyfin server", kind: kind,
                capabilities: [.video, .libraryCollections]
            )
            return ResolvedAccount(account: Account(from: provider.session), provider: provider)
        }
        let libraries = accounts.map { account in
            AggregatedLibrary(
                accountID: account.account.id, accountName: "Viewer",
                serverName: account.account.server.name, providerKind: account.account.server.provider,
                library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
            )
        }
        try await withWindow {
            NavigationStack {
                HeroCollectionPickerView(selections: .constant([]), libraries: libraries, accounts: accounts) { _ in }
            }
        } inspect: { window in
            let lines = try await self.capture(window, name: "Collection chooser source marks")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Plex server"), text)
            XCTAssertTrue(text.contains("Jellyfin server"), text)
            XCTAssertTrue(text.contains("Movies"), text)
        }
    }

    func testFeaturedRailShowsRealMetadataAndNativeCardFocus() async throws {
        let controller = HeroTrailerController()
        let coordinator = FeaturedTrailerCoordinator()
        defer { coordinator.stop() }
        let items = ["Orbit", "Voyage", "Horizon", "Arrival"].enumerated().map {
            MediaItem(id: "featured-\($0.offset)", title: $0.element, kind: .movie,
                      productionYear: 2024, officialRating: "PG", genres: ["Adventure"])
        }
        let phone = FeaturedCardLayout.size(viewportWidth: 393, television: false)
        XCTAssertEqual(phone.width, 345)
        XCTAssertEqual(phone.height / phone.width, 1.125)
        let tv = FeaturedCardLayout.size(viewportWidth: 1920, television: true)
        XCTAssertEqual(tv.height / tv.width, 1.25)
        XCTAssertLessThan(tv.width * 3 + 64, 1920, "The next card should peek into the rail.")
        try await withWindow {
            ScrollView {
                FeaturedMediaRow(
                    title: Text("Weekend picks"), items: items, scope: ObjectIdentifier(controller),
                    coordinator: coordinator, controller: controller, settings: .default,
                    resolver: { _ in nil }, isActive: true, onSelect: { _ in }
                )
            }
            .environment(\.scenePhase, .active)
        } inspect: { window in
            let lines = try await self.capture(window, name: "Featured collection rail")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Weekend picks"), text)
            XCTAssertTrue(text.contains("Orbit"), text)
            XCTAssertTrue(text.contains("2024"), text)
            XCTAssertTrue(text.contains("Adventure"), text)
            #if os(tvOS)
            let label = try XCTUnwrap(lines.first { $0.0.contains("Orbit") }).1
            let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
            let target = try XCTUnwrap(self.focusableItem(at: point, in: window))
            let system = try XCTUnwrap(UIFocusSystem(for: window))
            system.requestFocusUpdate(to: target)
            system.updateFocusIfNeeded()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in system.focusedItem === target && controller.isFeaturedReserved },
                object: nil
            )
            await self.fulfillment(of: [focused], timeout: 3)
            #else
            let visible = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in coordinator.activeItemID == items[0].stablePresentationID },
                object: nil
            )
            await self.fulfillment(of: [visible], timeout: 3)
            #endif
        }
    }

    func testSectionWarningShowsSourceAndNativeActions() async throws {
        let choice = HomeRowChoice(
            id: .server(accountID: "fixture", section: "top"),
            title: "Top picks", isProviderDefault: true
        )
        let issue = HomeSectionIssue(
            choice: choice, reason: .failed(.serverUnreachable),
            serverName: "Living room server", providerKind: .jellyfin
        )
        try await withWindow {
            HomeSectionStatusView(issue: issue, onRetry: {})
                .padding()
                #if os(iOS)
                .environment(\.plozzMetrics, .touch(density: .standard))
                #endif
        } inspect: { window in
            let lines = try await self.capture(window, name: "Home section load warning")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Top picks"), text)
            XCTAssertTrue(text.contains("Living room server"), text)
            XCTAssertTrue(text.contains("Details"), text)
            XCTAssertTrue(text.contains("Retry"), text)
            #if os(tvOS)
            for title in ["Details", "Retry"] {
                let label = try XCTUnwrap(lines.first { $0.0.contains(title) }).1
                let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
                let target = try XCTUnwrap(self.focusableItem(at: point, in: window))
                XCTAssertTrue(target.canBecomeFocused, title)
            }
            #endif
        }
    }

    #if os(tvOS)
    func testEmptySectionSharesThePopulatedRowHeaderAndPinnedNavigationKeyline() async throws {
        let item = MediaItem(
            id: "status-reference", title: "Reference title", kind: .movie,
            allowsTitleBasedMetadataMatching: false
        )
        let issue = HomeSectionIssue(
            choice: .init(id: .server(accountID: "fixture", section: "empty"), title: "Collection row", isProviderDefault: true),
            reason: .empty, serverName: "Collection server", providerKind: .jellyfin
        )
        for pinned in [false, true] {
            try await withWindow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        MediaRowView(title: Text("Collection row"), items: [item], onSelect: { _ in })
                        HomeSectionStatusRow(issue: issue, onRetry: {})
                    }
                }
                .environment(\.plozzPinnedSidebarActive, pinned)
                .environment(\.plozzNavigationContentInset, pinned ? 64 : 0)
                .environment(\.plozzCardFocusStyle, .system)
            } inspect: { window in
                let image = try await self.snapshot(window, name: "Empty row keyline pinned \(pinned)")
                let bitmap = try XCTUnwrap(image.cgImage)
                let pixels = try self.rgba(bitmap)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: bitmap).perform([request])
                let observations = request.results ?? []
                let lines = observations.compactMap { observation in
                    observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
                }
                let text = lines.map(\.0).joined(separator: " | ")
                let headings = try observations.filter { $0.topCandidates(1).first?.string == "Collection row" }
                    .map { try self.textInkBounds($0, bitmap: bitmap, pixels: pixels) }.sorted { $0.minY < $1.minY }
                XCTAssertEqual(headings.count, 2, text)
                let reference = try XCTUnwrap(headings.first)
                let empty = try XCTUnwrap(headings.last)
                XCTAssertEqual(empty.minX, reference.minX, accuracy: 3)
                XCTAssertEqual(empty.height, reference.height, accuracy: 3)
                XCTAssertTrue(text.contains("No titles to show"), text)
                XCTAssertTrue(text.contains("Collection server"), text)
                for title in ["Details", "Retry"] {
                    let label = try XCTUnwrap(lines.first { $0.0.contains(title) }, text).1
                    let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
                    let target = try XCTUnwrap(self.focusableItem(at: point, in: window))
                    XCTAssertTrue(target.canBecomeFocused)
                    try await self.focus(target, in: window)
                    XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === target)
                }
            }
        }
    }
    #endif

    func testPersonalCollectionSourceUsesCurrentAccountBrand() throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let provider = HomeSettingsLibraryProvider(name: "Collection server", kind: kind)
            let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
            let section = CollectionSection(source: .init(
                accountID: account.account.id, collectionID: "personal", title: "Personal picks",
                serverUserID: provider.session.userID
            ))
            let choice = HomeRowChoice(collectionSection: section)
            XCTAssertNil(choice.library)
            XCTAssertEqual(choice.homeEditorProvider(in: [account]), kind)
            XCTAssertNil(choice.homeEditorProvider(in: []))
            let differentViewer = HomeRowChoice(collectionSection: CollectionSection(source: .init(
                accountID: account.account.id, collectionID: "personal", title: "Personal picks",
                serverUserID: "different-viewer"
            )))
            XCTAssertNil(differentViewer.homeEditorProvider(in: [account]))
        }
    }

    #if os(tvOS)
    func testFeaturedRailUsesTheSharedPinnedNavigationKeyline() async throws {
        let controller = HeroTrailerController()
        let coordinator = FeaturedTrailerCoordinator()
        defer { coordinator.stop() }
        let items = (0..<6).map { MediaItem(id: "aligned-\($0)", title: "Title \($0)", kind: .movie) }
        for pinned in [false, true] {
            try await withWindow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        MediaRowView(title: Text("Reference row"), items: [], onSeeAll: {}, onSelect: { _ in })
                        FeaturedMediaRow(
                            title: Text("Featured row"), items: items, scope: ObjectIdentifier(controller),
                            coordinator: coordinator, controller: controller, settings: .default,
                            resolver: { _ in nil }, isActive: false, onSeeAll: {}, onSelect: { _ in }
                        )
                    }
                }
                .disabled(true)
                .environment(\.plozzPinnedSidebarActive, pinned)
                .environment(\.plozzNavigationContentInset, pinned ? 64 : 0)
                .environment(\.plozzCardFocusStyle, .system)
            } inspect: { window in
                let image = try await self.snapshot(window, name: "Featured keyline pinned \(pinned)")
                let bitmap = try XCTUnwrap(image.cgImage)
                let pixels = try self.rgba(bitmap)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: bitmap).perform([request])
                let lines = request.results ?? []
                let reference = try self.textInkBounds(
                    XCTUnwrap(lines.first { $0.topCandidates(1).first?.string == "Reference row" }),
                    bitmap: bitmap, pixels: pixels
                )
                let featured = try self.textInkBounds(
                    XCTUnwrap(lines.first { $0.topCandidates(1).first?.string == "Featured row" }),
                    bitmap: bitmap, pixels: pixels
                )
                XCTAssertEqual(featured.minX, reference.minX, accuracy: 3)
                XCTAssertEqual(featured.height, reference.height, accuracy: 3)
                let actions = try lines.filter { $0.topCandidates(1).first?.string == "See all" }
                    .map { try self.textInkBounds($0, bitmap: bitmap, pixels: pixels) }
                XCTAssertEqual(actions.count, 2)
                if actions.count == 2 {
                    XCTAssertEqual(actions[0].maxX, actions[1].maxX, accuracy: 3)
                    XCTAssertEqual(actions[0].height, actions[1].height, accuracy: 3)
                }
                let y = Int(featured.maxY) + 150
                let edge = try XCTUnwrap((0..<bitmap.width / 2).first { x in
                    pixels[(y * bitmap.width + x) * 4] > 3
                })
                XCTAssertEqual(CGFloat(edge), reference.minX, accuracy: 4,
                               "The resting artwork and both headings must share the same keyline.")
            }
        }
    }

    func testFeaturedNativeCardDoesNotExposeBackingAroundDarkArtwork() async throws {
        var frames: [Int: CGRect] = [:]
        var focused: Set<Int> = []
        try await withWindow {
            HStack(spacing: 50) {
                ForEach(0..<2) { index in
                    FeaturedCornerFixture(
                        onFrame: { frames[index] = $0 },
                        onFocus: { value in
                            if value { focused.insert(index) } else { focused.remove(index) }
                        }
                    )
                }
            }
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .light)
        } inspect: { window in
            let image = try await self.snapshot(window, name: "Featured resting dark corners")
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(focused.count, 1)
            let index = try XCTUnwrap((0..<2).first { !focused.contains($0) })
            let frame = try XCTUnwrap(frames[index])
            let bitmap = try XCTUnwrap(image.cgImage)
            let pixels = try self.rgba(bitmap)
            var lightest = 0
            for x in Int(frame.minX)..<Int(frame.maxX) {
                for y in Int(frame.minY)..<Int(frame.maxY) {
                    guard x < Int(frame.minX) + 24 || x >= Int(frame.maxX) - 24
                            || y < Int(frame.minY) + 24 || y >= Int(frame.maxY) - 24 else { continue }
                    let index = (y * bitmap.width + x) * 4
                    lightest = max(lightest, Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
                }
            }
            XCTAssertLessThan(lightest, 12, "A second artwork clip must not uncover the native card's light backing.")
        }
    }

    func testReorderInitialTargetOwnsNativeFocusWithoutAnotherSelection() async throws {
        try await withWindow {
            LiftableReorderList(
                sections: .init(enabled: [0, 1, 2], disabled: []),
                disabledSectionTitle: "Hidden", disabledPlaceholder: "None",
                isLifting: .constant(false), allowsHiding: false, initialElement: 1,
                row: { .init(title: Text(verbatim: "Section \($0)")) }, onChange: { _ in }
            )
        } inspect: { window in
            let lines = try await self.capture(window, name: "Selected section lifted")
            let label = try XCTUnwrap(lines.first { $0.0.contains("Section 1") }).1
            let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
            let target = try XCTUnwrap(self.focusableItem(at: point, in: window))
            let system = try XCTUnwrap(UIFocusSystem(for: window))
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in system.focusedItem === target }, object: nil
            )
            await self.fulfillment(of: [focused], timeout: 3)
        }
    }
    #endif

    func testCollectionEditorPreviewsActualTitlesBesidePresentationChoices() async throws {
        for style in CollectionSection.CardStyle.allCases {
            let requested = expectation(description: "Collection preview requested")
            let provider = HomeSettingsLibraryProvider(
                name: "Collection server",
                collectionItems: [MediaItem(id: "orbit", title: "Orbit", kind: .movie)],
                onCollectionRequest: { requested.fulfill() }
            )
            let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
            let section = CollectionSection(
                source: .init(
                    accountID: account.account.id, collectionID: "weekend",
                    title: "Weekend picks", serverUserID: account.provider.session.userID
                ),
                cardStyle: style
            )
            let suite = "CollectionPreview.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
            try await withWindow {
                CollectionSectionSettingsView(
                    section: section, isNew: true, inventory: HomeSectionCatalogModel(),
                    visibility: visibility, libraries: [], accounts: [account]
                )
                #if os(tvOS)
                .frame(width: SettingsFormMetrics.pageWidth)
                #elseif os(iOS)
                .environment(\.plozzMetrics, .touch(density: .standard))
                #endif
            } inspect: { window in
                await self.fulfillment(of: [requested], timeout: 5)
                let lines = try await self.capture(window, name: "Collection preview \(style.rawValue)")
                let text = lines.map(\.0).joined(separator: " ")
                XCTAssertTrue(text.contains("Weekend picks"), text)
                XCTAssertTrue(text.contains("Orbit"), "Preview must display the provider's title: \(text)")
                XCTAssertGreaterThan(try self.y("Posters", in: lines), try self.y("Orbit", in: lines))
                XCTAssertTrue(visibility.visibility.collectionSections.isEmpty, "Previewing does not save a section.")
            }
        }
    }

    #if os(tvOS)
    func testEmptyCollectionSeeAllIsFocusableAndReportsRowEntry() async throws {
        var entries = 0
        try await withWindow {
            MediaRowView(
                title: Text("Weekend picks"), items: [],
                onFocusEntered: { entries += 1 },
                onSeeAll: {}, onSelect: { _ in }
            )
        } inspect: { window in
            let lines = try await self.capture(window, name: "Empty collection navigation")
            XCTAssertTrue(lines.contains { $0.0.contains("No titles") })
            let label = try XCTUnwrap(lines.first { $0.0.contains("See all") }).1
            let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
            let item = try XCTUnwrap(self.focusableItem(at: point, in: window))
            let system = try XCTUnwrap(UIFocusSystem(for: window))
            system.requestFocusUpdate(to: item)
            system.updateFocusIfNeeded()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in system.focusedItem === item && entries > 0 }, object: nil
            )
            await self.fulfillment(of: [focused], timeout: 3)
        }
    }
    #endif

    func testReorderRemovalPreservesOtherSettingsAndRemainsAvailableToAdd() throws {
        let suite = "HomeReorderRemoval.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        let visibility = HomeLibraryVisibilityModel(store: store)
        visibility.useRowDefaults(.combined)
        let catalog = HomeSectionCatalog(libraries: [])
        var session = HomeSectionReorderSession(catalog: catalog, visibility: visibility.visibility)
        let original = catalog.sections(in: session.visibility).enabled
        visibility.setContinueWatchingShowsSeriesArtwork(false)
        try session.remove(.global(.continueWatching), savingTo: visibility)
        XCTAssertEqual(catalog.sections(in: session.visibility).enabled, original.filter { $0 != .global(.continueWatching) })
        XCTAssertTrue(catalog.sections(in: store.load()).disabled.contains(.global(.continueWatching)))
        XCTAssertFalse(store.load().continueWatchingShowsSeriesArtwork)
        XCTAssertThrowsError(try session.remove(.server(accountID: "missing", section: "missing"), savingTo: visibility))
        try visibility.setHomeSectionVisible(true, id: .global(.continueWatching), catalog: catalog)
        XCTAssertEqual(catalog.sections(in: store.load()).enabled.last, .global(.continueWatching))
        XCTAssertFalse(store.load().continueWatchingShowsSeriesArtwork)
    }

    func testAddSectionSeparatesCreationFromAvailableSections() async throws {
        let suite = "HomeAddSectionLanguage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        visibility.setGlobalRowEnabled(false, for: .recentlyAdded)
        try await withWindow {
            HomeAddSectionView(
                inventory: HomeSectionCatalogModel(), visibility: visibility, libraries: [], accounts: []
            )
            #if os(tvOS)
            .frame(width: SettingsFormMetrics.pageWidth)
            #endif
        } inspect: { window in
            let lines = try await self.capture(window, name: "Create or add a Home section")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertFalse(text.contains("Start with a library collection"), text)
            XCTAssertGreaterThan(try self.y("From a collection", in: lines), try self.y("Available rows", in: lines))
            XCTAssertGreaterThan(try self.y("Available rows", in: lines), try self.y("Recently Added", in: lines))
            XCTAssertFalse(text.contains("Choose the titles"), text)
            XCTAssertTrue(visibility.visibility.collectionSections.isEmpty)
        }
    }

    func testAddRowShowsAnEmptyStateWithoutAnEmptyHeading() async throws {
        let suite = "HomeAddEmpty.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        visibility.setMergeNextUpIntoContinueWatching(true)
        let inventory = HomeSectionCatalogModel()
        try await withWindow {
            HomeAddSectionView(inventory: inventory, visibility: visibility, libraries: [], accounts: [])
                #if os(tvOS)
                .frame(width: SettingsFormMetrics.pageWidth)
                #endif
        } inspect: { window in
            let lines = try await self.capture(window, name: "Home Add row empty state")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("From a collection"), text)
            XCTAssertTrue(text.contains("No additional rows available."), text)
            XCTAssertFalse(text.contains("Available rows"), text)
            XCTAssertTrue(text.contains("Next Up is included in Continue Watching."), text)
        }
    }

    func testAddRowShowsDiscoveryFailureAndClearsItAfterRecovery() async throws {
        for kind in [ProviderKind.jellyfin, .plex] {
            let suite = "HomeAddRecovery.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
            visibility.useRowDefaults(.combined)
            visibility.setMergeNextUpIntoContinueWatching(true)
            let provider = HomeSettingsLibraryProvider(
                name: "Basement", homeError: .serverUnreachable, kind: kind,
                homeLayout: .init(
                    sections: [.init(id: "native", kind: .recommendations, title: "Native picks")],
                    source: .promotedHubs
                )
            )
            let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
            let inventory = HomeSectionCatalogModel()
            try await withWindow {
                HomeAddSectionView(
                    inventory: inventory, visibility: visibility, libraries: [], accounts: [account]
                )
                #if os(tvOS)
                .frame(width: SettingsFormMetrics.pageWidth)
                #endif
            } inspect: { window in
                let failed = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        !inventory.isLoading && inventory.serverFailures[account.account.id] == .serverUnreachable
                    }, object: nil
                )
                await self.fulfillment(of: [failed], timeout: 5)
                let lines = try await self.capture(window, name: "Add row failed discovery \(kind)")
                let text = lines.map(\.0).joined(separator: " ")
                XCTAssertTrue(text.contains("Basement is offline."), text)
                XCTAssertTrue(text.contains("Retry"), text)
                XCTAssertFalse(text.contains("No additional rows available."), text)
                #if os(tvOS)
                let retry = try XCTUnwrap(lines.first { $0.0 == "Retry" }).1
                XCTAssertNotNil(self.focusableItem(at: CGPoint(
                    x: retry.midX * window.bounds.width, y: (1 - retry.midY) * window.bounds.height
                ), in: window))
                #endif
                await provider.setHomeError(nil)
                await inventory.load(libraries: [], accounts: [account], visibility: visibility)
                let recovered = try await self.capture(window, name: "Add row recovered discovery \(kind)")
                let recoveredText = recovered.map(\.0).joined(separator: " ")
                XCTAssertTrue(recoveredText.contains("Native picks"), recoveredText)
                XCTAssertFalse(recoveredText.contains("Basement is offline."), recoveredText)
                XCTAssertFalse(recoveredText.contains("Retry"), recoveredText)
            }
        }
    }

    func testReorderSnapshotSavesKnownRowsBeforeOrAfterDiscoveryWithoutLosingPreferences() async throws {
        for completesBeforeMove in [false, true] {
            let suite = "HomeReorderSnapshot.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = HomeLibraryVisibilityStore(defaults: defaults)
            let visibility = HomeLibraryVisibilityModel(store: store)
            visibility.useRowDefaults(.matchServer)
            let requested = expectation(description: "Native layout discovery remains pending")
            let provider = HomeSettingsLibraryProvider(
                name: "Slow server", kind: .plex,
                homeLayout: .init(
                    sections: [.init(id: "native", kind: .recommendations)], source: .promotedHubs
                ),
                holdsHome: true, onFirstHomeRequest: { requested.fulfill() }
            )
            defer { Task { await provider.resumeHome() } }
            let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
            let inventory = HomeSectionCatalogModel()
            let load = Task { await inventory.load(libraries: [], accounts: [account], visibility: visibility) }
            await fulfillment(of: [requested], timeout: 5)
            var session = HomeSectionReorderSession(catalog: inventory.catalog, visibility: visibility.visibility)
            let original = session.catalog.sections(in: session.visibility).enabled
            XCTAssertGreaterThan(original.count, 1)
            let saved = store.load()
            try session.move(original, savingTo: visibility)
            XCTAssertEqual(store.load(), saved, "Entering Reorder or making no move must not freeze a preset.")
            if completesBeforeMove {
                await provider.resumeHome()
                await load.value
                XCTAssertEqual(session.catalog.sections(in: session.visibility).enabled, original)
            }
            visibility.setContinueWatchingShowsSeriesArtwork(false)
            let reordered = Array(original.reversed())
            try session.move(reordered, savingTo: visibility)
            XCTAssertEqual(store.load().rowCustomization?.defaults, .custom)
            XCTAssertFalse(store.load().continueWatchingShowsSeriesArtwork,
                           "Saving a reorder must not overwrite unrelated settings changed after entry.")
            if !completesBeforeMove {
                await provider.resumeHome()
                await load.value
            }
            XCTAssertEqual(inventory.catalog.sections(in: visibility.visibility).enabled, reordered)
            XCTAssertEqual(inventory.catalog.sections(in: store.load()).enabled, reordered)
            XCTAssertTrue(inventory.catalog.sections(in: visibility.visibility).disabled.contains(
                .server(accountID: account.account.id, section: "native")
            ), "Late discoveries remain available to add without changing the saved arrangement.")
            XCTAssertFalse(inventory.isLoading)
        }
    }

    #if os(tvOS)
    func testAddSectionIsFocusableBeforeDiscoveryFinishes() async throws {
        let suite = "HomeAddImmediateFocus.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        visibility.setGlobalRowEnabled(false, for: .recentlyAdded)
        let requested = expectation(description: "Discovery remains pending while adding a known section")
        let provider = HomeSettingsLibraryProvider(
            name: "Slow server", holdsHome: true, onFirstHomeRequest: { requested.fulfill() }
        )
        defer { Task { await provider.resumeHome() } }
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let inventory = HomeSectionCatalogModel()
        try await withWindow {
            HomeAddSectionView(inventory: inventory, visibility: visibility, libraries: [], accounts: [account])
                .frame(width: SettingsFormMetrics.pageWidth)
        } inspect: { window in
            await self.fulfillment(of: [requested], timeout: 5)
            XCTAssertTrue(inventory.isLoading)
            let lines = try await self.capture(window, name: "Add row during pending discovery")
            let label = try XCTUnwrap(lines.first { $0.0.contains("Recently Added") }).1
            let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
            let item = try XCTUnwrap(self.focusableItem(at: point, in: window),
                                    "Known sections must remain enabled while optional discovery runs.")
            let system = try XCTUnwrap(UIFocusSystem(for: window))
            system.requestFocusUpdate(to: item)
            system.updateFocusIfNeeded()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in system.focusedItem === item }, object: nil
            )
            await self.fulfillment(of: [focused], timeout: 2)
            XCTAssertTrue(inventory.isLoading, "Focus must not depend on the held provider finishing.")
            try visibility.setHomeSectionVisible(true, id: .global(.recentlyAdded), catalog: inventory.currentCatalog(
                libraries: [], accounts: [account], visibility: visibility
            ))
            await provider.resumeHome()
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !inventory.isLoading }, object: nil
            )
            await self.fulfillment(of: [finished], timeout: 5)
            XCTAssertTrue(inventory.catalog.sections(in: visibility.visibility).enabled.contains(.global(.recentlyAdded)))
        }
        await provider.resumeHome()
    }

    func testReorderRemainsFocusableDuringSlowDiscoveryAndFailure() async throws {
        let suite = "HomeReorderDiscovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let requested = expectation(description: "Server discovery remains pending")
        let provider = HomeSettingsLibraryProvider(
            name: "Slow server", homeError: .serverUnreachable, holdsHome: true,
            onFirstHomeRequest: { requested.fulfill() }
        )
        defer { Task { await provider.resumeHome() } }
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let inventory = HomeSectionCatalogModel()
        try await withWindow {
            HomeSectionsSettingsView(libraries: [], accounts: [account], visibility: visibility, inventory: inventory)
                .frame(width: SettingsFormMetrics.pageWidth)
        } inspect: { window in
            await self.fulfillment(of: [requested], timeout: 5)
            XCTAssertTrue(inventory.isLoading)
            XCTAssertGreaterThan(inventory.catalog.sections(in: visibility.visibility).enabled.count, 1)
            try await self.assertReorderFocusable(in: window, name: "Reorder during pending discovery")
            await provider.resumeHome()
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !inventory.isLoading }, object: nil
            )
            await self.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(inventory.serverFailures[account.account.id], .serverUnreachable)
            try await self.assertReorderFocusable(in: window, name: "Reorder after discovery failure")
            let requests = await provider.homeRequests
            XCTAssertEqual(requests, 1, "An idle page must not retry a failed server automatically.")
        }
        await provider.resumeHome()
    }

    private func assertReorderFocusable(in window: UIWindow, name: String) async throws {
        let lines = try await capture(window, name: name)
        let label = try XCTUnwrap(lines.first { $0.0.contains("Edit") }).1
        let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
        XCTAssertNotNil(focusableItem(at: point, in: window),
                        "Known sections must be reorderable without waiting for server discovery.")
    }

    private func focusableItem(at point: CGPoint, in window: UIWindow) -> (any UIFocusItem)? {
        focusTarget(at: point, in: window)?.item
    }

    private func focusTarget(at point: CGPoint, in window: UIWindow) -> (item: any UIFocusItem, frame: CGRect)? {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let bounds = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: bounds) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                let frame = container.coordinateSpace.convert(item.frame, to: window)
                if !(item is UIScrollView), item.canBecomeFocused, frame.contains(point) { return (item, frame) }
            }
        }
        return nil
    }
    #endif

    func testPresetSelectionRefreshesRecoveredNativeSectionsBeforeSavingCustomRows() async throws {
        let suite = "HomePresetRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeSettingsLibraryProvider(
            name: "Recovered server", homeError: .serverUnreachable, kind: .plex,
            homeLayout: .init(sections: [.init(id: "native", kind: .recommendations)], source: .promotedHubs)
        )
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let inventory = HomeSectionCatalogModel()
        await inventory.load(libraries: [], accounts: [account], visibility: visibility)
        XCTAssertEqual(inventory.serverFailures[account.account.id], .serverUnreachable)

        try await withWindow {
            HomeSectionsSettingsView(libraries: [], accounts: [account], visibility: visibility, inventory: inventory)
        } inspect: { window in
            _ = try await self.capture(window, name: "Preset before server recovery")
            await provider.setHomeError(nil)
            visibility.useRowDefaults(.matchServer)
            let native = HomeRowID.server(accountID: account.account.id, section: "native")
            let recovered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    !inventory.isLoading && inventory.serverFailures.isEmpty
                        && inventory.catalog.sections(in: visibility.visibility).enabled == [native]
                }, object: nil
            )
            await self.fulfillment(of: [recovered], timeout: 5)
            try visibility.setHomeSectionVisible(true, id: .libraries, catalog: inventory.catalog)
            XCTAssertEqual(inventory.catalog.sections(in: visibility.visibility).enabled, [native, .libraries])
            _ = try await self.capture(window, name: "Preset after server recovery")
        }
    }

    #if os(tvOS)
    private struct FeaturedCornerFixture: View {
        let onFrame: (CGRect) -> Void
        let onFocus: (Bool) -> Void
        @FocusState private var focused: Bool

        var body: some View {
            Button {} label: {
                FeaturedCardArtwork(
                    item: MediaItem(id: "corners", title: "Dark artwork", kind: .movie),
                    size: CGSize(width: 520.25, height: 650.3125), usesNativeClipping: true
                ) {
                    Color.black
                }
            }
            .buttonStyle(.card)
            .buttonBorderShape(.roundedRectangle(radius: 20))
            .focused($focused)
            .frame(width: 520.25, height: 650.3125)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
            .onChange(of: focused, initial: true) { _, value in onFocus(value) }
        }
    }
    #endif

    #if os(iOS)
    func testMobilePresetScrollsWithSectionsWhileToolbarRemainsVisible() async throws {
        let suite = "HomeScrollingPreset.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        let provider = HomeSettingsLibraryProvider(name: "Library server", kind: .mediaShare)
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let libraries = (1...18).map {
            AggregatedLibrary(
                accountID: account.account.id, accountName: "Viewer", serverName: "Library server",
                providerKind: .mediaShare,
                library: MediaLibrary(id: "library-\($0)", title: "Library \($0)", kind: .movie)
            )
        }
        let choices = HomeRowChoice.shared + libraries.flatMap(HomeRowChoice.baseRows)
        visibility.applyRows(.init(enabled: choices.map(\.id), disabled: []), choices: choices)
        for (width, size, scheme): (CGFloat, DynamicTypeSize, ColorScheme) in [
            (390, .large, .dark), (390, .large, .light),
            (320, .accessibility5, .dark), (1024, .accessibility3, .dark)
        ] {
            let inventory = HomeSectionCatalogModel()
            try await withWindow(size: CGSize(width: width, height: 900), colorScheme: scheme) {
                NavigationStack {
                    HomeSectionsSettingsView(
                        libraries: libraries, accounts: [account], visibility: visibility, inventory: inventory
                    )
                }
                .environment(\.dynamicTypeSize, size)
            } inspect: { window in
                let ready = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        !inventory.isLoading && inventory.catalog.choices.contains {
                            $0.library?.library.id == "library-18"
                        }
                    }, object: nil
                )
                await self.fulfillment(of: [ready], timeout: 5)
                let before = try await self.capture(window, name: "Home preset header \(width) \(size) \(scheme)")
                let text = before.map(\.0).joined(separator: " ")
                    .replacingOccurrences(of: "- ", with: "")
                for label in ["Preset", "Edit", "Custom"] {
                    XCTAssertTrue(text.contains(label), text)
                }
                func scrollViews(_ view: UIView) -> [UIScrollView] {
                    (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                let scroll = try XCTUnwrap(scrollViews(window).first {
                    $0.contentSize.height > $0.bounds.height + 300
                })
                let initialOffset = scroll.contentOffset.y
                scroll.setContentOffset(CGPoint(x: 0, y: initialOffset + 300), animated: false)
                let after = try await self.capture(window, name: "Home scrolled preset \(width) \(size) \(scheme)")
                XCTAssertGreaterThan(scroll.contentOffset.y, initialOffset + 250)
                XCTAssertFalse(after.contains { $0.0.contains("Preset") },
                               "The preset must scroll away rather than remain pinned below the toolbar.")
                XCTAssertEqual(try self.y("Edit", in: before), try self.y("Edit", in: after), accuracy: 0.003)
                scroll.setContentOffset(CGPoint(x: 0, y: initialOffset), animated: false)
                let restored = try await self.capture(window, name: "Home preset restored \(width) \(size) \(scheme)")
                XCTAssertEqual(try self.y("Preset", in: before), try self.y("Preset", in: restored), accuracy: 0.003)
            }
        }
    }

    func testPushingAddSectionFinishesDiscoveryAfterTheRootDisappears() async throws {
        let suite = "HomeAddDiscovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let requested = expectation(description: "Root starts a held native-section request")
        let provider = HomeSettingsLibraryProvider(
            name: "Slow server", kind: .plex,
            homeLayout: .init(
                sections: [.init(id: "native", kind: .recommendations, title: "Native picks")], source: .promotedHubs
            ),
            holdsHome: true, onFirstHomeRequest: { requested.fulfill() }
        )
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let inventory = HomeSectionCatalogModel()
        let navigation = HomeCatalogNavigationFixture()
        try await withWindow {
            HomeCatalogNavigationHost(navigation: navigation, inventory: inventory, visibility: visibility, accounts: [account])
        } inspect: { window in
            await self.fulfillment(of: [requested], timeout: 5)
            XCTAssertTrue(inventory.isLoading)
            navigation.path = ["add"]
            let pushed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in navigation.rootDisappeared && navigation.addAppeared }, object: nil
            )
            await self.fulfillment(of: [pushed], timeout: 5)
            await provider.resumeHome()
            let native = HomeRowID.server(accountID: account.account.id, section: "native")
            let discovered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    !inventory.isLoading && inventory.catalog.sections(in: visibility.visibility).disabled.contains(native)
                }, object: nil
            )
            await self.fulfillment(of: [discovered], timeout: 5)
            let lines = try await self.capture(window, name: "Native section discovered on Add row")
            XCTAssertTrue(lines.contains { $0.0.contains("Native picks") }, lines.map(\.0).joined(separator: " "))
            try visibility.setHomeSectionVisible(true, id: native, catalog: inventory.catalog)
            navigation.path = []
            let returned = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !navigation.addAppeared }, object: nil
            )
            await self.fulfillment(of: [returned], timeout: 5)
            XCTAssertTrue(inventory.catalog.sections(in: visibility.visibility).enabled.contains(native))
        }
        await provider.resumeHome()
    }
    #endif

    func testMergeNextUpControlIsReadableAndReflectsHiddenContinueWatching() async throws {
        let suite = "HomeNextUpControl.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        )
        for scheme: ColorScheme in [.light, .dark] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                visibility.setGlobalRowEnabled(true, for: .continueWatching)
                try await withWindow {
                    ScrollView {
                        ContinueWatchingNextUpControl(visibility: visibility)
                            .padding(32)
                    }
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.themePalette, scheme == .light ? ThemePalette.light : .dark)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .light ? Color.white : Color.black)
                    #if os(tvOS)
                    .frame(width: 900, height: 650)
                    #endif
                } inspect: { window in
                    let lines = try await self.capture(
                        window, name: "Merge Next Up \(scheme) \(size)", scale: window.traitCollection.displayScale
                    )
                    let text = lines.map(\.0).joined(separator: " ")
                    XCTAssertTrue(text.contains("Include Next Up"), text)
                    XCTAssertTrue(text.contains("Combines Next Up rows here."), text)
                    visibility.setGlobalRowEnabled(false, for: .continueWatching)
                    let disabled = try await self.capture(
                        window, name: "Merge Next Up with hidden Continue Watching", scale: window.traitCollection.displayScale
                    )
                    let disabledText = disabled.map(\.0).joined(separator: " ")
                    XCTAssertTrue(disabledText.contains("Add Continue Watching"), disabledText)
                }
            }
        }
    }

    func testContinueWatchingSectionOrdersArtworkAndGroupedControls() async throws {
        let suite = "HomeSectionLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.continueWatching) })
        let page = HomeSectionSettingsView(
            choice: choice, inventory: HomeSectionCatalogModel(),
            visibility: visibility, libraries: [], accounts: []
        )
        try await withWindow(size: CGSize(width: 1100, height: 1600)) {
            Group {
                #if os(tvOS)
                page.environment(\.settingsPageBackButton, AnyView(SettingsBackButton {}))
                #else
                NavigationStack { page }
                #endif
            }
            .environment(\.horizontalSizeClass, .regular)
        } inspect: { window in
            let lines = try await self.capture(window, name: "Continue Watching grouped section layout")
            XCTAssertEqual(lines.filter { $0.0 == "Continue Watching" }.count, 1,
                           "The section must not repeat its heading in the native navigation bar.")
            #if os(tvOS)
            let actionTitle = "Center button action"
            #else
            let actionTitle = "When tapping an item"
            #endif
            let controls = ["Playback details", "Labels", "Include Next Up", actionTitle]
            let detailsY = try self.y("Playback details", in: lines)
            XCTAssertLessThan(try self.y("Appearance also applies", in: lines), try self.y("Labels", in: lines))
            XCTAssertGreaterThan(try self.y("Appearance also applies", in: lines), try self.y("Include Next Up", in: lines))
            for artwork in ["Artwork + logo", "Thumbnail", "Poster"] {
                XCTAssertGreaterThan(try self.y(artwork, in: lines), detailsY,
                                     "All three artwork choices belong above the settings groups.")
            }
            for (upper, lower) in zip(controls, controls.dropFirst()) {
                XCTAssertGreaterThan(try self.y(upper, in: lines), try self.y(lower, in: lines),
                                     "\(upper) must appear before \(lower).")
            }
            XCTAssertGreaterThan(try self.y(actionTitle, in: lines),
                                 try self.y("Remove from Home", in: lines))
            #if os(tvOS)
            XCTAssertFalse(lines.contains { $0.0.contains("Back") },
                           "The shared back control shows only its chevron.")
            for title in controls {
                let label = try XCTUnwrap(lines.first { $0.0.contains(title) }).1
                let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
                XCTAssertNotNil(self.focusableItem(at: point, in: window), title)
            }
            #endif
        }
    }

    func testContinueWatchingActionControlShowsCurrentProfileChoice() async throws {
        let suite = "HomeActionControl.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        let visibility = HomeLibraryVisibilityModel(store: store)
        #if os(tvOS)
        let actionTitle = "Center button action"
        #else
        let actionTitle = "When tapping an item"
        #endif
        try await withWindow {
            ScrollView {
                Group {
                    #if os(tvOS)
                    SettingsControlGroup { ContinueWatchingActionControl(visibility: visibility) }
                    #else
                    SettingsSectionGroup { ContinueWatchingActionControl(visibility: visibility) }
                    #endif
                }
                .padding(32)
            }
            #if os(tvOS)
            .frame(width: 900, height: 650)
            #endif
        } inspect: { window in
            for action in [ContinueWatchingAction.play, .openDetails, .play] {
                visibility.setContinueWatchingAction(action)
                let lines = try await self.capture(window, name: "Continue Watching action \(action)")
                let text = lines.map(\.0).joined(separator: " ")
                XCTAssertTrue(text.contains(actionTitle), text)
                XCTAssertTrue(text.contains(String(localized: action.displayName)), text)
                XCTAssertEqual(store.load().continueWatchingAction, action)
                #if os(tvOS)
                XCTAssertTrue(text.contains("Play/Pause always starts playback."), text)
                XCTAssertLessThan(
                    try self.y("Play/Pause", in: lines), try self.y(actionTitle, in: lines),
                    "The explanation belongs below the selection control."
                )
                let label = try XCTUnwrap(lines.first { $0.0.contains(actionTitle) }).1
                let point = CGPoint(x: label.midX * window.bounds.width, y: (1 - label.midY) * window.bounds.height)
                XCTAssertNotNil(self.focusableItem(at: point, in: window))
                #endif
            }
        }
    }

    #if os(iOS)
    func testMobileCustomizeHomeListsSectionsWithoutDetachedArtworkOrMergeControls() async throws {
        let suite = "MobileHomeNextUp.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        let visibility = HomeLibraryVisibilityModel(store: store)
        visibility.useRowDefaults(.combined)
        visibility.setMergeNextUpIntoContinueWatching(true)
        try await withWindow {
            NavigationStack {
                PlozziOSHomeSettingsView(
                    hero: HeroSettingsModel(store: InMemoryHeroSettingsStore()),
                    heroBackground: HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore()),
                    cards: CardStyleSettingsModel(),
                    visibility: visibility, accounts: []
                )
            }
        } inspect: { window in
            let lines = try await self.capture(window, name: "Mobile Home artwork without duplicate merge toggle")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Reorder"), text)
            XCTAssertTrue(text.contains("Hero"), text)
            XCTAssertTrue(text.contains("Continue Watching"), text)
            XCTAssertTrue(text.contains("Add row"), text)
            XCTAssertFalse(text.contains("Artwork"), text)
            XCTAssertFalse(text.contains("Include Next Up"), text)
            XCTAssertFalse(text.contains("No video libraries are available"), text)
            XCTAssertTrue(store.load().mergeNextUpIntoContinueWatching)

            visibility.setGlobalRowEnabled(false, for: .continueWatching)
            let hidden = try await self.capture(window, name: "Mobile Home with Continue Watching hidden")
            let hiddenText = hidden.map(\.0).joined(separator: " ")
            XCTAssertFalse(hiddenText.contains("Artwork"), hiddenText)
            XCTAssertFalse(hiddenText.contains("CONTINUE WATCHING"), "Do not leave an empty section for a hidden row.")
            XCTAssertFalse(hiddenText.contains("Include Next Up"), hiddenText)
            XCTAssertTrue(store.load().mergeNextUpIntoContinueWatching)
        }
    }

    func testMobileAllScreensKeepsRatingsAndSpoilerControlsIndependent() async throws {
        let suite = "MobileAllScreens.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ContentRatingSettingsStore(defaults: defaults, namespace: "viewer")
        let ratings = ContentRatingSettingsModel(store: store)
        let spoilers = SpoilerSettingsModel(store: SpoilerSettingsStore(defaults: defaults, namespace: "viewer"))
        try await withWindow {
            NavigationStack {
                PlozziOSAllScreensSettingsView(contentRatings: ratings, spoilers: spoilers)
            }
        } inspect: { window in
            let before = try await self.capture(window, name: "All screens settings")
            let text = before.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("All screens"), text)
            XCTAssertTrue(text.contains("Show content ratings"), text)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("Spoiler Protection"), text)
            XCTAssertTrue(text.contains("Protect unwatched episodes"), text)
            XCTAssertTrue(text.contains("Hide ratings until watched"), text)
            func switches(_ view: UIView) -> [UISwitch] {
                (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches)
            }
            let controls = switches(window).sorted {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            }
            XCTAssertEqual(controls.count, 3)
            let control = try XCTUnwrap(controls.first)
            XCTAssertTrue(control.isOn)
            control.setOn(false, animated: false)
            control.sendActions(for: .valueChanged)
            let after = try await self.capture(window, name: "All screens ratings off")
            XCTAssertFalse(store.load())
            XCTAssertTrue(ContentRatingSettingsStore(defaults: defaults, namespace: "other").load())
            XCTAssertTrue(after.contains { $0.0.contains("All screens") })
            XCTAssertTrue(after.contains { $0.0.contains("Hide ratings until watched") })
            XCTAssertEqual(spoilers.settings, .default)
            let protect = try XCTUnwrap(controls.dropFirst().first)
            protect.setOn(true, animated: false)
            protect.sendActions(for: .valueChanged)
            _ = try await self.capture(window, name: "All screens spoiler protection enabled")
            XCTAssertTrue(SpoilerSettingsStore(defaults: defaults, namespace: "viewer").load().isEnabled)
            XCTAssertFalse(SpoilerSettingsStore(defaults: defaults, namespace: "other").load().isEnabled)
            XCTAssertFalse(store.load(), "Spoiler controls must not change content-rating badges.")
            XCTAssertFalse(spoilers.settings.hideRatingsUntilWatched)
        }
    }

    func testMobileHomeListsFilteringWithoutInlineWatchedSwitches() async throws {
        try await withWindow {
            NavigationStack {
                HomeRowsSettingsView(
                    libraries: [], accounts: [],
                    visibility: HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: UUID().uuidString))
                )
                .environment(HeroSettingsModel(store: InMemoryHeroSettingsStore()))
                .environment(HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore()))
                .environment(CardStyleSettingsModel())
            }
        } inspect: { window in
            let lines = try await self.capture(window, name: "Home settings destinations")
            let text = lines.map(\.0).joined(separator: " ")
            for label in ["Home", "Hero", "Card labels", "Rows", "Filtering"] {
                XCTAssertTrue(text.contains(label), text)
            }
            XCTAssertFalse(text.contains("Hide watched"), text)
            XCTAssertFalse(text.contains("Add row"), text)
        }
    }

    func testMobileRecentlyAddedSwitchPersistsWithoutChangingPreset() async throws {
        let suite = "MobileRecentlyAdded.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        let visibility = HomeLibraryVisibilityModel(store: store)
        visibility.useRowDefaults(.combined)
        let heroStore = InMemoryHeroSettingsStore()
        let hero = HeroSettingsModel(store: heroStore)
        try await withWindow {
            NavigationStack {
                HomeFilteringSettingsView(visibility: visibility)
                    .environment(hero)
            }
        } inspect: { window in
            let before = try await self.capture(window, name: "Recently Added filtering off")
            XCTAssertTrue(before.contains { $0.0.localizedCaseInsensitiveContains("Hide watched content") })
            XCTAssertTrue(before.contains { $0.0.contains("Recently Added") })
            XCTAssertTrue(before.contains { $0.0.contains("Hero & discovery") })
            func switches(_ view: UIView) -> [UISwitch] {
                (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches)
            }
            let controls = switches(window).sorted {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            }
            XCTAssertEqual(controls.count, 2)
            let control = try XCTUnwrap(controls.first)
            let heroControl = try XCTUnwrap(controls.last)
            XCTAssertFalse(control.isOn)
            XCTAssertTrue(heroControl.isOn)
            control.setOn(true, animated: false)
            control.sendActions(for: .valueChanged)
            _ = try await self.capture(window, name: "Recently Added filtering on")
            XCTAssertTrue(store.load().hideWatchedRecentlyAdded)
            XCTAssertTrue(hero.settings.hideWatched, "Recently Added must not change hero filtering.")
            XCTAssertEqual(visibility.visibility.rowCustomization?.defaults, .combined)
            XCTAssertFalse(HomeLibraryVisibilityStore(defaults: defaults, namespace: "other").load()
                .hideWatchedRecentlyAdded)
            control.setOn(false, animated: false)
            control.sendActions(for: .valueChanged)
            _ = try await self.capture(window, name: "Recently Added filtering restored")
            XCTAssertFalse(store.load().hideWatchedRecentlyAdded)
            heroControl.setOn(false, animated: false)
            heroControl.sendActions(for: .valueChanged)
            _ = try await self.capture(window, name: "Hero filtering off independently")
            XCTAssertFalse(hero.settings.hideWatched)
            XCTAssertFalse(heroStore.load().hideWatched)
            XCTAssertFalse(store.load().hideWatchedRecentlyAdded)
            XCTAssertEqual(visibility.visibility.rowCustomization?.defaults, .combined)
        }
    }

    func testMobileSectionMergeSwitchPersistsWithoutChangingPreset() async throws {
        let suite = "MobileHomeRowsNextUp.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        let visibility = HomeLibraryVisibilityModel(store: store)
        visibility.useRowDefaults(.combined)
        try await withWindow {
            NavigationStack {
                HomeSectionSettingsView(
                    choice: HomeRowChoice.shared.first { $0.id == .global(.continueWatching) }!,
                    inventory: HomeSectionCatalogModel(), visibility: visibility, libraries: [], accounts: []
                )
            }
        } inspect: { window in
            _ = try await self.capture(window, name: "Mobile Rows on Home merge setting")
            func switches(_ view: UIView) -> [UISwitch] {
                (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches)
            }
            let control = try XCTUnwrap(switches(window).first)
            var ancestor = control.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.scrollRectToVisible(control.convert(control.bounds, to: scroll), animated: false)
                    break
                }
                ancestor = view.superview
            }
            XCTAssertTrue(control.isOn)
            control.setOn(false, animated: false)
            control.sendActions(for: .valueChanged)
            let lines = try await self.capture(window, name: "Mobile Rows on Home with Next Up separate")
            XCTAssertFalse(store.load().mergeNextUpIntoContinueWatching)
            XCTAssertEqual(visibility.visibility.rowCustomization?.defaults, .combined)
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Continue Watching"), text)
            XCTAssertTrue(text.contains("Include Next Up"), text)
        }
    }

    func testNativeReorderPreviewHasRoundedCorners() async throws {
        try await withWindow {
            LiftableReorderList(
                sections: .init(enabled: ["Alpha", "Beta"], disabled: []),
                disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden rows",
                isLifting: .constant(false),
                row: { .init(title: Text(verbatim: $0), subtitle: Text("Movies")) },
                onChange: { _ in }
            )
            .padding(24)
        } inspect: { window in
            _ = try await self.capture(window, name: "Native reorder rows")
            var views: [UIView] = [window]
            var collection: UICollectionView?
            while let view = views.popLast() {
                if let list = view as? UICollectionView {
                    collection = list
                    break
                }
                views += view.subviews
            }
            let list = try XCTUnwrap(collection)
            let index = IndexPath(item: 0, section: 0)
            let parameters = try XCTUnwrap(
                list.dragDelegate?.collectionView?(list, dragPreviewParametersForItemAt: index)
            )
            let path = try XCTUnwrap(parameters.visiblePath)
            let bounds = path.bounds
            XCTAssertGreaterThan(bounds.width, 200)
            XCTAssertGreaterThan(bounds.height, 40)
            XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
            for x in [bounds.minX + 1, bounds.maxX - 1] {
                for y in [bounds.minY + 1, bounds.maxY - 1] {
                    XCTAssertFalse(path.contains(CGPoint(x: x, y: y)), "Drag previews must cut out each corner.")
                }
            }
        }
    }

    func testOfflineServerDoesNotAddAGlobalWarningToHomeCustomization() async throws {
        let suite = "HomeSettingsOffline.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        let visibility = HomeLibraryVisibilityModel(store: store)
        let offline = HomeSettingsLibraryProvider(name: "Offline server", isOffline: true)
        let online = HomeSettingsLibraryProvider(name: "Available server", isOffline: false)
        visibility.applyRows(
            .init(enabled: [.global(.continueWatching)], disabled: [.global(.watchlist)]),
            choices: HomeRowChoice.shared
        )
        let saved = store.load()
        try await withWindow {
            NavigationStack {
                PlozziOSHomeSettingsView(
                    hero: HeroSettingsModel(store: InMemoryHeroSettingsStore()),
                    heroBackground: HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore()),
                    cards: CardStyleSettingsModel(),
                    visibility: visibility,
                    accounts: [offline, online].map {
                        ResolvedAccount(account: Account(from: $0.session), provider: $0)
                    }
                )
            }
        } inspect: { window in
            let deadline = ContinuousClock.now + .seconds(3)
            while await online.libraryRequests == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let offlineRequests = await offline.libraryRequests
            XCTAssertEqual(offlineRequests, 1)
            let lines = try await self.capture(window, name: "Home customization with an offline server")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Reorder"), text)
            XCTAssertTrue(text.contains("Hero"), text)
            XCTAssertFalse(text.contains("Available server"), "Whole-library controls belong in Settings > Libraries.")
            XCTAssertFalse(text.contains("Movies"), text)
            XCTAssertFalse(text.contains("LIBRARIES"), text)
            XCTAssertFalse(text.contains("Some libraries are"), text)
            XCTAssertFalse(text.contains("Retry"), text)
            XCTAssertEqual(store.load(), saved)
        }
    }

    func testLibraryDiscoveryRefreshesForEffectiveCredentialsAndPlexViewerChanges() async throws {
        let suite = "HomeSettingsViewer.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        )
        let first = HomeSettingsLibraryProvider(name: "Server", libraryTitle: "Original movies", kind: .plex)
        let rotated = HomeSettingsLibraryProvider(name: "Server", libraryTitle: "Updated movies", kind: .plex)
        let child = HomeSettingsLibraryProvider(name: "Server", libraryTitle: "Child movies", kind: .plex)
        let account = Account(from: first.session)
        let revision = CredentialRevision()
        let updates: [(ResolvedAccount, HomeSettingsLibraryProvider, String)] = [
            (.init(account: account, provider: first, plexHomeUserID: "owner"), first, "Original movies"),
            (.init(account: account, provider: rotated, plexHomeUserID: "owner",
                   credentialRevision: revision), rotated, "Updated movies"),
            (.init(account: account, provider: child, plexHomeUserID: "child",
                   credentialRevision: revision), child, "Child movies")
        ]
        let source = HomeSettingsAccountsFixture(accounts: [updates[0].0])
        try await withWindow {
            HomeSettingsViewerHost(source: source, visibility: visibility)
        } inspect: { window in
            for (resolved, provider, title) in updates {
                source.accounts = [resolved]
                let deadline = ContinuousClock.now + .seconds(3)
                while await provider.libraryRequests == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let requests = await provider.libraryRequests
                XCTAssertEqual(requests, 1, title)
                let lines = try await self.capture(window, name: "Home settings \(title)")
                let text = lines.map(\.0).joined(separator: " ")
                XCTAssertTrue(text.contains("Reorder"), text)
                XCTAssertTrue(text.contains("Hero"), text)
                XCTAssertTrue(text.contains(title), "Expected the active viewer's \(title): \(text)")
            }
        }
    }

    func testLateLibraryFailureDoesNotRestoreRemovedLibraryManagementUI() async throws {
        let suite = "HomeSettingsLateFailure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        )
        let first = HomeSettingsLibraryProvider(name: "Server", libraryTitle: "Original movies")
        let delayed = HomeSettingsLibraryProvider(name: "Offline", isOffline: true, holdsLibraries: true)
        let current = HomeSettingsLibraryProvider(name: "Server", libraryTitle: "Current movies")
        defer { Task { await delayed.resumeLibraries() } }
        let account = Account(from: first.session)
        let source = HomeSettingsAccountsFixture(accounts: [
            .init(account: account, provider: first),
            .init(account: Account(from: delayed.session), provider: delayed)
        ])
        try await withWindow {
            HomeSettingsViewerHost(source: source, visibility: visibility)
        } inspect: { window in
            let deadline = ContinuousClock.now + .seconds(3)
            while await delayed.libraryRequests == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let delayedRequests = await delayed.libraryRequests
            XCTAssertEqual(delayedRequests, 1)
            source.accounts = [.init(account: account, provider: current)]
            let currentDeadline = ContinuousClock.now + .seconds(3)
            while await current.libraryRequests == 0, ContinuousClock.now < currentDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let currentRequests = await current.libraryRequests
            XCTAssertEqual(currentRequests, 1)
            let before = try await self.capture(window, name: "Current account libraries")
            XCTAssertTrue(before.map(\.0).joined(separator: " ").contains("Reorder"))
            await delayed.resumeLibraries()
            let after = try await self.capture(window, name: "Current libraries after stale failure")
            let text = after.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Hero"), text)
            XCTAssertTrue(text.contains("Current movies"), text)
            XCTAssertFalse(text.contains("Original movies"), text)
        }
    }
    #endif

    func testMatchServerNamesEachFailedServerWithoutCallingOtherErrorsOffline() async throws {
        let suite = "HomeRowServerFailures.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        )
        let offline = HomeSettingsLibraryProvider(name: "Basement", homeError: .serverUnreachable)
        let unauthorized = HomeSettingsLibraryProvider(name: "Cinema", homeError: .unauthorized)
        let invalid = HomeSettingsLibraryProvider(name: "Loft", homeError: .invalidResponse)
        let online = HomeSettingsLibraryProvider(name: "Available server")
        let accounts = [offline, unauthorized, invalid, online].map {
            ResolvedAccount(account: Account(from: $0.session), provider: $0)
        }
        await visibility.prepareServerDefaults(accounts: accounts)
        XCTAssertEqual(visibility.serverMatchFailures.count, 3)
        let inventory = HomeSectionCatalogModel()
        await inventory.load(libraries: [], accounts: accounts, visibility: visibility)

        try await withWindow {
            ScrollView {
                HomeCatalogStatus(inventory: inventory, accounts: accounts, libraries: [], retry: {})
                    .padding(24)
            }
            #if os(tvOS)
            .frame(width: 1050)
            #endif
        } inspect: { window in
            let lines = try await self.capture(window, name: "Named Home server failures")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Basement is offline."), text)
            XCTAssertTrue(text.contains("Sign in to Cinema again."), text)
            XCTAssertTrue(text.contains("load rows from Loft."), text)
            XCTAssertFalse(text.contains("Cinema is offline"), text)
            XCTAssertFalse(text.contains("Loft is offline"), text)
            XCTAssertFalse(text.contains("Available server is offline"), text)
            XCTAssertFalse(text.contains("server arrangements"), text)
            XCTAssertFalse(text.contains("Keeping known rows"), text)

            await offline.setHomeError(nil)
            await inventory.load(libraries: [], accounts: accounts, visibility: visibility)
            let recovered = try await self.capture(window, name: "Recovered Home server")
            let recoveredText = recovered.map(\.0).joined(separator: " ")
            XCTAssertFalse(recoveredText.contains("Basement is offline"), recoveredText)
            XCTAssertTrue(recoveredText.contains("Sign in to Cinema again."), recoveredText)
            XCTAssertTrue(recoveredText.contains("load rows from Loft."), recoveredText)
        }
    }

    func testSharedArrangerReflectsCrossLibraryOrderAndPersistsEdits() async throws {
        let suite = "HomeRowArrangement.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        let visibility = HomeLibraryVisibilityModel(store: store)
        let accounts = ["Alpha", "Beta"].map { name in
            let provider = HomeSettingsLibraryProvider(name: name, kind: .mediaShare)
            return ResolvedAccount(account: Account(from: provider.session), provider: provider)
        }
        let libraries = accounts.map {
            AggregatedLibrary(
                accountID: $0.account.id, accountName: "Viewer", serverName: "Server",
                providerKind: .mediaShare,
                library: MediaLibrary(id: $0.account.server.name, title: "\($0.account.server.name) Movies", kind: .movie)
            )
        }

        let choices = libraries.flatMap(HomeRowChoice.baseRows) + HomeRowChoice.shared
        let ids: [HomeRowID] = [
            .global(.continueWatching), .library(libraries[0].key, kind: .recentlyAdded),
            .global(.watchlist), .library(libraries[1].key, kind: .recentlyAdded)
        ]
        let hidden = HomeRowChoice.shared.map(\.id).filter { !ids.contains($0) }
        visibility.applyRows(.init(enabled: ids, disabled: hidden), choices: choices)

        try await withWindow {
            #if os(iOS)
            NavigationStack {
                HomeSectionsSettingsView(libraries: libraries, accounts: accounts, visibility: visibility)
            }
            #else
            HomeSectionsSettingsView(libraries: libraries, accounts: accounts, visibility: visibility)
            .frame(width: 1050)
            #endif
        } inspect: { window in
            let controls = try await self.capture(window, name: "Home arranger controls")
            XCTAssertFalse(controls.contains { $0.0.contains("Merge Next Up rows") })
            XCTAssertTrue(controls.contains { $0.0.contains("Home rows") }, controls.map(\.0).joined(separator: " "))
            XCTAssertFalse(controls.contains { $0.0.contains("Hero") })
            try self.scrollToBottom(window)
            let before = try await self.capture(window, name: "Home arranger original order")
            XCTAssertFalse(before.contains { $0.0.contains("Include Next Up") })
            XCTAssertFalse(before.contains { $0.0.contains("Home layout") })
            XCTAssertGreaterThan(try self.y("Alpha", in: before), try self.y("Beta", in: before))
            XCTAssertTrue(before.contains { $0.0.contains("All libraries") })
            visibility.applyRows(.init(enabled: Array(ids.reversed()), disabled: hidden), choices: choices)
            try self.scrollToBottom(window)
            let after = try await self.capture(window, name: "Home arranger reversed order")
            XCTAssertGreaterThan(try self.y("Beta", in: after), try self.y("Alpha", in: after))
            XCTAssertEqual(store.load().rowSections(choices: choices).enabled, Array(ids.reversed()))
        }
    }

    func testRowSubtitlesAndRanksRemainVisibleAtLargeTextSizes() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            try await withWindow {
                ScrollView {
                    LiftableReorderList(
                        sections: .init(enabled: ["Alpha", "Beta"], disabled: []),
                        disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden rows",
                        isLifting: .constant(false),
                        row: {
                            .init(
                                title: Text(verbatim: $0), providerKind: .jellyfin,
                                subtitle: Text("Movies"), providerMarkInSubtitle: true
                            )
                        }, onChange: { _ in }
                    )
                    .padding(30)
                }
                .environment(\.dynamicTypeSize, size)
                #if os(tvOS)
                .frame(width: 1050)
                #endif
            } inspect: { window in
                let text = try await self.capture(window, name: "Home row text size \(size)")
                XCTAssertGreaterThan(try self.y("Alpha", in: text), try self.y("Beta", in: text))
                XCTAssertEqual(text.filter { $0.0.contains("Movies") }.count, 2)
            }
        }
    }

    func testPresetSelectorReflectsSavedAndCustomLayoutsAtLargeTextSizes() async throws {
        let suite = "HomeRowPresets.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "viewer")
        )
        for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            for (preset, title): (HomeRowCustomization.Defaults, String) in [
                (.matchServer, "Match server"), (.combined, "Combined rows"), (.custom, "Custom")
            ] {
                visibility.useRowDefaults(preset)
                #if os(iOS)
                let windowSize: CGSize? = CGSize(width: 320, height: 900)
                #else
                let windowSize: CGSize? = nil
                #endif
                try await withWindow(size: windowSize) {
                    HomeRowPresetPicker(visibility: visibility)
                        .padding(24)
                        .environment(\.dynamicTypeSize, size)
                } inspect: { window in
                    let lines = try await self.capture(window, name: "Home preset \(title) text size \(size)")
                    let text = lines.map(\.0).joined(separator: " ")
                    // Wrapping hyphenates words; OCR can read the chevron as a stray single-letter word.
                    let readable = text.replacingOccurrences(of: "- ", with: "")
                        .filter { $0.isLetter || $0.isWhitespace }
                        .split(whereSeparator: \.isWhitespace).filter { $0.count > 1 }
                        .joined(separator: " ").lowercased()
                    XCTAssertTrue(text.contains("Preset"), text)
                    XCTAssertTrue(readable.contains(title.lowercased()), text)
                    XCTAssertEqual(visibility.visibility.rowCustomization?.defaults, preset)
                }
            }
        }
    }

    func testSourceFailuresAppearOnInventoryPagesButNotRowAppearance() async throws {
        let suite = "HomeRootFailures.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.applyRows(
            .init(enabled: [.global(.continueWatching)],
                  disabled: HomeRowChoice.shared.map(\.id).filter { $0 != .global(.continueWatching) }),
            choices: HomeRowChoice.shared
        )
        let provider = HomeSettingsLibraryProvider(name: "Basement", homeError: .serverUnreachable)
        let accounts = [ResolvedAccount(account: Account(from: provider.session), provider: provider)]
        let inventory = HomeSectionCatalogModel()
        let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.continueWatching) })
        await inventory.load(libraries: [], accounts: accounts, visibility: visibility)
        XCTAssertEqual(inventory.serverFailures.count, 1)
        for page in 0..<3 {
            try await withWindow {
                NavigationStack {
                    if page == 0 {
                        HomeSectionsSettingsView(libraries: [], accounts: accounts, visibility: visibility, inventory: inventory)
                    } else if page == 1 {
                        HomeSectionSettingsView(
                            choice: choice, inventory: inventory, visibility: visibility, libraries: [], accounts: accounts
                        )
                    } else {
                        HomeAddSectionView(inventory: inventory, visibility: visibility, libraries: [], accounts: accounts)
                    }
                }
            } inspect: { window in
                _ = try await self.capture(window, name: "Home source error page \(page)")
                try self.scrollToBottom(window)
                let lines = try await self.capture(window, name: "Home source error placement \(page)")
                let text = lines.map(\.0).joined(separator: " ")
                XCTAssertEqual(text.contains("Basement is offline."), page != 1, text)
                XCTAssertEqual(lines.filter { $0.0.contains("Retry") }.count, page != 1 ? 1 : 0, text)
            }
        }
    }

    func testSourceRowsRenderTheSharedProviderAndTransportMarks() async throws {
        let sources: [(ProviderKind, MediaShareTransportKind?)] =
            [ProviderKind.jellyfin, .plex, .emby, .silo, .iptv].map { ($0, nil) }
            + MediaShareTransportKind.allCases.map { (.mediaShare, $0) }
            + [(.plex, nil)]
        let choices = sources.enumerated().map { index, source in
            if index == sources.count - 1 {
                return HomeRowChoice(serverRow: .init(
                    accountID: "server", serverName: "Native server", providerKind: .plex,
                    section: .init(id: "native", kind: .recommendations)
                ))
            }
            let library = AggregatedLibrary(
                accountID: "account", accountName: "Viewer", serverName: "Server",
                providerKind: source.0, transportKind: source.1,
                library: .init(id: "library-\(index)", title: "Movies", kind: .movie)
            )
            return HomeRowChoice(
                id: .library(library.key, kind: .recentlyAdded), title: "Recently Added",
                library: library, isProviderDefault: true
            )
        }
        var screenshots: [CGImage] = []
        for reference in [false, true] {
            try await withWindow(size: CGSize(width: 600, height: 1040)) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(choices.indices, id: \.self) { index in
                        Group {
                            if reference {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        choices[index].homeEditorTitle.font(.body.weight(.medium))
                                        HStack(spacing: 6) {
                                            ProviderBrandMark(
                                                provider: sources[index].0, size: 20, showsBackground: false,
                                                mediaShareTransport: sources[index].1
                                            )
                                            choices[index].homeEditorSource.font(.footnote).settingsRowSecondary()
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.forward").font(.footnote).settingsRowSecondary()
                                }
                                .multilineTextAlignment(.leading)
                                .frame(minHeight: 44)
                            } else {
                                HomeSectionChoiceLabel(choice: choices[index])
                            }
                        }
                        .frame(width: 380, height: 72)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
            } inspect: { window in
                let image = try await self.snapshot(window, name: reference ? "Shared mark references" : "Home source marks")
                screenshots.append(try XCTUnwrap(image.cgImage))
            }
        }
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return bytes
        }
        for index in choices.indices {
            let rect = CGRect(x: 24, y: 24 + index * 80, width: 24, height: 72)
            let actual = try XCTUnwrap(screenshots[0].cropping(to: rect))
            let reference = try XCTUnwrap(screenshots[1].cropping(to: rect))
            let actualPixels = try pixels(actual)
            let referencePixels = try pixels(reference)
            XCTAssertTrue(stride(from: 0, to: referencePixels.count, by: 4).contains {
                let channels = referencePixels[$0..<$0 + 3]
                return (channels.max() ?? 0) - (channels.min() ?? 0) > 30
            }, "The shared reference must contain visible artwork.")
            XCTAssertTrue(actualPixels == referencePixels,
                          "Source \(sources[index]) must render the shared mark below the title beside the source.")
        }
    }

    func testReorderProviderMarkCanMoveBesideTheSubtitleWithoutChangingDefaultPlacement() async throws {
        for secondary in [false, true] {
            try await withWindow(size: CGSize(width: 900, height: 300)) {
                LiftableReorderList(
                    sections: .init(enabled: ["row"], disabled: []),
                    disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden rows",
                    isLifting: .constant(false), allowsHiding: false,
                    row: { _ in
                        .init(
                            title: Text("Recently Added"), symbolName: "rectangle.grid.1x2",
                            providerKind: .jellyfin, subtitle: Text("Movies"),
                            providerMarkInSubtitle: secondary
                        )
                    },
                    onChange: { _ in }
                )
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } inspect: { window in
                let image = try await self.snapshot(window, name: "Reorder secondary provider \(secondary)")
                let cgImage = try XCTUnwrap(image.cgImage)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
                func textFrame(_ text: String) throws -> CGRect {
                    let result = try XCTUnwrap(request.results?.first {
                        $0.topCandidates(1).first?.string.contains(text) == true
                    })
                    let candidate = try XCTUnwrap(result.topCandidates(1).first)
                    let range = try XCTUnwrap(candidate.string.range(of: text))
                    let rect = try XCTUnwrap(candidate.boundingBox(for: range)).boundingBox
                    return CGRect(
                        x: rect.minX * image.size.width, y: (1 - rect.maxY) * image.size.height,
                        width: rect.width * image.size.width, height: rect.height * image.size.height
                    )
                }
                let title = try textFrame("Recently Added")
                let source = try textFrame("Movies")
                let mark = try self.coloredArtworkBounds(in: cgImage)
                if secondary {
                    XCTAssertGreaterThan(mark.minY, title.maxY)
                    XCTAssertEqual(mark.midY, source.midY, accuracy: 5)
                    XCTAssertLessThanOrEqual(mark.maxX, source.minX)
                    XCTAssertGreaterThan(mark.midX, title.minX)
                } else {
                    XCTAssertLessThan(mark.maxX, title.minX,
                                      "Other reorder consumers must keep their leading provider mark.")
                }
            }
        }
    }

    private func coloredArtworkBounds(in image: CGImage) throws -> CGRect {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bounds = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let channels = bytes[offset..<(offset + 3)]
                if bytes[offset + 3] > 150,
                   (channels.max() ?? 0) - (channels.min() ?? 0) > 40 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        XCTAssertFalse(bounds.isNull, "The provider mark must contain visible colored artwork.")
        return bounds
    }

    #if os(tvOS)
    func testAllHiddenNoticeStillProvidesANativeFocusTarget() async throws {
        try await withWindow {
            HomeContentNoticeView(notice: .noHomeRows, onReload: {})
        } inspect: { window in
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let host = try XCTUnwrap(window.rootViewController)
            let deadline = ContinuousClock.now + .seconds(3)
            while system.focusedItem == nil, ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(system.focusedItem)
            let text = try await self.capture(window, name: "All Home rows hidden")
            XCTAssertTrue(text.contains { $0.0.contains("Reload") })
        }
    }
    #endif

    private func textInkBounds(
        _ observation: VNRecognizedTextObservation, bitmap: CGImage, pixels: [UInt8]
    ) throws -> CGRect {
        // Vision locates words; its approximate boxes are not glyph geometry.
        let box = observation.boundingBox
        let search = CGRect(
            x: box.minX * CGFloat(bitmap.width), y: (1 - box.maxY) * CGFloat(bitmap.height),
            width: box.width * CGFloat(bitmap.width), height: box.height * CGFloat(bitmap.height)
        ).insetBy(dx: -12, dy: -12).intersection(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        var ink = CGRect.null
        for y in Int(search.minY)..<Int(search.maxY) {
            for x in Int(search.minX)..<Int(search.maxX) {
                let offset = (y * bitmap.width + x) * 4
                if pixels[offset] > 80, pixels[offset + 1] > 80, pixels[offset + 2] > 80 {
                    ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        XCTAssertFalse(ink.isNull)
        return ink
    }

    private func withWindow<Content: View>(
        size: CGSize? = nil,
        colorScheme: ColorScheme = .dark,
        @ViewBuilder content: () -> Content,
        inspect: (UIWindow) async throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = size.map { CGRect(origin: .zero, size: $0) } ?? scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        window.rootViewController = HomeRowsFocusHost(rootView: AnyView(
            content()
                .environment(HeroSettingsModel(store: InMemoryHeroSettingsStore()))
                .environment(HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore()))
                .environment(CardStyleSettingsModel())
                .environment(\.themePalette, colorScheme == .dark ? ThemePalette.dark : ThemePalette.light)
                .environment(\.colorScheme, colorScheme)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(.black)
        ))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await inspect(window)
    }

    private func scrollToBottom(_ window: UIWindow) throws {
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(window).first { $0.contentSize.height > 0 })
        let bottom = max(
            -scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
    }

    private func snapshot(_ window: UIWindow, name: String, scale: CGFloat = 1) async throws -> UIImage {
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func capture(_ window: UIWindow, name: String, scale: CGFloat = 1) async throws -> [(String, CGRect)] {
        let image = try await snapshot(window, name: name, scale: scale)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.001
        let original = try XCTUnwrap(image.cgImage)
        var images = [original]
        if scale > 1 {
            let inverted = CIImage(cgImage: original).applyingFilter("CIColorInvert")
            images.append(try XCTUnwrap(CIContext().createCGImage(inverted, from: inverted.extent)))
        }
        return try images.flatMap { image in
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { result in
                result.topCandidates(1).first.map { ($0.string, result.boundingBox) }
            }
        }
    }

    private func y(_ name: String, in lines: [(String, CGRect)]) throws -> CGFloat {
        try XCTUnwrap(lines.first { $0.0.contains(name) }, lines.map(\.0).joined(separator: " | ")).1.midY
    }
}

#if os(iOS)
@MainActor @Observable
private final class HomeCatalogNavigationFixture {
    var path: [String] = []
    var rootDisappeared = false
    var addAppeared = false
}

@MainActor
private struct HomeCatalogNavigationHost: View {
    @Bindable var navigation: HomeCatalogNavigationFixture
    let inventory: HomeSectionCatalogModel
    let visibility: HomeLibraryVisibilityModel
    let accounts: [ResolvedAccount]

    var body: some View {
        NavigationStack(path: $navigation.path) {
            HomeSectionsSettingsView(libraries: [], accounts: accounts, visibility: visibility, inventory: inventory)
                .onDisappear { navigation.rootDisappeared = true }
                .navigationDestination(for: String.self) { _ in
                    HomeAddSectionView(inventory: inventory, visibility: visibility, libraries: [], accounts: accounts)
                        .onAppear { navigation.addAppeared = true }
                        .onDisappear { navigation.addAppeared = false }
                }
        }
    }
}

@MainActor @Observable
private final class HomeSettingsAccountsFixture {
    var accounts: [ResolvedAccount]
    init(accounts: [ResolvedAccount]) { self.accounts = accounts }
}

@MainActor
private struct HomeSettingsViewerHost: View {
    let source: HomeSettingsAccountsFixture
    let visibility: HomeLibraryVisibilityModel
    private let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
    private let heroBackground = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
    private let cards = CardStyleSettingsModel()

    var body: some View {
        NavigationStack {
            PlozziOSHomeSettingsView(
                hero: hero, heroBackground: heroBackground,
                cards: cards,
                visibility: visibility, accounts: source.accounts
            )
        }
    }
}
#endif

private actor HomeSettingsLibraryProvider: MediaProvider, CapabilityReporting {
    let capabilities: ProviderCapability
    let session: UserSession
    let isOffline: Bool
    let kind: ProviderKind
    private(set) var libraryRequests = 0
    private var homeError: AppError?
    private let libraryTitle: String
    private var holdsLibraries: Bool
    private var libraryContinuation: CheckedContinuation<Void, Never>?
    private let homeLayout: ServerHomeLayout?
    private var holdsHome: Bool
    private var homeContinuations: [CheckedContinuation<Void, Never>] = []
    private let onFirstHomeRequest: (@Sendable () -> Void)?
    private var requestedHome = false
    private(set) var homeRequests = 0
    private let collectionItems: [MediaItem]
    private let onCollectionRequest: (@Sendable () -> Void)?

    init(
        name: String, isOffline: Bool = false, homeError: AppError? = nil,
        libraryTitle: String = "Movies", kind: ProviderKind = .jellyfin,
        holdsLibraries: Bool = false, homeLayout: ServerHomeLayout? = nil,
        holdsHome: Bool = false, onFirstHomeRequest: (@Sendable () -> Void)? = nil,
        collectionItems: [MediaItem] = [], onCollectionRequest: (@Sendable () -> Void)? = nil,
        capabilities: ProviderCapability = .videoOnly
    ) {
        self.isOffline = isOffline
        self.capabilities = capabilities
        self.homeError = homeError
        self.libraryTitle = libraryTitle
        self.kind = kind
        self.holdsLibraries = holdsLibraries
        self.homeLayout = homeLayout
        self.holdsHome = holdsHome
        self.onFirstHomeRequest = onFirstHomeRequest
        self.collectionItems = collectionItems
        self.onCollectionRequest = onCollectionRequest
        session = UserSession(
            server: MediaServer(
                id: name, name: name,
                baseURL: URL(string: "https://home-settings.example.test")!, provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }

    func setHomeError(_ error: AppError?) { homeError = error }
    func resumeLibraries() {
        holdsLibraries = false
        libraryContinuation?.resume()
        libraryContinuation = nil
    }
    func serverHomeLayout() async throws -> ServerHomeLayout? {
        homeRequests += 1
        if !requestedHome {
            requestedHome = true
            onFirstHomeRequest?()
        }
        if holdsHome { await withCheckedContinuation { homeContinuations.append($0) } }
        if let homeError { throw homeError }
        return homeLayout
    }

    func resumeHome() {
        holdsHome = false
        let pending = homeContinuations
        homeContinuations = []
        for continuation in pending { continuation.resume() }
    }

    func libraries() async throws -> [MediaLibrary] {
        libraryRequests += 1
        if holdsLibraries { await withCheckedContinuation { libraryContinuation = $0 } }
        if isOffline { throw AppError.serverUnreachable }
        return [MediaLibrary(id: "movies", title: libraryTitle, kind: .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }

    func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        onCollectionRequest?()
        return .init(
            items: Array(collectionItems.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: collectionItems.count
        )
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
