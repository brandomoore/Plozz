import CoreModels
import CoreUI
import Observation
@testable import AppShell
@testable import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class ArtworkSettingsHostedTests: XCTestCase {
    func testTVLabelPreviewHeadingsAreReadableAtTheDisplayedSize() async throws {
        for page in [CardCaptionSettingsPage.home, .detail] {
            let preview = CardLabelScopePreview.snapshot(
                page: page, editing: page.firstControl, settings: .default,
                isShowcase: false, seriesArtwork: true, layout: .landscape
            )
            try await withScreen(content:
                VStack {
                    CardLabelScopePreview(preview: preview, style: .borderless)
                        .frame(width: CardLabelScopePreview.illustrationWidth)
                    Button("Preview action") {}
                }
            ) { window in
                let text = try await self.capture(window, name: "readable-tv-labels-\(page.rawValue)", includeMaster: true)
                let labels = try self.collectionLabelFrames(in: window)
                for row in preview.rows {
                    let title = String(localized: row.title)
                    XCTAssertTrue(text.contains(title), text)
                    let label = try XCTUnwrap(labels.first { $0.text == title })
                    let ink = try self.textInkBounds(in: self.renderWindow(window), frame: label.frame)
                    XCTAssertGreaterThanOrEqual(ink.height, 16, "Row names must not become miniature diagram text.")
                }
                XCTAssertEqual(self.focusItems(in: window).count, 1, "The diagram remains non-interactive.")
            }
        }
    }

    func testLibraryLabelPreviewDoesNotRepeatVisibleStatusText() async throws {
        for showsLabels in [false, true] {
            let preview = CardLabelScopePreview.Snapshot(
                page: .recommended,
                rows: [
                    .init(view: .continueWatching, showsLabels: showsLabels, highlighted: true),
                    .init(view: .recommended, showsLabels: showsLabels, highlighted: true)
                ],
                layout: .landscape
            )
            try await withScreen(content:
                VStack(spacing: 32) {
                    CardLabelScopePreview(preview: preview, style: .framed)
                        .frame(width: 280)
                    Button("Preview action") {}
                }
            ) { window in
                let text = try await self.capture(
                    window, name: "library-label-visual-only-\(showsLabels)", includeMaster: true
                )
                XCTAssertTrue(text.contains("Recommended"), text)
                let words = text.split(whereSeparator: \.isWhitespace)
                XCTAssertFalse(words.contains("On"), "The diagram must not have a duplicate status table.")
                XCTAssertFalse(words.contains("Off"), "The diagram must not have a duplicate status table.")
            }
        }
    }

    func testLibraryLabelEditorFocusPreviewsDoNotChangeSettings() async throws {
        let suite = "LibraryLabelPreviewHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        cards.captions.setOverride(.show, for: .home)
        cards.captions.setOverride(.hide, for: .recommended)
        let initial = cards.captions
        try await withScreen(content:
            CardCaptionCustomizationView(cards: cards, scope: .libraries, visibility: visibility)
                .frame(width: 1100, height: 1000)
        ) { window in
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
            let rows = self.focusItems(in: window).sorted {
                ((try? self.nativeFrame($0, in: window).minY) ?? 0)
                    < ((try? self.nativeFrame($1, in: window).minY) ?? 0)
            }
            // Back and Page precede Recommended's two label controls.
            XCTAssertEqual(rows.count, 4)
            for (index, view) in CardCaptionSettingsPage.recommended.controls.enumerated() {
                let row = try XCTUnwrap(rows.dropFirst(2).dropFirst(index).first)
                host.artworkFocusTarget = row
                system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
                system.updateFocusIfNeeded()
                host.artworkFocusTarget = nil
                let text = try await self.capture(window, name: "library-label-preview-\(view.rawValue)", includeMaster: true)
                XCTAssertTrue(system.focusedItem === row)
                XCTAssertEqual(cards.captions, initial, "Focus previews must never commit a label choice.")
                XCTAssertTrue(text.contains(String(localized: view.displayName)), text)
                if view == .continueWatching {
                    XCTAssertTrue(text.contains("Home"), text)
                    XCTAssertTrue(text.contains("Recommended"), text)
                    XCTAssertTrue(text.contains("Use default"), text)
                    XCTAssertTrue(text.contains("Uses this page's default."), text)
                }
            }
        }
    }

    func testContentRatingExamplesRemainVisibleAcrossNativeFocusAndAppearance() async throws {
        let suite = "ContentRatingFocusHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ContentRatingSettingsModel(store: ContentRatingSettingsStore(defaults: defaults))
        for colorScheme in [ColorScheme.dark, .light] {
            try await withScreen(
                content: VStack(spacing: 30) {
                    SettingsControlGroup { ContentRatingToggle(model: model) }
                    Button("Another setting") {}
                        .buttonStyle(SettingsFormButtonStyle())
                }
                .frame(width: SettingsFormMetrics.pageWidth)
                .environment(\.plozzShowsContentRatings, false),
                colorScheme: colorScheme
            ) { window in
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
                let items = self.focusItems(in: window).sorted {
                    ((try? self.nativeFrame($0, in: window).minY) ?? 0)
                        < ((try? self.nativeFrame($1, in: window).minY) ?? 0)
                }
                XCTAssertEqual(items.count, 2, "The illustrative badges must never become focus targets.")
                for showsRatings in [true, false] {
                    model.showsRatings = showsRatings
                    for index in 0..<2 {
                        let target = try XCTUnwrap(items.indices.contains(index) ? items[index] : nil)
                        host.artworkFocusTarget = target
                        system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
                        system.updateFocusIfNeeded()
                        host.artworkFocusTarget = nil
                        let text = try await self.capture(
                            window, name: "rating-examples-\(colorScheme)-\(showsRatings)-focus-\(index)",
                            includeMaster: true
                        )
                        XCTAssertTrue(system.focusedItem === target)
                        XCTAssertTrue(text.contains("Show content ratings"), text)
                        try self.assertRatingExampleInk(in: window)
                    }
                }
            }
        }
    }

    private func assertRatingExampleInk(in window: UIWindow) throws {
        let title = try XCTUnwrap(collectionLabelFrames(
            in: window, matchingText: "Show content ratings"
        ).first).frame
        let frame = CGRect(x: title.maxX + 5, y: title.midY - 15, width: 140, height: 30).integral
        let crop = try XCTUnwrap(renderWindow(window).cgImage?.cropping(to: frame))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let background = Int(try XCTUnwrap(pixels.first))
        func hasContrast(x: Int, y: Int) -> Bool {
            abs(Int(pixels[y * crop.width + x]) - background) > 80
        }
        // Outlines have taller vertical strokes than the small glyphs. Single-letter
        // OCR confuses the outlined R with B, so measure each badge's actual ink.
        let columns = (0..<crop.width).filter { x in
            (0..<crop.height).filter { hasContrast(x: x, y: $0) }.count >= 14
        }
        var edges: [ClosedRange<Int>] = []
        for column in columns {
            if let last = edges.last, last.upperBound + 1 == column {
                edges[edges.count - 1] = last.lowerBound...column
            } else {
                edges.append(column...column)
            }
        }
        XCTAssertEqual(edges.count, 4, "Both example badges must have two contrasting vertical outline edges.")
        guard edges.count == 4 else { return }
        for index in [0, 2] {
            let left = edges[index].upperBound + 3
            let right = edges[index + 1].lowerBound - 2
            XCTAssertGreaterThan(right, left)
            guard right > left else { return }
            let ink = (left..<right).reduce(0) { count, x in
                count + ((crop.height / 2 - 6)..<(crop.height / 2 + 6)).filter {
                    hasContrast(x: x, y: $0)
                }.count
            }
            XCTAssertGreaterThan(ink, 8, "Each outlined example must contain a visible rating glyph.")
        }
    }

    func testContextualCardLabelControlsShowOnlyTheirScreenViews() async throws {
        let suite = "ContextualCardLabelsHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        for scope in CardCaptionSettingsScope.allCases {
            try await withScreen(content:
                CardCaptionCustomizationView(cards: cards, scope: scope)
                    .frame(width: 1100, height: 1000)
            ) { window in
                var text = try await self.capture(window, name: "card-labels-\(scope)", includeMaster: true)
                let page = try XCTUnwrap(scope.pages.first)
                XCTAssertEqual(self.focusItems(in: window).count,
                               page.controls.count + 1 + (scope.pages.count > 1 ? 1 : 0))
                XCTAssertTrue(text.contains(scope == .home ? "Card labels" : "Customize labels"), text)
                XCTAssertTrue(text.contains(String(localized: page.title)), text)
                XCTAssertEqual(text.contains("Overrides"), page.hasOverrides, text)
                if page.hasOverrides {
                    XCTAssertTrue(text.contains("Default"), text)
                    let scroll = try self.verticalScroll(in: window)
                    scroll.setContentOffset(CGPoint(
                        x: scroll.contentOffset.x,
                        y: max(-scroll.adjustedContentInset.top,
                               scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    ), animated: false)
                    text += " " + (try await self.capture(
                        window, name: "card-labels-\(scope)-overrides", includeMaster: true
                    ))
                    XCTAssertTrue(text.contains("Use default"), text)
                    XCTAssertTrue(text.contains(String(localized: try XCTUnwrap(page.sharedRowNote))), text)
                }
                for view in page.controls where view.isRowOverride || page == .detail {
                    XCTAssertTrue(text.contains(String(localized: view.cardLabelTitle)), text)
                }
                XCTAssertFalse(text.contains("Filmography"), text)
                XCTAssertFalse(text.contains("Search"), text)
            }
        }
    }

    func testSharedPageBackButtonsShowOnlyChevronAndKeepNativeFocus() async throws {
        for usesGlass in [false, true] {
            try await withScreen(content:
                SettingsPageHeader("Shared page")
                    .environment(\.settingsPageBackButton, AnyView(SettingsBackButton(usesGlass: usesGlass) {}))
                    .frame(width: SettingsFormMetrics.pageWidth)
            ) { window in
                let text = try await self.capture(window, name: "shared-back-chevron-\(usesGlass)", includeMaster: true)
                XCTAssertTrue(text.contains("Shared page"), text)
                XCTAssertFalse(text.contains("Back"), text)
                let back = try self.backButton(beside: "Shared page", in: window)
                let frame = try self.nativeFrame(back, in: window)
                XCTAssertLessThan(frame.width, frame.height * 2, "The icon-only back button must remain compact.")
                XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === back)
            }
        }
    }

    func testContinueWatchingPreviewsUseSharedSelectionStyleAndReadableDetails() async throws {
        for showsCaptions in [false, true] {
            var captions = CardCaptionSettings.default
            captions.setOverride(showsCaptions ? .show : .hide, for: .continueWatching)
            try await withScreen(content:
                HomeEditorPage(title: Text("Continue Watching"), showsHeader: true) {
                    Text("All libraries").font(.subheadline)
                    Toggle("Include Next Up", isOn: .constant(true))
                    ContinueWatchingArtworkPicker(
                        style: .constant(.portraitPosters), playbackDetails: .detailed, captions: captions
                    )
                }
                .frame(width: SettingsFormMetrics.pageWidth, height: 1000)
                .environment(\.settingsPageBackButton, AnyView(SettingsBackButton {}))
            ) { window in
                let image = self.renderWindow(window)
                let attachment = XCTAttachment(image: image)
                attachment.name = "tv-continue-watching-details-labels-\(showsCaptions ? "on" : "off")"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                let bitmap = try XCTUnwrap(image.cgImage)
                let focusFrames: [CGRect] = try self.focusItems(in: window).map {
                    try self.nativeFrame($0, in: window)
                }
                let choices = focusFrames.filter {
                    $0.width > 200 && $0.width < SettingsFormMetrics.pageWidth / 2 && $0.height > 200
                }.sorted { $0.minX < $1.minX }
                XCTAssertEqual(choices.count, 3)
                let surfaces: [[Int]] = try choices.map { frame in
                    let patch = try XCTUnwrap(bitmap.cropping(to: CGRect(
                        x: frame.midX - 2, y: frame.minY + 6, width: 4, height: 4
                    ).integral))
                    var pixels = [UInt8](repeating: 0, count: patch.width * patch.height * 4)
                    try pixels.withUnsafeMutableBytes { bytes in
                        let context = try XCTUnwrap(CGContext(
                            data: bytes.baseAddress, width: patch.width, height: patch.height,
                            bitsPerComponent: 8, bytesPerRow: patch.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        ))
                        context.draw(patch, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
                    }
                    return (0..<3).map { channel in
                        stride(from: channel, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
                            / (patch.width * patch.height)
                    }
                }
                let selectedSurface = try XCTUnwrap(surfaces.last)
                for surface in surfaces.dropLast() {
                    XCTAssertTrue(zip(selectedSurface, surface).contains { $0 - $1 > 20 },
                                  "The selected choice must use the shared preview card's accent wash.")
                }
                let left = (window.bounds.width - SettingsFormMetrics.pageWidth) / 2
                let columnWidth = SettingsFormMetrics.pageWidth / 3
                var heights: [CGFloat] = []
                for column in 0..<3 {
                    let crop = try XCTUnwrap(bitmap.cropping(to: CGRect(
                        x: left + CGFloat(column) * columnWidth, y: 0,
                        width: columnWidth, height: window.bounds.height
                    )))
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    request.usesLanguageCorrection = false
                    request.minimumTextHeight = 0.005
                    try VNImageRequestHandler(cgImage: crop).perform([request])
                    let runtime = try (request.results ?? []).compactMap { observation -> CGRect? in
                        guard let text = observation.topCandidates(1).first,
                              let range = text.string.range(of: "30m") ?? text.string.range(of: "30 m")
                        else { return nil }
                        return try text.boundingBox(for: range)?.boundingBox
                    }
                    XCTAssertEqual(runtime.count, 1, "Each TV choice must retain its complete playback detail.")
                    let bounds = try XCTUnwrap(runtime.first)
                    let frame = CGRect(
                        x: left + CGFloat(column) * columnWidth + bounds.minX * CGFloat(crop.width),
                        y: (1 - bounds.maxY) * CGFloat(crop.height),
                        width: bounds.width * CGFloat(crop.width), height: bounds.height * CGFloat(crop.height)
                    )
                    let detailImage = try XCTUnwrap(bitmap.cropping(to: frame.insetBy(dx: -4, dy: -4).integral))
                    let detailAttachment = XCTAttachment(image: UIImage(cgImage: detailImage))
                    detailAttachment.name = "tv-runtime-\(showsCaptions)-\(column)"
                    detailAttachment.lifetime = .keepAlways
                    self.add(detailAttachment)
                    let height = try self.textInkBounds(in: image, frame: frame, lightForegroundThreshold: 180).height
                    heights.append(height)
                    XCTAssertGreaterThanOrEqual(height, 10, "TV preview details must retain the approved mobile-like proportions.")
                }
                for height in heights.dropFirst() {
                    XCTAssertEqual(height, try XCTUnwrap(heights.first), accuracy: 1,
                                   "All three TV previews must use matching playback detail sizes.")
                }
            }
        }
    }

    func testGroupedSettingsAlignHeadingsCompactLabelsHelpersAndSteppers() async throws {
        try await withScreen(content:
            SettingsFormGroup(title: Text("Shared heading"), description: Text("Shared footer")) {
                LabeledSettingRow("Shared preferred language", trailingAlignment: .trailing) {
                    Button("English") {}.buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Shared toggle", isOn: .constant(true))
                    Text("Shared helper").settingsHelperText()
                }
                SettingsStepper(
                    options: [10, 20, 30], selection: .constant(20),
                    label: "Shared time interval", subtitle: "Shared interval description",
                    verbatimTitle: { $0.formatted() }
                )
            }
            .frame(width: SettingsFormMetrics.pageWidth)
        ) { window in
            let labels = [
                "Shared heading", "Shared preferred language", "Shared toggle",
                "Shared helper", "Shared time interval", "Shared interval description", "Shared footer"
            ]
            let image = self.renderWindow(window)
            let expected = (window.bounds.width - SettingsFormMetrics.pageWidth) / 2 + 28
            for label in labels {
                let frame = try XCTUnwrap(self.collectionLabelFrames(in: window, matchingText: label).first).frame
                let ink = try self.textInkBounds(in: image, frame: frame)
                XCTAssertEqual(ink.minX, expected, accuracy: 3, "\(label) must share the group text keyline.")
            }
            _ = try await self.capture(window, name: "settings-native-shared-keylines", includeMaster: true)
        }
    }

    func testIllustratedCardSeparatorAlternatives() async throws {
        for divider in [false, true] {
            try await withScreen(content: VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing) {
                SettingsPageHeader("Cards")
                    .environment(\.settingsPageBackButton, AnyView(SettingsBackButton {}))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Labels").settingsSectionHeader()
                        .padding(.horizontal, SettingsFormMetrics.headingInset)
                    illustratedPreviewGroup(divider: divider) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(CardCaptionPreference.allCases) { preference in
                                PreviewCard(
                                    title: preference.displayName, isSelected: preference == .recommended,
                                    accent: ThemePalette.dark.accent, compact: true, swatchHeight: 150,
                                    titleLineLimit: nil, titleSizeGroup: CardCaptionPreference.allCases.map(\.displayName),
                                    action: {}
                                ) {
                                    CardStyleSwatch(
                                        style: .borderless, showsCaptions: preference != .hide,
                                        showsMixedCaptions: preference == .recommended
                                    )
                                }
                            }
                        }
                    } control: {
                        ViewCustomizationLink(isCustomized: false) { EmptyView() }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Watched Indicator").settingsSectionHeader()
                        .padding(.horizontal, SettingsFormMetrics.headingInset)
                    illustratedPreviewGroup(divider: divider) {
                        CompactWatchIndicatorPicker(selection: .constant(.unwatched), swatchHeight: 150)
                    } control: {
                        Toggle("Show unwatched episode count", isOn: .constant(true))
                    }
                }
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .frame(width: SettingsFormMetrics.pageWidth, height: 1000, alignment: .topLeading)) { window in
                let copy = try await self.capture(
                    window, name: "settings-native-illustrated-rows-\(divider ? "spaced-divider" : "no-divider")",
                    includeMaster: true
                )
                _ = try self.backButton(beside: "Cards", in: window)
                for label in ["App default", "Customize by view", "Watched", "Unwatched", "Show unwatched episode count"] {
                    XCTAssertTrue(copy.contains(label), copy)
                }
            }
        }
    }

    private func illustratedPreviewGroup<Illustrations: View, Control: View>(
        divider: Bool, @ViewBuilder illustrations: () -> Illustrations, @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 0) {
            illustrations()
            if divider {
                PlozzDivider().padding(.vertical, 16)
            } else {
                Color.clear.frame(height: 16)
            }
            control()
        }
        .padding(SettingsFormMetrics.groupInset)
        .settingsGroupSurface(cornerRadius: SettingsFormMetrics.groupCornerRadius)
        .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
        .environment(\.settingsFormRowsFlushLeading, false)
        .environment(\.settingsRowsHaveDividers, true)
    }

    func testLongSettingsCopyWrapsInsideTheSharedColumn() async throws {
        let title = "Playback and subtitle preferences"
        let label = "Preferred subtitle language when the original dialogue is in another language"
        let value = "Portuguese (Brazil)"
        for smallerTitle in [false, true] {
            try await withScreen(content:
                VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing) {
                    if smallerTitle {
                        HStack(spacing: SettingsFormMetrics.controlSpacing) {
                            SettingsBackButton {}
                            Text(verbatim: title).font(.system(size: 48, weight: .bold))
                        }
                    } else {
                        SettingsPageHeader(verbatim: title)
                            .environment(\.settingsPageBackButton, AnyView(SettingsBackButton {}))
                    }
                    SettingsControlGroup {
                        LabeledSettingRow("Preferred language", trailingAlignment: .trailing) {
                            Button("English") {}.buttonStyle(.bordered)
                        }
                        LabeledSettingRow(
                            LocalizedStringResource(stringLiteral: label),
                            trailingAlignment: .trailing
                        ) {
                            Button {} label: { Text(verbatim: value) }
                                .buttonStyle(.bordered)
                        }
                        ViewCustomizationRow(
                            id: "long-view-label",
                            title: "Artwork shown when browsing collections and recommended movies",
                            value: "Prefer artwork from metadata providers",
                            cycle: {}
                        )
                        Toggle("Show the number of unwatched episodes alongside the series title", isOn: .constant(true))
                    }
                    Text("Long-text stress example using the shared native controls; not proposed setting names.")
                        .settingsHelperText()
                }
                .padding(.horizontal, SettingsFormMetrics.pageInset)
                .frame(width: SettingsFormMetrics.pageWidth)
            ) { window in
                let copy = try await self.capture(
                    window, name: "settings-native-long-copy-\(smallerTitle ? "smaller-title" : "current-title")",
                    includeMaster: true
                )
                _ = try self.backButton(beside: "Playback", in: window)
                XCTAssertTrue(copy.contains(title), copy)
                XCTAssertTrue(copy.contains(label), copy)
                XCTAssertTrue(copy.contains(value), copy)
                XCTAssertTrue(copy.contains("Prefer artwork from metadata providers"), copy)
                let shortLabel = try XCTUnwrap(self.collectionLabelFrames(
                    in: window, matchingText: "Preferred language"
                ).first)
                let shortValue = try XCTUnwrap(self.collectionLabelFrames(
                    in: window, matchingText: "English"
                ).first)
                XCTAssertEqual(shortLabel.frame.midY, shortValue.frame.midY, accuracy: 3,
                               "Short labels must keep their existing horizontal layout.")
                let left = (window.bounds.width - SettingsFormMetrics.pageWidth) / 2
                let right = left + SettingsFormMetrics.pageWidth
                for item in self.focusItems(in: window) {
                    let frame = try self.nativeFrame(item, in: window)
                    XCTAssertGreaterThanOrEqual(frame.minX, left)
                    XCTAssertLessThanOrEqual(frame.maxX, right)
                }
            }
        }
    }

    func testCompactSettingsControlsShareRenderedTypeAndRowHeights() async throws {
        let state = SettingsScaleFixtureState()
        state.selection = .detailed
        try await withScreen(content: SettingsScaleFixture(state: state).frame(width: 1000)) { window in
            let labels = try self.collectionLabelFrames(
                in: window, attachmentName: "settings-shared-control-scale", matchingText: "Balanced"
            )
            let matching = labels.filter { $0.text.contains("Balanced") }.sorted { $0.frame.minY < $1.frame.minY }
            XCTAssertEqual(matching.count, 6, "\(labels)")
            let titles = Array(matching.prefix(4))
            let image = self.renderWindow(window)
            let reference = try self.textInkBounds(in: image, frame: XCTUnwrap(titles.first).frame)
            for title in titles {
                XCTAssertEqual(try self.textInkBounds(in: image, frame: title.frame).height,
                               reference.height, accuracy: 1, title.text)
            }
            let items = self.focusItems(in: window)
            let frames = try titles.map { title in
                try XCTUnwrap(items.compactMap { item -> CGRect? in
                    let frame = try? self.nativeFrame(item, in: window)
                    return frame?.contains(CGPoint(x: title.frame.midX, y: title.frame.midY)) == true ? frame : nil
                }.min { $0.width * $0.height < $1.width * $1.height })
            }
            let rowHeight = SettingsRowMetrics.minHeight(.primary) + 2 * SettingsRowMetrics.verticalPadding(.primary)
            XCTAssertEqual(frames[0].height, rowHeight, accuracy: 1)
            XCTAssertEqual(frames[1].height + 2 * SettingsRowMetrics.segmentedTrackInset, rowHeight, accuracy: 1)
            XCTAssertEqual(frames[2].height, rowHeight, accuracy: 1)
            let descriptions = Array(matching.dropFirst(4))
            XCTAssertEqual(descriptions.count, 2)
            let controlHeight = reference.height
            let descriptionHeights = try descriptions.map { try self.textInkBounds(in: image, frame: $0.frame).height }
            for height in descriptionHeights {
                XCTAssertLessThan(height, controlHeight)
                XCTAssertEqual(height, try XCTUnwrap(descriptionHeights.first), accuracy: 1)
            }
        }
    }

    func testNavigationReorderIconsUseTheCompactControlScale() async throws {
        try await withNavigationReorderScreen { window in
            let text = try await self.capture(window, name: "settings-navigation-reorder-icons", includeMaster: true)
            for title in ["Home", "Watchlist", "Live TV", "Search", "Music", "Movies", "TV Shows", "Settings"] {
                XCTAssertTrue(text.contains(title), text)
            }
            let frames = try self.focusItems(in: window).map { try self.nativeFrame($0, in: window) }
                .filter { $0.minY >= 0 && $0.maxY <= window.bounds.height }
                .sorted { $0.minY < $1.minY }
            XCTAssertGreaterThanOrEqual(frames.count, 9)
            let rowHeight = SettingsRowMetrics.minHeight(.primary) + 2 * SettingsRowMetrics.verticalPadding(.primary)
            let singleLineRows = frames.prefix(9).filter { $0.height <= rowHeight + 1 }
            let libraryRows = frames.prefix(9).filter { $0.height > rowHeight + 1 }
            XCTAssertEqual(singleLineRows.count, 7)
            XCTAssertEqual(libraryRows.count, 2, "Library rows reserve a second line for their server.")
            for frame in singleLineRows {
                XCTAssertEqual(frame.height, rowHeight, accuracy: 1)
            }
            XCTAssertEqual(try XCTUnwrap(libraryRows.first).height,
                           try XCTUnwrap(libraryRows.last).height, accuracy: 1)
            for (previous, next) in zip(frames.prefix(8), frames.dropFirst().prefix(8)) {
                XCTAssertEqual(next.minY - previous.maxY, SettingsRowMetrics.formRowSpacing, accuracy: 1)
            }
        }
    }

    func testSettingsChoiceFamiliesUseTheSameRenderedTitleFont() async throws {
        try await withScreen(content: VStack(alignment: .leading, spacing: 28) {
            Button("Balanced") {}.buttonStyle(SettingsFormButtonStyle())
            SettingsCheckableRow(title: Text("Balanced"), isChecked: false, action: {})
            SettingsOptionPicker(
                options: SettingsScaleFixtureState.Option.allCases, selection: .constant(.detailed),
                title: { $0.title }
            )
            SettingsStepper(
                options: [SettingsScaleFixtureState.Option.balanced], selection: .constant(.balanced),
                title: { $0.title }
            )
            Button {} label: {
                SettingsRowLabel(icon: nil, title: "Balanced")
            }
            .buttonStyle(SettingsFocusButtonStyle())
        }.padding(40).frame(width: 1000)) { window in
            let labels = try self.collectionLabelFrames(
                in: window, attachmentName: "settings-shared-choice-scale", matchingText: "Balanced"
            )
            let titles = labels.filter { $0.text.contains("Balanced") }.sorted { $0.frame.minY < $1.frame.minY }
            XCTAssertEqual(titles.count, 5, "\(labels)")
            let image = self.renderWindow(window)
            let reference = try self.textInkBounds(in: image, frame: XCTUnwrap(titles.first).frame)
            for title in titles {
                XCTAssertEqual(try self.textInkBounds(in: image, frame: title.frame).height,
                               reference.height, accuracy: 1, title.text)
            }
        }
    }

    func testNavigationReorderKeepsColumnsAlignedAcrossTwoDigitRanks() async throws {
        let names = [
            "Movies", "TV Shows", "Documentaries", "Concerts", "Family", "Animation",
            "Comedy", "Drama", "Action", "Sci-Fi", "Horror", "Classics", "Short Films",
            "Stand-Up", "Sports", "Travel", "Music Videos"
        ]
        try await withNavigationReorderScreen(libraryNames: names) { window in
            let first = try XCTUnwrap(self.collectionLabelFrames(in: window, matchingText: "Home").first)
            let firstInk = try self.textInkBounds(in: self.renderWindow(window), frame: first.frame)
            let scroll = try self.verticalScroll(in: window)
            let rowStride = SettingsRowMetrics.minHeight(.primary)
                + 2 * SettingsRowMetrics.verticalPadding(.primary) + SettingsRowMetrics.formRowSpacing
            for (rank, preceding, following) in [(9, "Documentaries", "Concerts"), (19, "Short Films", "Stand-Up")] {
                scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(rank - 3) * rowStride), animated: false)
                let text = try await self.capture(
                    window, name: "settings-navigation-ranks-\(rank)-\(rank + 1)", includeMaster: true
                )
                XCTAssertTrue(text.contains(preceding), text)
                XCTAssertTrue(text.contains(following), text)
                let image = self.renderWindow(window)
                for title in [preceding, following] {
                    let label = try XCTUnwrap(self.collectionLabelFrames(in: window, matchingText: title).first)
                    let ink = try self.textInkBounds(in: image, frame: label.frame)
                    XCTAssertEqual(ink.minX, firstInk.minX, accuracy: 2,
                                   "Ranks 1–24 must reserve the same number and icon columns: \(title).")
                }
            }
        }
    }

    func testSegmentFocusOnlyPreviewsAndOnlySelectionUsesCheckmarkSpace() async throws {
        let state = SettingsScaleFixtureState()
        try await withScreen(content: SettingsScaleFixture(state: state).frame(width: 1000)) { window in
            let compact = try XCTUnwrap(self.collectionLabelFrames(in: window, matchingText: "Compact").first)
            let target = try XCTUnwrap(self.focusItems(in: window).first {
                (try? self.nativeFrame($0, in: window).contains(CGPoint(x: compact.frame.midX, y: compact.frame.midY))) == true
            })
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
            host.artworkFocusTarget = target
            system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
            system.updateFocusIfNeeded()
            host.artworkFocusTarget = nil
            _ = try await self.capture(window, name: "settings-segment-focus", includeMaster: true)
            XCTAssertTrue(system.focusedItem === target)
            XCTAssertEqual(state.focused, .compact)
            XCTAssertEqual(state.selection, .balanced, "Moving focus must not commit a preference.")
            let focusedFrame = try self.nativeFrame(target, in: window)
            let before = try self.focusItems(in: window).map { try self.nativeFrame($0, in: window) }
                .filter { abs($0.midY - focusedFrame.midY) < 1 }.sorted { $0.minX < $1.minX }
            XCTAssertEqual(before.count, 3)
            state.selection = .compact
            _ = try await self.capture(window, name: "settings-segment-selection", includeMaster: true)
            let after = try self.focusItems(in: window).map { try self.nativeFrame($0, in: window) }
                .filter { abs($0.midY - focusedFrame.midY) < 1 }.sorted { $0.minX < $1.minX }
            XCTAssertEqual(after.count, before.count)
            guard before.count == 3, after.count == 3 else { return }
            for (old, new) in zip(before, after) {
                XCTAssertEqual(old.height, new.height, accuracy: 1)
            }
            XCTAssertGreaterThan(before[0].width - after[0].width, 8, "Unselected options must not reserve a checkmark slot.")
            XCTAssertGreaterThan(after[1].width - before[1].width, 8, "Only the selected option expands for the checkmark.")
            XCTAssertEqual(before[0].width - after[0].width, after[1].width - before[1].width, accuracy: 1)
            XCTAssertEqual(before[2].width, after[2].width, accuracy: 1)
            XCTAssertEqual(before[0].minX, after[0].minX, accuracy: 1)
            XCTAssertEqual(before[2].maxX, after[2].maxX, accuracy: 1)
            XCTAssertTrue(system.focusedItem === target)
        }
    }

    func testAppearancePreviewCardsAndDescriptionsUseTheSharedScale() async throws {
        let previews: [(String, AnyView)] = [
            ("Music Player", AnyView(MusicPlayerStyleDetail(
                appearance: .constant(.matchTheme), showTrackDetails: .constant(true)
            ))),
            ("Cards", AnyView(CompactCardStylePicker(selection: .constant(.borderless), swatchHeight: 124)))
        ]
        for (title, preview) in previews {
            try await withScreen(content: VStack(alignment: .leading, spacing: 32) {
                Text(verbatim: title).settingsFeatureTitle()
                Text("How your settings look across the app.").settingsHelperText()
                preview
                SettingsDetailGroup(title: "Liquid Glass") {
                    SettingsSegmentedPicker(
                        options: TransparencyPreference.allCases, selection: .constant(.system),
                        title: { $0.displayName }
                    )
                    Text(TransparencyPreference.system.detail).settingsHelperText()
                }
            }
            .padding(40)
            .frame(width: 1100)) { window in
                let text = try await self.capture(window, name: "settings-scale-\(title)", includeMaster: true)
                XCTAssertTrue(text.contains(title), text)
                XCTAssertTrue(text.contains("LIQUID GLASS"), text)
                XCTAssertTrue(text.contains("tvOS Default"), text)
            }
        }
    }

    func testHeroSourceSummaryFollowsLiveLocaleChanges() async throws {
        let namespace = "HeroLocaleHosted.\(UUID())"
        let models = ProfileSettingsModel(namespace: namespace)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        models.heroSettingsModel.settings.sources = [.continueWatching]
        let locale = HeroHostedLocale()
        try await withScreen(content: HeroLocaleHostedControls(locale: locale)
            .frame(width: 1100)
            .environment(models.heroSettingsModel)
            .environment(models.heroBackgroundModel)
            .buttonStyle(SettingsFocusButtonStyle())
            .toggleStyle(SettingsSwitchToggleStyle())) { window in
            for (identifier, expected, previous) in [
                ("en_US", "Continue Watching", "Seguir viendo"),
                ("es", "Seguir viendo", "Continue Watching"),
                ("en_US", "Continue Watching", "Seguir viendo"),
            ] {
                locale.value = Locale(identifier: identifier)
                let shown = try await self.capture(window, name: "hero-summary-\(identifier)", includeMaster: true)
                XCTAssertTrue(shown.contains(expected), shown)
                XCTAssertFalse(shown.contains(previous), shown)
            }
        }
    }

    func testHeroKeepsEverydayControlsInlineAndReturnsNativeFocusToNamedPages() async throws {
        let namespace = "HeroHierarchyHosted.\(UUID())"
        let models = ProfileSettingsModel(namespace: namespace)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        models.heroSettingsModel.settings.autoAdvance = false
        models.heroSettingsModel.settings.showsRatings = false
        models.heroBackgroundModel.settings.homeTrailerEnabled = false
        let navigation = SettingsDetailNavigation()
        try await withScreen(content: SettingsDetailPages(navigation: navigation) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsRowMetrics.formSectionSpacing) {
                    HeroSettingsControls(libraries: [], accounts: [])
                }
                .padding(48)
            }
            .buttonStyle(SettingsFocusButtonStyle())
            .toggleStyle(SettingsSwitchToggleStyle())
        } detail: {
            HeroSettingsDestination(libraries: [], accounts: [])
        }
        .frame(width: 1100)
        .environment(models.heroSettingsModel)
        .environment(models.heroBackgroundModel)) { window in
            let root = try await self.capture(window, name: "hero-inline-titles", includeMaster: true)
            for title in ["Hero content sources", "Items to show", "Advance automatically"] {
                XCTAssertTrue(root.contains(title), root)
            }
            for title in ["Hide watched content", "Titles shown in hero", "Automatic changes", "Appearance", "Rotation", "Rotate automatically"] {
                XCTAssertFalse(root.contains(title), root)
            }
            XCTAssertFalse(root.contains("TMDB"), root)
            XCTAssertFalse(root.contains("Show provider labels"), root)
            XCTAssertFalse(root.contains("Seconds per item"), root)
            let scroll = try self.verticalScroll(in: window)
            scroll.setContentOffset(CGPoint(
                x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            ), animated: false)
            let bottom = try await self.capture(window, name: "hero-inline-ratings-trailers", includeMaster: true)
            XCTAssertTrue(bottom.contains("Ratings"), bottom)
            XCTAssertTrue(bottom.contains("Trailers"), bottom)
            XCTAssertTrue(bottom.contains("Off"), bottom)
            XCTAssertFalse(bottom.contains("Show ratings"), bottom)
            XCTAssertFalse(bottom.contains("Play trailer behind the hero"), bottom)
            XCTAssertFalse(bottom.contains("Show Common Sense age"), bottom)
            XCTAssertFalse(bottom.contains("Start muted"), bottom)

            scroll.setContentOffset(.zero, animated: false)
            models.heroSettingsModel.settings.autoAdvance = true
            let automatic = try await self.capture(window, name: "hero-inline-automatic", includeMaster: true)
            XCTAssertTrue(automatic.contains("Seconds per item"), automatic)
            XCTAssertFalse(automatic.localizedCaseInsensitiveContains("Automatic changes"), automatic)
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            for page in [HeroSettingsPage.titles, .ratings, .trailers] {
                if page != .titles {
                    scroll.setContentOffset(CGPoint(
                        x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    ), animated: false)
                    _ = try await self.capture(window, name: "hero-\(page.rawValue)-link", includeMaster: true)
                }
                let openingLabel = try XCTUnwrap(self.collectionLabelFrames(in: window).first {
                    $0.text == String(localized: page.title)
                })
                let center = CGPoint(x: openingLabel.frame.midX, y: openingLabel.frame.midY)
                let originatingLink = try XCTUnwrap(self.focusItems(in: window).first {
                    (try? self.nativeFrame($0, in: window).contains(center)) == true
                })
                let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
                host.artworkFocusTarget = originatingLink
                system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
                system.updateFocusIfNeeded()
                host.artworkFocusTarget = nil
                XCTAssertTrue(system.focusedItem === originatingLink)
                navigation.push(pageID: page.rawValue, animated: false)
                let shown = try await self.capture(window, name: "hero-\(page.rawValue)", includeMaster: true)
                let expected = page == .titles ? "Continue Watching"
                    : page == .ratings ? "Show ratings" : "Play trailer behind the hero"
                XCTAssertTrue(shown.contains(expected), shown)
                if page == .titles {
                    XCTAssertTrue(shown.contains("Hero content sources"), shown)
                }
                XCTAssertFalse(shown.contains("Hide watched content"), shown)
                XCTAssertFalse(navigation.awaitingFocus, "The page must receive native focus, not trap the master pane.")
                if page == .ratings {
                    XCTAssertFalse(shown.contains("Show Common Sense age"), shown)
                    models.heroSettingsModel.settings.showsRatings = true
                    let ratings = try await self.capture(window, name: "hero-ratings-enabled", includeMaster: true)
                    XCTAssertTrue(ratings.contains("Show Common Sense age"), ratings)
                    XCTAssertTrue(ratings.localizedCaseInsensitiveContains("Maximum ratings shown"), ratings)
                    XCTAssertTrue(ratings.contains("Shows fewer when fewer ratings are available"), ratings)
                } else if page == .trailers {
                    XCTAssertFalse(shown.contains("Start muted"), shown)
                    models.heroBackgroundModel.settings.homeTrailerEnabled = true
                    let trailers = try await self.capture(window, name: "hero-trailers-enabled", includeMaster: true)
                    XCTAssertTrue(trailers.contains("Start muted"), trailers)
                }
                navigation.pop(animated: false)
                let returnDeadline = ContinuousClock.now + .seconds(5)
                while (navigation.awaitingFocus || system.focusedItem == nil),
                      ContinuousClock.now < returnDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(navigation.awaitingFocus, "Wait for native return focus before blocking on OCR.")
                let returned = try await self.capture(window, name: "hero-return-\(page.rawValue)", includeMaster: true)
                if page != .titles {
                    XCTAssertTrue(returned.contains("On"), returned)
                    XCTAssertFalse(returned.contains("Show Common Sense age"), returned)
                    XCTAssertFalse(returned.contains("Start muted"), returned)
                }
                let label = try XCTUnwrap(self.collectionLabelFrames(in: window).first {
                    $0.text == String(localized: page.title)
                })
                let frame = try self.nativeFrame(try XCTUnwrap(system.focusedItem), in: window)
                XCTAssertTrue(frame.contains(CGPoint(x: label.frame.midX, y: label.frame.midY)),
                              "Return must focus \(page.rawValue), not a competing link. Focus: \(frame), label: \(label.frame)")
            }
            scroll.setContentOffset(.zero, animated: false)
            models.heroSettingsModel.settings.sources = [.featured, .watchlist]
            models.heroSettingsModel.settings.setEnabled(.featured, enabled: true)
            let selected = try await self.capture(window, name: "hero-selected-source-summary", includeMaster: true)
            XCTAssertTrue(selected.contains("Discovery"), selected)
            XCTAssertTrue(selected.contains("Watchlist"), selected)
            models.heroSettingsModel.setDiscoveryPolicy { false }
            let kids = try await self.capture(window, name: "hero-kids-source-summary", includeMaster: true)
            XCTAssertFalse(kids.contains("Discovery"), kids)
            XCTAssertTrue(kids.contains("Watchlist"), kids)
            models.heroSettingsModel.settings.sources = []
            let empty = try await self.capture(window, name: "hero-empty-source-summary", includeMaster: true)
            XCTAssertTrue(empty.contains("No content sources selected"), empty)
        }
    }

    func testNestedDiscoveryReturnsToTitleSourcesWithoutPoppingTheHeroPage() async throws {
        let namespace = "HeroNestedHosted.\(UUID())"
        let models = ProfileSettingsModel(namespace: namespace, isSeerrConfigured: { true })
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let parent = SettingsDetailNavigation()
        let child = SettingsDetailNavigation()
        parent.push(pageID: HeroSettingsPage.titles.rawValue, animated: false)
        try await withScreen(content: HeroSettingsScreen(
            page: .titles, libraries: [], accounts: [], childNavigation: child
        )
        .frame(width: 1100)
        .environment(parent)
        .environment(models.heroSettingsModel)
        .environment(models.heroBackgroundModel)) { window in
            _ = try await self.capture(window, name: "hero-grouped-title-sources", includeMaster: true)
            let sourceLabels = try self.collectionLabelFrames(in: window, attachmentName: "hero-source-label-metrics")
            let random = try XCTUnwrap(sourceLabels.first { $0.text == "Random from Library" })
            let choose = try XCTUnwrap(sourceLabels.first { $0.text == "Choose libraries" })
            let image = self.renderWindow(window)
            for label in [random, choose] {
                XCTAssertEqual(try self.textInkBounds(in: image, frame: label.frame).height,
                               try self.controlInkHeight(label.text, excludingOCRPadding: true), accuracy: 3,
                               "Source switches and links must use the shared control font, accounting for different glyphs.")
            }
            XCTAssertEqual(try self.textInkBounds(in: image, frame: random.frame).minX,
                           try self.textInkBounds(in: image, frame: choose.frame).minX, accuracy: 2,
                           "Grouped source controls must share a leading text edge.")
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
            let initialFrame = try self.nativeFrame(try XCTUnwrap(system.focusedItem), in: window)
            XCTAssertEqual(initialFrame.minX, (window.bounds.width - 1100) / 2 + SettingsFormMetrics.pageInset
                           + SettingsRowMetrics.formGroupInset, accuracy: 1)
            XCTAssertEqual(initialFrame.width,
                           1100 - 2 * (SettingsFormMetrics.pageInset + SettingsRowMetrics.formGroupInset), accuracy: 1)
            try self.assertConcentricGroup(in: window, focusFrame: initialFrame)
            var sourceFrames: [CGRect] = []
            for label in [random, choose] {
                let center = CGPoint(x: label.frame.midX, y: label.frame.midY)
                let target = try XCTUnwrap(self.focusItems(in: window).first {
                    (try? self.nativeFrame($0, in: window).contains(center)) == true
                })
                sourceFrames.append(try self.nativeFrame(target, in: window))
                host.artworkFocusTarget = target
                system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
                system.updateFocusIfNeeded()
                host.artworkFocusTarget = nil
                XCTAssertTrue(system.focusedItem === target)
                _ = try await self.capture(window, name: "hero-group-focus-\(sourceFrames.count)", includeMaster: true)
            }
            XCTAssertEqual(sourceFrames[0].height, sourceFrames[1].height, accuracy: 1)
            XCTAssertEqual(sourceFrames[1].minY - sourceFrames[0].maxY,
                           2 * SettingsFormMetrics.dividerFocusClearance + 1, accuracy: 1)
            let scroll = try self.verticalScroll(in: window)
            scroll.setContentOffset(CGPoint(
                x: scroll.contentOffset.x,
                y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            ), animated: false)
            _ = try await self.capture(window, name: "hero-title-source-options", includeMaster: true)
            let label = try XCTUnwrap(self.collectionLabelFrames(in: window)
                .first { $0.text == "Discovery providers" })
            let center = CGPoint(x: label.frame.midX, y: label.frame.midY)
            let target = try XCTUnwrap(self.focusItems(in: window).first {
                (try? self.nativeFrame($0, in: window).contains(center)) == true
            })
            host.artworkFocusTarget = target
            system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
            system.updateFocusIfNeeded()
            host.artworkFocusTarget = nil
            XCTAssertTrue(system.focusedItem === target)
            child.push(pageID: HeroSettingsPage.discovery.rawValue, animated: false)
            let opened = try await self.capture(window, name: "hero-nested-discovery", includeMaster: true)
            XCTAssertTrue(opened.contains("Show provider labels"), opened)
            XCTAssertFalse(child.awaitingFocus)
            child.pop(animated: false)
            _ = try await self.capture(window, name: "hero-nested-titles-return", includeMaster: true)
            XCTAssertTrue(parent.isPresented, "Returning from Discovery must not leave the title-source page.")
            let returnedLabel = try XCTUnwrap(self.collectionLabelFrames(in: window)
                .first { $0.text == "Discovery providers" })
            let frame = try self.nativeFrame(try XCTUnwrap(system.focusedItem), in: window)
            XCTAssertTrue(frame.contains(CGPoint(x: returnedLabel.frame.midX, y: returnedLabel.frame.midY)),
                          "Nested return should retain the source-option link: \(frame), \(returnedLabel.frame)")
        }
    }

    func testOpenDiscoveryPageRemovesProvidersWhenProfileBecomesKids() async throws {
        let namespace = "HeroKidsHosted.\(UUID())"
        let models = ProfileSettingsModel(namespace: namespace)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let navigation = SettingsDetailNavigation()
        navigation.push(pageID: HeroSettingsPage.discovery.rawValue, animated: false)
        try await withScreen(content: SettingsDetailPages(navigation: navigation) {
            HeroSettingsControls(libraries: [], accounts: [])
        } detail: {
            HeroSettingsDestination(libraries: [], accounts: [])
        }
        .frame(width: 1100)
        .environment(models.heroSettingsModel)
        .environment(models.heroBackgroundModel)) { window in
            let adult = try await self.capture(window, name: "hero-discovery-providers", includeMaster: true)
            XCTAssertTrue(adult.contains("Show provider labels"), adult)
            XCTAssertTrue(adult.contains("TMDB"), adult)
            models.heroSettingsModel.setDiscoveryPolicy { false }
            let kids = try await self.capture(window, name: "hero-discovery-kids", includeMaster: true)
            XCTAssertTrue(kids.contains("Discovery is unavailable in Kids profiles"), kids)
            XCTAssertFalse(kids.contains("TMDB"), kids)
            XCTAssertFalse(kids.contains("Show provider labels"), kids)
            _ = try self.backButton(beside: "Discovery", in: window)
            XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        }
    }

    func testEmptyHeroPagesEnterTheirSingleBackControl() async throws {
        let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
        hero.setDiscoveryPolicy { false }
        let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
        for page in [HeroSettingsPage.discovery, .libraries] {
            let navigation = SettingsDetailNavigation()
            navigation.push(pageID: page.rawValue, animated: false)
            try await withScreen(content: SettingsDetailPages(navigation: navigation) {
                HeroSettingsControls(libraries: [], accounts: [])
            } detail: {
                HeroSettingsDestination(libraries: [], accounts: [])
            }
                .frame(width: 1100)
                .environment(hero)
                .environment(background)) { window in
                _ = try await self.capture(window, name: "hero-empty-\(page.rawValue)", includeMaster: true)
                let back = try self.backButton(beside: String(localized: page.title), in: window)
                let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
                XCTAssertTrue(focused === back)
                XCTAssertFalse(navigation.awaitingFocus)
            }
        }
    }

    func testMultipleSelectionsShowTheirLibrariesAndClearingDoesNotSwitchTheBrowsedSource() async throws {
        let provider = HeroPickerHostedProvider(empty: false)
        let account = ResolvedAccount(account: Account(id: "a", from: provider.session), provider: provider)
        let libraries = ["movies", "shows"].map {
            AggregatedLibrary(
                accountID: "a", accountName: "Viewer", serverName: "Server", providerKind: .silo,
                library: MediaLibrary(id: $0, title: $0 == "movies" ? "Movies" : "Shows", kind: $0 == "movies" ? .movie : .series)
            )
        }
        var settings = HeroSettings.default
        settings.collections = libraries.map {
            .init(accountID: "a", libraryID: $0.library.id, collectionID: "\($0.library.id)-collection",
                  title: "\($0.library.id) picks", serverUserID: "viewer")
        }
        let model = HeroSettingsModel(store: InMemoryHeroSettingsStore(settings))
        try await withScreen(content: HeroCollectionPickerView(
            selections: Binding(get: { model.settings.collections }, set: { model.settings.collections = $0 }),
            libraries: libraries, accounts: [account]
        ).frame(width: 1100)) { window in
            let before = try await self.capture(window, name: "hero-multiple-selected-libraries", includeMaster: true)
            XCTAssertTrue(before.contains("Selected collections"), before)
            XCTAssertTrue(before.contains("movies picks"), before)
            XCTAssertTrue(before.contains("shows picks"), before)
            XCTAssertTrue(before.contains("Movies / Server / Viewer"), before)
            XCTAssertTrue(before.contains("Shows / Server / Viewer"), before)
            model.settings.collections = []
            let cleared = try await self.capture(window, name: "hero-cleared-same-library", includeMaster: true)
            XCTAssertFalse(cleared.contains("Selected collections"), cleared)
            XCTAssertTrue(cleared.contains("movies picks"), cleared)
            XCTAssertFalse(cleared.contains("Funny movies"), "Clearing choices must not reset the browsed source: \(cleared)")
        }
    }

    func testCollectionPickerScrollsThroughBottomSafeAreaToScreenEdge() async throws {
        let provider = HeroPickerHostedProvider(empty: false, collectionCount: 20)
        let account = ResolvedAccount(account: Account(id: "a", from: provider.session), provider: provider)
        let navigation = SettingsDetailNavigation()
        navigation.push(animated: false)
        try await withScreen(
            content: SettingsDetailPages(navigation: navigation) {
                Color.clear
            } detail: {
                HeroCollectionPickerView(selections: .constant([]), libraries: [], accounts: [account])
            }.frame(width: 1100),
            bottomSafeArea: 120
        ) { window in
            var pending = [try XCTUnwrap(window.rootViewController?.view)]
            var scrolls: [UIScrollView] = []
            while let view = pending.popLast() {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    scrolls.append(scroll)
                }
                pending.append(contentsOf: view.subviews)
            }
            let scroll = try XCTUnwrap(scrolls.max { $0.bounds.width < $1.bounds.width })
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: 500), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            let innerBottom = window.bounds.maxY - (window.rootViewController?.view.safeAreaInsets.bottom ?? 0)
            let before = try self.collectionLabelFrames(in: window)
            let row = try XCTUnwrap(before.last {
                $0.text.hasPrefix("Collection ") && $0.frame.maxY < innerBottom - 40
            }, "\(before)")
            let originalInkHeight = try self.textInkBounds(in: self.renderWindow(window), frame: row.frame).height
            let baselineOffset = scroll.contentOffset.y
            for targetY in [innerBottom + 30, window.bounds.maxY - 60] {
                let newOffset = baselineOffset + row.frame.minY - targetY
                XCTAssertGreaterThan(newOffset, -scroll.adjustedContentInset.top)
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: newOffset), animated: false)
                let text = try await self.capture(window, name: "collections-bottom-\(Int(targetY))", includeMaster: true)
                XCTAssertTrue(text.contains(row.text), "A row below the safe-area edge must remain readable: \(text)")
                let visible = try XCTUnwrap(self.collectionLabelFrames(in: window).first { $0.text == row.text })
                XCTAssertGreaterThan(visible.frame.minY, innerBottom + 15)
                XCTAssertLessThan(visible.frame.maxY, window.bounds.maxY)
                let visibleInkHeight = try self.textInkBounds(in: self.renderWindow(window), frame: visible.frame).height
                XCTAssertGreaterThan(visibleInkHeight, originalInkHeight * 0.85)
            }
        }
    }

    func testCustomizationBackAndTitleScrollThroughTheTopSafeAreaWithoutClipping() async throws {
        try await withScreen(
            content: CardCaptionCustomizationContent(
                settings: .constant(.init(preference: .show)), scope: .detail
            )
                .frame(width: 1100)
                .padding(.bottom, 350),
            topSafeArea: 60
        ) { window in
            var pending = [try XCTUnwrap(window.rootViewController?.view)]
            var scrolls: [UIScrollView] = []
            while let view = pending.popLast() {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    scrolls.append(scroll)
                }
                pending.append(contentsOf: view.subviews)
            }
            let scroll = try XCTUnwrap(scrolls.max { $0.bounds.width < $1.bounds.width })
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            _ = try await self.capture(window, name: "labels-before-top-scroll", includeMaster: true)
            let before = try self.collectionLabelFrames(in: window)
            let title = try XCTUnwrap(before.first { $0.text == "Customize labels" })
            let backItem = try self.backButton(beside: "Customize labels", in: window)
            let backControlFrame = try self.nativeFrame(backItem, in: window)
            let beforeImage = self.renderWindow(window)
            let titleInk = try self.textInkBounds(in: beforeImage, frame: title.frame)
            let backInk = try self.textInkBounds(in: beforeImage,
                                                frame: backControlFrame.insetBy(dx: 12, dy: 12))
            let viewport = scroll.convert(scroll.bounds, to: window)
            let innerTop = viewport.minY + scroll.adjustedContentInset.top
            let distance = backInk.minY - innerTop + 14
            XCTAssertGreaterThan(distance, 20)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + distance), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            _ = try await self.capture(window, name: "labels-crossing-top-inset", includeMaster: true)
            let after = try self.collectionLabelFrames(in: window)
            let scrolledTitle = try XCTUnwrap(after.first { $0.text == "Customize labels" })
            let scrolledControlFrame = try self.nativeFrame(backItem, in: window)
            let afterImage = self.renderWindow(window)
            let scrolledTitleInk = try self.textInkBounds(in: afterImage, frame: scrolledTitle.frame)
            let scrolledBackInk = try self.textInkBounds(in: afterImage,
                                                        frame: scrolledControlFrame.insetBy(dx: 12, dy: 12))
            XCTAssertLessThan(scrolledBackInk.minY, innerTop - 8)
            XCTAssertGreaterThan(scrolledBackInk.height, backInk.height * 0.85,
                                 "The back chevron must remain visible across the top inset.")
            XCTAssertEqual(backControlFrame.minY - scrolledControlFrame.minY, distance, accuracy: 1)
            XCTAssertEqual(titleInk.minY - scrolledTitleInk.minY, distance, accuracy: 3,
                           "Neither Back nor the title should be pinned.")
            let text = try await self.capture(window, name: "labels-scrolling-through-top-inset", includeMaster: true)
            XCTAssertTrue(text.contains("Episodes"), text)
        }
    }

    func testLabelHelpKeepsVisibilityInThePreviewRatherThanDuplicateProse() async throws {
        let suite = "LabelVisibilityHelpHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        try await withScreen(content: CardCaptionCustomizationView(cards: cards).frame(width: 1100)) { window in
            for (preference, expected) in [
                (CardCaptionPreference.show, "On"),
                (.hide, "Off"),
                (.recommended, "Mixed")
            ] {
                cards.captions = CardCaptionSettings(preference: preference)
                let text = try await self.capture(window, name: "label-help-\(preference.rawValue)", includeMaster: true)
                XCTAssertTrue(text.contains(expected), text)
                if preference == .recommended {
                    XCTAssertTrue(text.contains("Mixed hides labels in Showcase"), text)
                    XCTAssertTrue(text.contains("other cards keep their labels"), text)
                } else {
                    XCTAssertTrue(text.contains("Changes labels below Home cards"), text)
                    XCTAssertFalse(text.contains("Mixed hides labels"), text)
                }
                XCTAssertTrue(text.contains("Default"), text)
                XCTAssertFalse(text.contains("each page's setting"), text)
                XCTAssertFalse(text.contains("Labels are visible"), text)
                XCTAssertFalse(text.contains("Labels are hidden"), text)
            }
        }
    }

    func testCollectionPickerUsesPaneHeaderAndReturnsRealFocus() async throws {
        let provider = HeroPickerHostedProvider(empty: false)
        let account = ResolvedAccount(account: Account(id: "a", from: provider.session), provider: provider)
        let navigation = SettingsDetailNavigation()
        let picker = HeroCollectionPickerView(selections: .constant([]), libraries: [], accounts: [account])
        try await withScreen(content: NavigationStack {
            HStack(spacing: 0) {
                Text("Customize Home").frame(width: 768)
                SettingsDetailPages(navigation: navigation) {
                    SettingsDetailLink {
                        picker
                    } label: {
                        Text("Choose collection")
                    }
                } detail: {
                    picker
                }
            }
            .ignoresSafeArea()
        }) { window in
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            navigation.push(animated: false)
            let deadline = ContinuousClock.now + .seconds(3)
            while navigation.awaitingFocus, ContinuousClock.now < deadline {
                system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
                system.updateFocusIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(navigation.awaitingFocus)
            let text = try await self.capture(window, name: "hero-personal-collection-pane", includeMaster: true)
            let focused = try self.nativeFocusedFrame(system, in: window)
            let labels = try self.collectionLabelFrames(in: window)
            let sourceLabel = try XCTUnwrap(labels.first { $0.text == "Personal collections" })
            XCTAssertTrue(focused.contains(CGPoint(x: sourceLabel.frame.midX, y: sourceLabel.frame.midY)),
                          "Entry must reach the real source row, not Back: \(focused), label: \(sourceLabel.frame)")
            let heading = try XCTUnwrap(self.collectionLabelFrames(in: window, matchingText: "Choose collections").first)
            XCTAssertGreaterThan(heading.frame.minX, 800)
            let headingInk = try self.textInkBounds(in: self.renderWindow(window), frame: heading.frame)
            XCTAssertLessThan(headingInk.height, 60, "The shared page title must fit the available pane.")
            XCTAssertTrue(text.contains("Choose collections"), text)
            _ = try self.backButton(beside: "Choose collections", in: window)
            XCTAssertTrue(text.contains("Funny movies from year 2000"), text)
            XCTAssertTrue(text.contains("Personal collections"), text)
            let rows = self.focusItems(in: window)
            XCTAssertFalse(rows.contains { $0 is UISegmentedControl })
            for row in rows {
                guard let view = row as? UIView else { continue }
                let frame = view.convert(view.bounds, to: window)
                XCTAssertGreaterThanOrEqual(frame.minX, 768, "Controls must stay in the detail pane.")
                XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
            }
            navigation.pop(animated: false)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(navigation.awaitingFocus)
            let restored = try self.nativeFocusedFrame(system, in: window)
            let rootLabel = try XCTUnwrap(self.collectionLabelFrames(in: window).first { $0.text == "Choose collection" })
            XCTAssertTrue(restored.contains(CGPoint(x: rootLabel.frame.midX, y: rootLabel.frame.midY)),
                          "Back must restore native focus to the parent link.")
        }
    }

    func testCollectionPickerLongLibraryNamesAndEmptySourceStayWithinPane() async throws {
        let provider = HeroPickerHostedProvider(empty: true)
        let account = ResolvedAccount(account: Account(id: "a", from: provider.session), provider: provider)
        let library = AggregatedLibrary(
            accountID: "a", accountName: "Viewer", serverName: "Server",
            providerKind: .silo,
            library: MediaLibrary(id: "movies", title: "Movies with a very long library name that must wrap without clipping", kind: .movie)
        )
        try await withScreen(content: NavigationStack {
            HStack(spacing: 0) {
                Text("Customize Home").frame(width: 768)
                HeroCollectionPickerView(selections: .constant([]), libraries: [library], accounts: [account])
            }
            .ignoresSafeArea()
        }) { window in
            let text = try await self.capture(window, name: "hero-long-source-labels", includeMaster: true)
            XCTAssertTrue(text.contains("without clipping"), text)
            XCTAssertTrue(text.contains("No collections in this source"), text)
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            XCTAssertNotNil(system.focusedItem, "An empty collection list must still offer real focusable controls.")
        }
    }

    private func nativeFocusedFrame(_ system: UIFocusSystem, in window: UIWindow) throws -> CGRect {
        try nativeFrame(XCTUnwrap(system.focusedItem), in: window)
    }

    private func backButton(beside title: String, in window: UIWindow) throws -> any UIFocusItem {
        let heading = try XCTUnwrap(collectionLabelFrames(in: window, matchingText: title)
            .min { $0.frame.minY < $1.frame.minY }).frame
        let buttons = try focusItems(in: window).filter {
            let frame = try nativeFrame($0, in: window)
            // OCR can include the adjacent chevron in the heading's bounds.
            return frame.midX < heading.minX && frame.minY < heading.maxY && frame.maxY > heading.minY
        }
        let frames = try focusItems(in: window).map { try nativeFrame($0, in: window) }
        XCTAssertEqual(buttons.count, 1,
                       "The page must have one native Back control beside \(heading). Items: \(frames)")
        return try XCTUnwrap(buttons.first)
    }

    private func nativeFrame(_ item: any UIFocusItem, in window: UIWindow) throws -> CGRect {
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return try XCTUnwrap(Optional<CGRect>.none, "A focused row must expose native focus coordinates.")
    }

    private func collectionLabelFrames(
        in window: UIWindow, attachmentName: String? = nil, matchingText: String? = nil
    ) throws -> [(text: String, frame: CGRect)] {
        window.layoutIfNeeded()
        let image = renderWindow(window)
        if let attachmentName {
            let attachment = XCTAttachment(image: image)
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return try (request.results ?? []).compactMap { result in
            guard let candidate = result.topCandidates(1).first else { return nil }
            let text = candidate.string
            let bounds: CGRect
            if let matchingText {
                guard let range = text.range(of: matchingText),
                      let box = try candidate.boundingBox(for: range) else { return nil }
                bounds = box.boundingBox
            } else {
                bounds = result.boundingBox
            }
            return (text, CGRect(
                x: bounds.minX * window.bounds.width, y: (1 - bounds.maxY) * window.bounds.height,
                width: bounds.width * window.bounds.width, height: bounds.height * window.bounds.height
            ))
        }
    }

    private func controlInkHeight(_ text: String, excludingOCRPadding: Bool = false) throws -> CGFloat {
        let renderer = ImageRenderer(content: Text(verbatim: text)
            .font(SettingsRowMetrics.titleFont)
            .foregroundStyle(.white)
            .padding(20)
            .background(.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let bounds = try XCTUnwrap(request.results?.first).boundingBox
        guard excludingOCRPadding else { return bounds.height * image.size.height }
        return try textInkBounds(in: image, frame: CGRect(
            x: bounds.minX * image.size.width, y: (1 - bounds.maxY) * image.size.height,
            width: bounds.width * image.size.width, height: bounds.height * image.size.height
        )).height
    }

    /// OCR locates the label; actual ink avoids contrast-dependent OCR box padding.
    private func textInkBounds(
        in image: UIImage, frame: CGRect, lightForegroundThreshold: UInt8? = nil
    ) throws -> CGRect {
        let bounds = frame.insetBy(dx: -4, dy: -4).integral
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: bounds))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let threshold: UInt8
        let darkText: Bool
        if let lightForegroundThreshold {
            threshold = lightForegroundThreshold
            darkText = false
        } else {
            threshold = try UInt8((Int(XCTUnwrap(pixels.min())) + Int(XCTUnwrap(pixels.max()))) / 2)
            darkText = try XCTUnwrap(pixels.first) > threshold
        }
        let foreground = pixels.indices.filter {
            darkText ? pixels[$0] < threshold : pixels[$0] > threshold
        }
        let columns = foreground.map { $0 % crop.width }
        let rows = foreground.map { $0 / crop.width }
        let minX = try XCTUnwrap(columns.min())
        let minY = try XCTUnwrap(rows.min())
        return CGRect(
            x: bounds.minX + CGFloat(minX), y: bounds.minY + CGFloat(minY),
            width: CGFloat(try XCTUnwrap(columns.max()) - minX + 1),
            height: CGFloat(try XCTUnwrap(rows.max()) - minY + 1)
        )
    }

    private func assertConcentricGroup(in window: UIWindow, focusFrame: CGRect) throws {
        let image = try XCTUnwrap(renderWindow(window).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        func brightness(x: Int, y: Int) -> UInt8 { pixels[(y * image.width + x) * 4] }
        let horizontal = Array(Int(focusFrame.minX - 30)...Int(focusFrame.maxX + 30))
        let vertical = Array(Int(focusFrame.minY - 30)...Int(focusFrame.maxY + 30))
        for samples in [
            horizontal.map { brightness(x: $0, y: Int(focusFrame.midY)) },
            vertical.map { brightness(x: Int(focusFrame.midX), y: $0) }
        ] {
            let background = try XCTUnwrap(samples.first)
            let outerStart = try XCTUnwrap(samples.firstIndex { Int($0) > Int(background) + 5 })
            let innerStart = try XCTUnwrap(samples.firstIndex { $0 > 240 })
            let outerEnd = try XCTUnwrap(samples.lastIndex { Int($0) > Int(background) + 5 })
            let innerEnd = try XCTUnwrap(samples.lastIndex { $0 > 240 })
            XCTAssertEqual(CGFloat(innerStart - outerStart), SettingsRowMetrics.formGroupInset, accuracy: 1)
            XCTAssertEqual(CGFloat(outerEnd - innerEnd), SettingsRowMetrics.formGroupInset, accuracy: 1)
        }
    }

    func testFullPageArtworkHighlightsRemainVisibleAtEveryRoundedCorner() throws {
        var hero = HeroSettings.default
        hero.style = .carousel
        for (area, kind) in [
            (ArtworkArea.home, ArtworkScopeDiagram.DetailKind.movie),
            (.details, .movie), (.details, .series)
        ] {
            for palette in [ThemePalette.dark, .light, .pureBlack] {
                for scale in [CGFloat(1), 2] {
                    let renderer = ImageRenderer(content:
                        ArtworkScopeDiagram(area: area, detailKind: kind, heroSettings: hero)
                            .frame(width: 256, height: 144)
                            .environment(\.themePalette, palette)
                    )
                    renderer.scale = scale
                    let image = try XCTUnwrap(renderer.cgImage)
                    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                    try pixels.withUnsafeMutableBytes { bytes in
                        let context = try XCTUnwrap(CGContext(
                            data: bytes.baseAddress, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        ))
                        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    }
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    XCTAssertTrue(UIColor(palette.accent).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                    for trailing in [false, true] {
                        for bottom in [false, true] {
                            var accentPixels = 0
                            for y in Int(2 * scale)..<Int(9 * scale) {
                                for x in Int(2 * scale)..<Int(9 * scale) {
                                    let column = trailing ? image.width - 1 - x : x
                                    let row = bottom ? image.height - 1 - y : y
                                    let offset = (row * image.width + column) * 4
                                    if abs(CGFloat(pixels[offset]) - red * 255) < 35,
                                       abs(CGFloat(pixels[offset + 1]) - green * 255) < 35,
                                       abs(CGFloat(pixels[offset + 2]) - blue * 255) < 35,
                                       pixels[offset + 3] > 220 {
                                        accentPixels += 1
                                    }
                                }
                            }
                            XCTAssertGreaterThanOrEqual(
                                accentPixels, Int(3 * scale * scale),
                                "\(area) \(kind), scale=\(scale), trailing=\(trailing), bottom=\(bottom)"
                            )
                        }
                    }
                    let attachment = XCTAttachment(image: UIImage(cgImage: image))
                    attachment.name = "highlight-corners-\(area)-\(kind)-\(scale)-\(palette.isLight)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testCustomizationCardReservesAStableViewportWithoutOverlappingRows() async throws {
        let helpCases: [ViewCustomizationHelp?] = [
            nil,
            ViewCustomizationHelp(detail: try XCTUnwrap(ArtworkArea.home.detail), illustration: .artwork(.home)),
            ViewCustomizationHelp(detail: try XCTUnwrap(ArtworkArea.playback.detail), illustration: .artwork(.playback)),
            ViewCustomizationHelp(detail: try XCTUnwrap(ArtworkArea.details.detail), illustration: .artwork(.details)),
            CardCaptionSettings.default.customizationHelp(in: .home, style: .framed),
            CardCaptionSettings(preference: .hide).customizationHelp(in: .home, style: .borderless)
        ]
        var viewportHeight: CGFloat?
        for (index, help) in helpCases.enumerated() {
            try await withScreen(content: ViewCustomizationList(
                title: "Artwork by view", initialRowID: "viewport-first",
                focusedHelp: { _ in help }
            ) {
                ForEach(0..<18) { index in
                    ViewCustomizationRow(
                        id: index == 0 ? "viewport-first" : "viewport-\(index)",
                        title: "Music", value: "Library", cycle: {}
                    )
                }
            }
            .frame(width: 1100, height: 900)
            .ignoresSafeArea()) { window in
                var views = [try XCTUnwrap(window.rootViewController?.view)]
                var scrollViews: [UIScrollView] = []
                while let view = views.popLast() {
                    if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                        scrollViews.append(scroll)
                    }
                    views.append(contentsOf: view.subviews)
                }
                let scroll = try XCTUnwrap(scrollViews.max { $0.bounds.width < $1.bounds.width })
                if help == nil {
                    XCTAssertEqual(scroll.bounds.height, 900, accuracy: 2,
                                   "Lists without contextual help must not reserve a blank footer.")
                } else {
                    XCTAssertEqual(scroll.bounds.height, 632, accuracy: 2,
                                   "Reserve exactly the card, inset and separation, not an overlay.")
                    if let viewportHeight {
                        XCTAssertEqual(scroll.bounds.height, viewportHeight, accuracy: 1)
                    }
                    viewportHeight = scroll.bounds.height
                    XCTAssertEqual(scroll.adjustedContentInset.bottom, 40, accuracy: 1)
                }
                _ = try await self.capture(window, name: "customization-inset-card-\(index)",
                                           includeMaster: true)
            }
        }
    }

    func testLabelPreviewsOfferRecommendedAndShareCustomizationControls() async throws {
        let suite = "LabelPreviewHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        let settings = Binding(get: { cards.captions }, set: { cards.captions = $0 })
        try await withScreen(content: NavigationStack {
            SettingsSplitLayout(
                title: "Cards",
                rows: [SettingsSplitRow(id: "labels", title: "Labels") {
                    CardLabelControls(settings: settings, style: .borderless)
                }],
                selection: .constant("labels")
            )
        }) { window in
            let initial = try await self.capture(window, name: "labels-recommended-preview")
            for text in [
                "App default", "Show labels everywhere", "Hide labels everywhere",
                "Customize labels"
            ] {
                XCTAssertTrue(initial.contains(text), initial)
            }
            XCTAssertFalse(initial.contains("Showcase"), initial)
            XCTAssertFalse(initial.contains("Plozz chooses"), initial)
            XCTAssertFalse(initial.contains("customizations override"), initial)
            XCTAssertFalse(initial.contains("Using defaults"), initial)
            let previews = self.focusItems(in: window).filter { $0.frame.height > 150 && $0.frame.width > 150 }
            XCTAssertEqual(previews.count, 3)
            let height = try XCTUnwrap(previews.first).frame.height
            for preview in previews {
                XCTAssertEqual(preview.frame.height, height, accuracy: height * 0.02,
                               "Presets must share a height, allowing only native focus scaling.")
            }
            XCTAssertEqual(cards.captions.preference, .recommended)
            cards.captions.setOverride(.hide, for: .browse)
            let customized = try await self.capture(window, name: "labels-customized-preview")
            XCTAssertTrue(customized.split(whereSeparator: \.isWhitespace).contains("Custom"), customized)
            XCTAssertFalse(customized.contains("Remove view customizations"), customized)
            XCTAssertNil(cards.captions.selectedPreset)
        }
    }

    func testContextCardsKeepTheirSentenceReadableAcrossThemesAndTextSizes() async throws {
        let detail = try XCTUnwrap(ArtworkArea.continueWatching.detail)
        for (name, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                try await withScreen(content: VStack(spacing: 40) {
                    ViewCustomizationHelpCard(help: .init(
                        detail: detail, illustration: .artwork(.continueWatching)
                    ))
                    Button("Focus target") {}
                }
                .padding(48)
                .frame(width: 1100)
                .background(palette.settingsBackground)
                .environment(\.themePalette, palette)
                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                .environment(\.dynamicTypeSize, size)) { window in
                    let copy = try await self.capture(window, name: "context-card-\(name)-\(size)", includeMaster: true)
                    XCTAssertTrue(copy.contains(String(localized: detail)), copy)
                    XCTAssertEqual(self.focusItems(in: window).count, 1,
                                   "Illustrations and help must remain non-interactive.")
                }
            }
        }
    }

    func testLabelViewChoicesUseShortValuesAndPresetsReplaceCustomizations() async throws {
        let suite = "LabelChoicesHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        let settings = Binding(get: { cards.captions }, set: { cards.captions = $0 })
        try await withScreen(content: CardCaptionCustomizationContent(
            settings: settings
        )) { window in
            let initial = try await self.capture(window, name: "labels-browse-inherited", includeMaster: true)
            XCTAssertTrue(initial.contains("Customize labels"), initial)
            XCTAssertTrue(initial.contains("Mixed"), initial)
            XCTAssertFalse(initial.contains("Main setting"), initial)
            XCTAssertFalse(initial.contains("App default"), initial)
            XCTAssertTrue(initial.contains("Home"), initial)
            XCTAssertTrue(initial.contains("Continue Watching"), initial)
            XCTAssertFalse(initial.contains("No labels"), initial)
            let scroll = try self.verticalScroll(in: window)
            let initialOffset = scroll.contentOffset
            scroll.setContentOffset(CGPoint(
                x: initialOffset.x,
                y: max(-scroll.adjustedContentInset.top,
                       scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            ), animated: false)
            let overrides = try await self.capture(
                window, name: "labels-home-row-overrides", includeMaster: true
            )
            for label in ["Overrides", "Continue Watching", "Libraries", "Use default"] {
                XCTAssertTrue(overrides.contains(label), overrides)
            }
            XCTAssertTrue(overrides.contains("Continue Watching is shared with Recommended"), overrides)
            scroll.setContentOffset(initialOffset, animated: false)
            cards.captions.toggleCustomization(in: .home)
            let changed = try await self.capture(window, name: "labels-home-explicit", includeMaster: true)
            XCTAssertNil(changed.range(of: #"\bCustom\b"#, options: .regularExpression), changed)
            XCTAssertEqual(cards.captions.override(for: .home), .show)
            XCTAssertEqual(cards.captions.override(for: .continueWatching), .automatic)
            XCTAssertEqual(cards.captions.override(for: .homeLibraries), .automatic)
            XCTAssertTrue(cards.captions.showsLabels(in: .home))
            XCTAssertEqual(CardCaptionSettingsStore(defaults: defaults).load(), cards.captions)
            cards.captions.applyPreset(.show)
            XCTAssertTrue(cards.captions.showsLabels(in: .browse))
            XCTAssertTrue(cards.captions.overrides.isEmpty)
        }
    }

    func testWatchIndicatorPickerShowsThreeNativePreviewChoices() async throws {
        let suite = "WatchChoicesHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(defaults: defaults))
        try await withScreen(content: SettingsSplitLayout(title: "Watch indicators", rows: [
            SettingsSplitRow(id: "watch-indicators", title: "Watch indicators") {
                CompactWatchIndicatorPicker(
                    selection: Binding(get: { model.indicator }, set: { model.indicator = $0 }),
                    swatchHeight: 150
                )
            }
        ])) { window in
            for mode in WatchStatusIndicator.allCases {
                model.indicator = mode
                let text = try await self.capture(window, name: "watch-choices-\(mode)", includeMaster: true)
                for label in ["Watched", "Unwatched", "Hidden"] {
                    XCTAssertTrue(text.contains(label), text)
                }
            }
        }
    }

    func testCardsDetailScrollsThroughWatchedIndicatorsAndTheLastStyleRow() async throws {
        let suite = "CardsViewportHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        let watched = WatchStatusIndicatorSettingsModel(
            store: WatchStatusIndicatorSettingsStore(defaults: defaults)
        )
        try await withScreen(content: SettingsSplitLayout(
            title: "Appearance",
            rows: [SettingsSplitRow(
                id: "cards", title: "Cards",
                description: "How media cards look across the app.",
                subpage: SettingsDetailSubpage { CardCaptionCustomizationView(cards: cards) }
            ) {
                CardAppearanceControls(cards: cards, watchIndicator: watched)
            }]
        )) { window in
            var views = [try XCTUnwrap(window.rootViewController?.view)]
            var scrollViews: [UIScrollView] = []
            while let view = views.popLast() {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    scrollViews.append(scroll)
                }
                views.append(contentsOf: view.subviews)
            }
            let scroll = try XCTUnwrap(scrollViews.max { $0.bounds.width < $1.bounds.width })
            for (offset, words) in [
                (CGFloat(180), ["Watched", "Unwatched"]),
                (scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom,
                 ["Posters", "Cards"])
            ] {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
                let copy = try await self.capture(window, name: "cards-viewport-\(Int(offset))")
                for word in words { XCTAssertTrue(copy.contains(word), copy) }
            }
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
            let target = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window) else { return nil }
                return frame.minX > window.bounds.width * 0.4 && frame.height > 150 ? (item, frame) : nil
            }.max { $0.1.maxY < $1.1.maxY }?.0)
            host.artworkFocusTarget = target
            system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
            system.updateFocusIfNeeded()
            host.artworkFocusTarget = nil
            let focused = try await self.capture(window, name: "cards-last-style-focused")
            XCTAssertTrue(system.focusedItem === target)
            XCTAssertTrue(focused.contains("Posters") && focused.contains("Cards"), focused)
        }
    }

    func testAppearanceSeparatesArtworkAndGatesHouseholdProviderNavigation() async throws {
        let namespace = "ArtworkAppearanceHosted.\(UUID())"
        let models = ProfileSettingsModel(namespace: namespace)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        models.cardStyleModel.artwork = .default
        let navigation = SettingsNavigationModel()
        navigation.appearanceRowID = "artwork"
        let libraries = ProfileLibrariesScope(
            accounts: [], activeProfile: .init(id: namespace, name: "Viewer"),
            discoveredLibraries: .empty, refreshingLibraryAccountIDs: [],
            unreachableLibraryAccountIDs: [], reloadLibraries: {},
            homeVisibility: models.homeLibraryVisibilityModel,
            isAccountIncludedInActiveProfile: { _ in false },
            onSetAccountIncluded: { _, _ in }, onAddAccount: {},
            plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
        )
        for canManage in [true, false] {
            let content = NavigationStack {
                AppearanceDetailView(
                    librariesScope: libraries, settingsNavigation: navigation,
                    canManageProviders: canManage,
                    theme: models.themeModel, nightShift: models.nightShiftModel,
                    spoilers: models.spoilerModel
                )
            }
            .environment(models.musicPlayerModel)
            .environment(models.uiDensityModel)
            .environment(models.cardStyleModel)
            .environment(models.watchStatusIndicatorModel)
            .environment(models.navigationStyleModel)
            .environment(models.transparencyModel)
            .environment(models.appLanguageModel)
            .environment(models.contentRatingModel)
            try await withScreen(content: content) { window in
                let text = try await self.capture(window, name: "artwork-appearance-providers-\(canManage)")
                XCTAssertTrue(text.contains("Choose the posters, backgrounds, and logos you see"), text)
                XCTAssertTrue(text.contains("Recommended"), text)
                XCTAssertTrue(text.contains("Prefer my library"), text)
                XCTAssertTrue(text.contains("Prefer artwork from metadata providers"), text)
                XCTAssertTrue(text.contains("Customize by view"), text)
                XCTAssertFalse(text.contains("Using defaults"), text)
                XCTAssertFalse(text.contains("About artwork sources"), text)
                XCTAssertFalse(text.contains("Remove view customizations"), text)
                XCTAssertEqual(text.contains("Metadata Providers"), canManage, text)
                XCTAssertEqual(text.contains("TMDB"), canManage, text)
                XCTAssertEqual(text.contains("TheTVDB"), canManage, text)
                XCTAssertFalse(text.contains("Online services"), text)
                if canManage {
                    models.cardStyleModel.artwork.setOverride(.library, for: .browse)
                    let customized = try await self.capture(window, name: "artwork-appearance-customized")
                    XCTAssertTrue(customized.split(whereSeparator: \.isWhitespace).contains("Custom"), customized)
                    XCTAssertFalse(customized.contains("Remove view customizations"), customized)
                    models.cardStyleModel.artwork.resetOverrides()
                }
            }
        }
    }

    func testBrowseShowsOnlyItsSourceAndPresetChangesReplaceExplicitChoices() async throws {
        let suite = "ArtworkSettingsHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        try await withScreen(cards: cards, area: .browse) { window in
            let inherited = try await self.capture(window, name: "artwork-browse-use-preset")
            XCTAssertTrue(inherited.contains("Library"), inherited)
            XCTAssertFalse(inherited.contains("Main setting"), inherited)
            XCTAssertFalse(inherited.contains("Recommended"), inherited)
            XCTAssertFalse(inherited.contains("Use default"), inherited)
            XCTAssertFalse(inherited.contains("without text"), inherited)
            XCTAssertFalse(inherited.contains("Continue Watching"), inherited)
            XCTAssertLessThan(inherited.split(whereSeparator: \.isWhitespace).count, 8, inherited)

            cards.artwork.setOverride(.online, for: .browse)
            let overridden = try await self.capture(window, name: "artwork-browse-provider-first")
            XCTAssertTrue(overridden.contains("Metadata providers"), overridden)
            XCTAssertFalse(overridden.contains("Custom"), overridden)
            XCTAssertEqual(cards.artwork.override(for: .browse), .online)
            cards.artwork.applyPreset(.library)
            let changed = try await self.capture(window, name: "artwork-browse-changed-preset")
            XCTAssertTrue(changed.contains("Library"), changed)
            XCTAssertFalse(changed.contains("Custom"), changed)
            XCTAssertEqual(cards.artwork.selectedPreset, .library)
            XCTAssertTrue(cards.artwork.overrides.isEmpty)
            XCTAssertEqual(ArtworkSettingsStore(defaults: defaults).load(), cards.artwork)
        }
    }

    func testContinueWatchingShowsOnlyItsResolvedSource() async throws {
        let suite = "ArtworkContinueWatchingHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        try await withScreen(cards: cards, area: .continueWatching) { window in
            let text = try await self.capture(window, name: "artwork-continue-watching")
            XCTAssertTrue(text.contains("Metadata providers"), text)
            XCTAssertFalse(text.contains("Main setting"), text)
            XCTAssertFalse(text.contains("Recommended"), text)
            XCTAssertFalse(text.contains("Custom"), text)
            XCTAssertTrue(cards.artwork.prefersTextlessArtwork(in: .continueWatching))
            let row = try XCTUnwrap(self.focusItems(in: window).first { $0.frame.width > 700 })
            XCTAssertLessThan(row.frame.height, 80, "The name and value must fit one line at normal TV text size.")
        }
    }

    func testMixedChoicesCycleBackOnTVWithoutChangingOtherViews() async throws {
        let suite = "MixedChoicesHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        cards.artwork = ArtworkSettings(preference: .library)
        try await withScreen(cards: cards, area: .details) { window in
            for value in ["Library", "Metadata providers", "Mixed", "Library"] {
                let text = try await self.capture(window, name: "artwork-details-cycle-\(value)")
                XCTAssertTrue(text.contains(value), text)
                XCTAssertFalse(text.contains("Use default"), text)
                XCTAssertEqual(cards.artwork.preference(in: .browse), .library)
                XCTAssertEqual(ArtworkSettingsStore(defaults: defaults).load(), cards.artwork)
                cards.artwork.toggleCustomization(in: .details)
            }
        }
        cards.captions = CardCaptionSettings(preference: .hide)
        try await withScreen(content: SettingsSplitLayout(
            title: "Cards",
            rows: [SettingsSplitRow(id: "labels", title: "Labels") {
                CardCaptionViewChoices(view: .home, settings: Binding(
                    get: { cards.captions }, set: { cards.captions = $0 }
                ))
            }]
        )) { window in
            for value in ["Off", "Mixed", "On", "Off"] {
                let text = try await self.capture(window, name: "labels-home-cycle-\(value)")
                XCTAssertTrue(text.contains(value), text)
                XCTAssertFalse(text.contains("Use default"), text)
                XCTAssertFalse(cards.captions.showsLabels(in: .browse))
                XCTAssertEqual(CardCaptionSettingsStore(defaults: defaults).load(), cards.captions)
                cards.captions.toggleCustomization(in: .home)
            }
        }
    }

    func testPresetExplanationsFollowNativeFocusWithoutChangingSelection() async throws {
        let suite = "ArtworkFocusHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        try await withScreen(content: NavigationStack {
            SettingsSplitLayout(
                title: "Appearance",
                rows: [SettingsSplitRow(id: "artwork", title: "Artwork") {
                    ArtworkSettingsControls(cards: cards)
                }],
                selection: .constant("artwork")
            )
        }) { window in
            let snippets = [
                "Plozz chooses artwork to suit each part",
                "Always use local artwork from your libraries",
                "Always use metadata-provider artwork"
            ]
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
            for index in 0..<4 {
                window.layoutIfNeeded()
                let allItems = self.focusItems(in: window)
                let items = allItems.filter { $0.frame.width > 700 }
                    .sorted { $0.frame.minY < $1.frame.minY }
                XCTAssertEqual(items.count, 4, allItems.map { "\($0.frame)" }.joined(separator: ", "))
                let target = try XCTUnwrap(items.indices.contains(index) ? items[index] : nil)
                host.artworkFocusTarget = target
                system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
                system.updateFocusIfNeeded()
                host.artworkFocusTarget = nil
                let text = try await self.capture(window, name: "artwork-preset-focus-\(index)")
                XCTAssertTrue(system.focusedItem === target, "Inline help must retain native focus.")
                if index == 0 {
                    let title = try XCTUnwrap(self.collectionLabelFrames(in: window, matchingText: "Recommended").first)
                    let ink = try self.textInkBounds(in: self.renderWindow(window), frame: title.frame)
                    XCTAssertEqual(ink.height, try self.controlInkHeight("Recommended", excludingOCRPadding: true), accuracy: 3,
                                   "Artwork presets must use the same body-sized font as other settings controls.")
                }
                for (snippetIndex, snippet) in snippets.enumerated() {
                    XCTAssertEqual(text.contains(snippet), index == snippetIndex, text)
                }
                XCTAssertEqual(cards.artwork.preference, .recommended, "Focus must not select a preference.")
                XCTAssertFalse(text.contains("About artwork sources"), text)
            }
        }
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) {
                    items[ObjectIdentifier(item)] = item
                }
            }
        }
        return Array(items.values)
    }

    private func verticalScroll(in window: UIWindow) throws -> UIScrollView {
        var pending = [try XCTUnwrap(window.rootViewController?.view)]
        var scrolls: [UIScrollView] = []
        while let view = pending.popLast() {
            if let scroll = view as? UIScrollView {
                scrolls.append(scroll)
            }
            pending.append(contentsOf: view.subviews)
        }
        return try XCTUnwrap(scrolls.max { $0.bounds.width < $1.bounds.width })
    }

    private func makeCards(defaults: UserDefaults) -> CardStyleSettingsModel {
        CardStyleSettingsModel(
            store: CardStyleSettingsStore(defaults: defaults),
            focusStore: CardFocusStyleSettingsStore(defaults: defaults),
            captionStore: CardCaptionSettingsStore(defaults: defaults),
            artworkStore: ArtworkSettingsStore(defaults: defaults)
        )
    }

    private func withNavigationReorderScreen(
        libraryNames: [String] = ["Movies", "TV Shows"],
        inspect: (UIWindow) async throws -> Void
    ) async throws {
        let namespace = "NavigationScaleHosted.\(UUID())"
        let models = ProfileSettingsModel(namespace: namespace)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        models.navigationStyleModel.style = .sidebar
        let libraries = libraryNames.enumerated().map { index, name in
            AggregatedLibrary(
                accountID: index.isMultiple(of: 2) ? "plex" : "jellyfin",
                accountName: "Viewer", serverName: index.isMultiple(of: 2) ? "Plex" : "Jellyfin",
                providerKind: index.isMultiple(of: 2) ? .plex : .jellyfin,
                library: MediaLibrary(id: "library-\(index)", title: name, kind: index == 1 ? .series : .movie)
            )
        }
        let scope = ProfileLibrariesScope(
            accounts: [], activeProfile: .init(id: namespace, name: "Viewer"),
            discoveredLibraries: .loaded(libraries), refreshingLibraryAccountIDs: [],
            unreachableLibraryAccountIDs: [], reloadLibraries: {},
            homeVisibility: models.homeLibraryVisibilityModel,
            isAccountIncludedInActiveProfile: { _ in true },
            onSetAccountIncluded: { _, _ in }, onAddAccount: {},
            plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
        )
        try await withScreen(content: ScrollView {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.formSectionSpacing) {
                Text("Navigation").settingsFeatureTitle()
                NavigationLibrariesDetailView(scope: scope, navigation: models.navigationStyleModel)
            }
            .padding(48)
        }.frame(width: 1100), inspect: inspect)
    }

    private func withScreen(
        cards: CardStyleSettingsModel,
        area: ArtworkArea,
        inspect: (UIWindow) async throws -> Void
    ) async throws {
        try await withScreen(
            content: SettingsSplitLayout(
                title: "Appearance",
                rows: [SettingsSplitRow(id: "artwork", title: "Artwork") {
                    ArtworkAreaChoices(area: area, settings: Binding(
                        get: { cards.artwork }, set: { cards.artwork = $0 }
                    ))
                }]
            ),
            inspect: inspect
        )
    }

    private func withScreen(
        content: some View,
        topSafeArea: CGFloat = 0,
        bottomSafeArea: CGFloat = 0,
        colorScheme: ColorScheme = .dark,
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
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let palette = colorScheme == .dark ? ThemePalette.dark : .light
        let host = ArtworkFocusHost(rootView:
            content
                .background(palette.settingsBackground)
                .environment(\.themePalette, palette)
                .environment(\.colorScheme, colorScheme)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        host.additionalSafeAreaInsets.top = topSafeArea
        host.additionalSafeAreaInsets.bottom = bottomSafeArea
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let focusDeadline = ContinuousClock.now + .seconds(3)
        while system.focusedItem == nil, ContinuousClock.now < focusDeadline {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(system.focusedItem)
        try await Task.sleep(for: .milliseconds(350))
        try await waitForHostedLayout(window)
        try await inspect(window)
    }

    private func renderWindow(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            UIColor.black.setFill()
            context.fill(window.bounds)
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func capture(_ window: UIWindow, name: String, includeMaster: Bool = false) async throws -> String {
        try await Task.sleep(for: .milliseconds(250))
        try await waitForHostedLayout(window)
        let image = renderWindow(window)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        if !includeMaster {
            request.regionOfInterest = CGRect(x: 0.40, y: 0, width: 0.60, height: 1)
        }
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

@MainActor
@Observable
private final class SettingsScaleFixtureState {
    enum Option: Hashable, CaseIterable {
        case balanced, compact, detailed

        var title: LocalizedStringResource {
            switch self {
            case .balanced: "Balanced"
            case .compact: "Compact"
            case .detailed: "Detailed"
            }
        }
    }

    var selection: Option = .balanced
    var focused: Option?
}

private struct SettingsScaleFixture: View {
    let state: SettingsScaleFixtureState

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Button("Balanced") {}
                .buttonStyle(SettingsFormButtonStyle())
            SettingsSegmentedPicker(
                options: SettingsScaleFixtureState.Option.allCases,
                selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
                title: { $0.title }, onFocusedOptionChange: { state.focused = $0 }
            )
            LiftableReorderList(
                sections: .init(enabled: ["Balanced"], disabled: []),
                disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden rows",
                isLifting: .constant(false),
                row: { .init(title: Text(verbatim: $0)) }, onChange: { _ in }
            )
            PreviewCard(
                title: "Balanced", isSelected: false, accent: .purple,
                compact: true, swatchHeight: 44, action: {}
            ) {
                Color.gray
            }
            .frame(width: 350)
            Text("Balanced").settingsHelperText()
            Text("Balanced").settingsSectionDescription()
        }
        .padding(40)
    }
}

@MainActor
private protocol ArtworkFocusRequesting: AnyObject {
    var artworkFocusTarget: (any UIFocusEnvironment)? { get set }
}

@MainActor
private final class HeroHostedLocale: ObservableObject {
    @Published var value = Locale(identifier: "en_US")
}

private struct HeroLocaleHostedControls: View {
    @ObservedObject var locale: HeroHostedLocale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.formSectionSpacing) {
                HeroSettingsControls(libraries: [], accounts: [])
            }
            .padding(48)
        }
        .environment(\.locale, locale.value)
    }
}

private struct HeroPickerHostedProvider: MediaProvider, CapabilityReporting {
    let empty: Bool
    var collectionCount = 1
    let kind: ProviderKind = .silo
    let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.com")!, provider: .silo),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture"
    )
    var capabilities: ProviderCapability { [.personalCollections, .libraryCollections] }
    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: empty ? [] : [
            .init(id: "\(libraryID)-collection", title: "\(libraryID) picks", kind: .collection)
        ], startIndex: 0, totalCount: empty ? 0 : 1)
    }
    func personalCollections(page: PageRequest) async throws -> MediaPage {
        let items: [MediaItem] = empty ? [] : (0..<collectionCount).map {
            .init(
                id: $0 == 0 ? "personal" : "personal-\($0)",
                title: $0 == 0 ? "Funny movies from year 2000+" : "Collection \($0 + 1)",
                kind: .collection
            )
        }
        return .init(items: Array(items.dropFirst(page.startIndex).prefix(page.limit)),
                     startIndex: page.startIndex, totalCount: items.count)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
private final class ArtworkFocusHost<Content: View>: UIHostingController<Content>, ArtworkFocusRequesting {
    weak var artworkFocusTarget: (any UIFocusEnvironment)?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        artworkFocusTarget.map { [$0] } ?? super.preferredFocusEnvironments
    }
}
