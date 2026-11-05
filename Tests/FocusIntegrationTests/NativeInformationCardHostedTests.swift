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
    func testSummaryAlignsSideBySideSurfacesAndScoreIconGaps() async throws {
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
        for (count, hasGuidance, longOverview) in [
            (1, false, false), (2, false, false), (3, false, false), (5, false, false),
            (1, true, false), (2, true, false), (3, true, false),
            (4, true, false), (5, true, false), (4, false, true), (0, true, false)
        ] {
            var item = MediaItem(
                id: "summary", title: "Slow Horses", kind: .series,
                overview: "A dysfunctional team of MI5 agents navigate the espionage world's smoke and mirrors to defend the UK from sinister forces.",
                productionYear: 2022
            )
            if longOverview {
                item.overview = String(repeating: item.overview ?? "", count: 8)
            }
            item.ratings = Array([
                ExternalRating(source: .rottenTomatoes, value: 98, scale: .percent),
                .init(source: .rottenTomatoesAudience, value: 88, scale: .percent),
                .init(source: .imdb, value: 8.3, scale: .outOfTen),
                .init(source: .tmdb, value: 8.1, scale: .outOfTen),
                .init(source: .metacritic, value: 73, scale: .outOfHundred)
            ].prefix(count))
            if hasGuidance {
                item.familyGuidance = .init(
                    recommendedAge: 16, qualityRating: nil,
                    overview: "Smart espionage thriller has language, violence, drinking."
                )
            }
            window.rootViewController = UIHostingController(rootView:
                ScrollView {
                    DetailInformationSections(item: item, horizontalInset: 80)
                }
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.themePalette, .dark)
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            let cards = nativeCards(in: window)
            let expectedCount = count + (hasGuidance ? 1 : 0) + 1
            XCTAssertEqual(cards.count, expectedCount,
                           "Each score owns a tile; guidance participates in the same grid.")
            guard cards.count == expectedCount else { continue }
            let frames = try cards.map { card in
                let container = try XCTUnwrap(card.superview)
                return container.convert(container.bounds, to: window)
            }
            let about = frames[0]
            let ratings = Array(frames.dropFirst())
            let contentWidth = window.bounds.inset(by: window.safeAreaInsets).width - 160
            let columnWidth = (contentWidth - 2 * DetailInformationLayout.sectionSpacing) / 3
            XCTAssertEqual(about.width, columnWidth, accuracy: 1,
                           "TV prose must stay within one third-width column.")
            XCTAssertEqual(ratings[0].minY, about.minY, accuracy: 1)
            XCTAssertGreaterThan(ratings[0].minX, about.maxX)
            let tileCount = count + (hasGuidance ? 1 : 0)
            let compactScore = count == 1 && !hasGuidance
            let compactWidth = max(220, (columnWidth - DetailInformationLayout.sectionSpacing) / 2)
            let ratingsWidth = tileCount > 1 ? 2 * columnWidth + DetailInformationLayout.sectionSpacing
                : (compactScore ? compactWidth : columnWidth)
            let columns = hasGuidance ? min(4, max(2, count + 1)) : min(4, count > 4 ? (count + 1) / 2 : count)
            let cellWidth = (ratingsWidth - CGFloat(columns - 1) * DetailInformationLayout.gutter) / CGFloat(columns)
            for score in ratings.prefix(count) {
                XCTAssertEqual(score.width, cellWidth, accuracy: 1,
                               "Scores must use equal flexible columns, not fixed 220pt tiles.")
                if count == 4 && !hasGuidance {
                    XCTAssertEqual(score.minY, ratings[0].minY, accuracy: 1,
                                   "Four TV scores should read across one row rather than a 2-by-2 grid.")
                }
            }
            if tileCount == 1 && !compactScore {
                XCTAssertEqual(ratings[0].width, columnWidth, accuracy: 1,
                               "A lone score or guide must occupy only one reading column.")
            }
            XCTAssertEqual(try XCTUnwrap(ratings.map(\.maxX).max()), ratings[0].minX + ratingsWidth, accuracy: 1)
            if compactScore {
                XCTAssertLessThan(ratings[0].height, about.height,
                                  "A single score must not stretch to match the synopsis.")
            } else {
                XCTAssertEqual(try XCTUnwrap(ratings.map(\.maxY).max()), about.maxY, accuracy: 1,
                               "Multi-tile About and Ratings must share a bottom edge: frames=\(frames)")
            }
            if hasGuidance {
                let guide = try XCTUnwrap(ratings.last)
                let column = count % columns
                let span = min(2, columns - column)
                let rightEdge = ratings[0].minX + CGFloat(column) * (cellWidth + DetailInformationLayout.gutter)
                    + CGFloat(span) * cellWidth + CGFloat(span - 1) * DetailInformationLayout.gutter
                XCTAssertEqual(guide.maxX, rightEdge, accuracy: 1)
                XCTAssertLessThanOrEqual(guide.width, 560)
                if count > 0 {
                    let lastScore = ratings[count - 1]
                    if count % columns == 0 {
                        XCTAssertEqual(guide.minX, ratings[0].minX, accuracy: 1)
                        XCTAssertGreaterThan(guide.minY, lastScore.maxY)
                    } else {
                        XCTAssertEqual(guide.minX - lastScore.maxX, DetailInformationLayout.gutter, accuracy: 1)
                        XCTAssertEqual(guide.minY, lastScore.minY, accuracy: 1)
                        XCTAssertEqual(guide.maxY, lastScore.maxY, accuracy: 1)
                    }
                }
            }
            if count == 4 && hasGuidance {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: XCTUnwrap(DetailTransitionSnapshot.image(of: window).cgImage))
                    .perform([request])
                let values = try XCTUnwrap(request.results).filter {
                    ["98%", "88%", "8.3", "8.1"].contains($0.topCandidates(1).first?.string ?? "")
                }.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                XCTAssertEqual(values.count, 4)
                let pixels = try informationPixels(window)
                let paintedValues = values.map { value in
                    paintedTextBounds(pixels, in: CGRect(
                        x: value.boundingBox.minX * 1920,
                        y: (1 - value.boundingBox.maxY) * 1080,
                        width: value.boundingBox.width * 1920,
                        height: value.boundingBox.height * 1080
                    ).insetBy(dx: -6, dy: -4))
                }
                for (index, value) in paintedValues.enumerated() {
                    let scores = ratings[index]
                    XCTAssertFalse(value.isNull)
                    XCTAssertEqual(value.midY, paintedValues[0].midY, accuracy: 3)
                    var iconLeft: Int?
                    var iconRight: Int?
                    for y in Int(scores.minY + 24)..<Int(scores.maxY - 24) {
                        for x in Int(value.minX - 100)..<Int(value.minX) {
                            let offset = (y * 1920 + x) * 4
                            let channels = pixels[offset..<(offset + 3)]
                            if let high = channels.max(), let low = channels.min(),
                               high > 160, high - low > 45 {
                                iconLeft = min(iconLeft ?? x, x)
                                iconRight = max(iconRight ?? x, x)
                            }
                        }
                    }
                    let gap = value.minX - CGFloat(try XCTUnwrap(iconRight) + 1)
                    XCTAssertEqual(gap, 16, accuracy: 2,
                                   "Visible mark edges, not their centered slots, determine the score gap.")
                    let visibleCenter = (CGFloat(try XCTUnwrap(iconLeft)) + value.maxX) / 2
                    XCTAssertEqual(visibleCenter, scores.midX, accuracy: 2,
                                   "Each complete mark-and-score unit must have balanced space within its column.")
                }
            }
            let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            attachment.name = "summary-\(count)-scores-guidance-\(hasGuidance)-long-\(longOverview)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testRatingsWithoutOverviewKeepTheirColumnSpan() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for count in [1, 3, 4, 5] {
            var item = MediaItem(id: "ratings-only", title: "A film", kind: .movie)
            item.ratings = Array([
                ExternalRating(source: .rottenTomatoes, value: 98, scale: .percent),
                .init(source: .rottenTomatoesAudience, value: 88, scale: .percent),
                .init(source: .imdb, value: 8.3, scale: .outOfTen),
                .init(source: .tmdb, value: 8.1, scale: .outOfTen),
                .init(source: .metacritic, value: 73, scale: .outOfHundred)
            ].prefix(count))
            window.rootViewController = UIHostingController(rootView:
                ScrollView { DetailInformationSections(item: item, horizontalInset: 80) }
                    .environment(\.plozzCardFocusStyle, .system)
                    .environment(\.themePalette, .dark)
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            let cards = nativeCards(in: window)
            XCTAssertEqual(cards.count, count)
            let frames = try cards.map { card in
                let container = try XCTUnwrap(card.superview)
                return container.convert(container.bounds, to: window)
            }
            let content = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 80, dy: 0)
            let columnWidth = (content.width - 2 * DetailInformationLayout.sectionSpacing) / 3
            let width = count == 1 ? max(220, (columnWidth - DetailInformationLayout.sectionSpacing) / 2)
                : 2 * columnWidth + DetailInformationLayout.sectionSpacing
            XCTAssertEqual(try XCTUnwrap(frames.map(\.minX).min()), content.minX, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(frames.map(\.maxX).max()), content.minX + width, accuracy: 1,
                           "Missing About must not reserve a column or stretch ratings across the whole page.")
        }
    }

    func testStackedSummaryKeepsIntrinsicCardHeights() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 720, height: 1080)
        var item = MediaItem(id: "stacked-summary", title: "A title", kind: .movie,
                             overview: String(repeating: "A story about two friends travelling together. ", count: 8))
        item.ratings = [.init(source: .tmdb, value: 8.1, scale: .outOfTen)]
        window.rootViewController = UIHostingController(rootView:
            ScrollView { DetailInformationSections(item: item, horizontalInset: 40) }
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.themePalette, .dark)
        )
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        let cards = nativeCards(in: window)
        XCTAssertEqual(cards.count, 2)
        guard cards.count == 2 else { return }
        let frames = try cards.map { card in
            let container = try XCTUnwrap(card.superview)
            return container.convert(container.bounds, to: window)
        }
        XCTAssertGreaterThan(frames[1].minY, frames[0].maxY)
        XCTAssertLessThan(frames[1].height, 160, "A stacked score must not inherit the synopsis height.")
        XCTAssertGreaterThan(frames[0].height, frames[1].height + 40)
    }

    func testFocusedAboutKeepsReadableTextInLightAppearance() async throws {
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
        for longOverview in [false, true] {
            let item = MediaItem(
                id: "light-about", title: "An unexpected journey", kind: .movie,
                overview: String(repeating: "Two friends travel together and discover a new city. ",
                                 count: longOverview ? 30 : 1)
            )
            let host = NativeInformationFocusHost(rootView: AnyView(
                DetailInformationSections(item: item, horizontalInset: 80)
                    .environment(\.themePalette, .light)
                    .environment(\.colorScheme, .light)
                    .environment(\.gradientBackgroundsEnabled, false)
                    .environment(\.plozzCardFocusStyle, .system)
            ))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            let card = try XCTUnwrap(nativeCards(in: window).first)
            host.target = card
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(card.isFocused)
            let surface = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: card.contentView, in: window))
            let textRegion = surface.insetBy(dx: 24, dy: 24).intersection(window.bounds).integral
            let pixels = try informationPixels(window)
            var darkPixels = 0
            for y in Int(textRegion.minY)..<Int(textRegion.maxY) {
                for x in Int(textRegion.minX)..<Int(textRegion.maxX) {
                    if pixels[(y * 1920 + x) * 4] < 80 { darkPixels += 1 }
                }
            }
            XCTAssertGreaterThan(darkPixels, 200, "Focused About text must not become white on a light card.")
            let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            attachment.name = "light-about-expandable-\(longOverview)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testDetailFactsUseUnboxedThirdWidthColumns() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let item = MediaItem(
            id: "layout", title: "A film", kind: .movie, productionYear: 2026,
            officialRating: "TV-MA", genres: ["Horror", "Science Fiction", "Adventure"],
            people: [
                .init(id: "director-1", name: "Saul Metzstein", kind: "Director"),
                .init(id: "director-2", name: "Adam Randall", kind: "Director"),
                .init(id: "director-3", name: "James Hawes", kind: "Director"),
                .init(id: "writer-1", name: "Will Smith", kind: "Writer"),
                .init(id: "writer-2", name: "Mark Denton", kind: "Writer"),
                .init(id: "writer-3", name: "Jonny Stockwood", kind: "Writer")
            ],
            studios: ["First Studio", "Second Studio", "Third Studio", "Fourth Studio"],
            runtime: 5_700
        )
        window.rootViewController = UIHostingController(rootView:
            ScrollView {
                DetailInformationSections(
                    item: item, horizontalInset: 80,
                    selectedSource: MediaSourceRef(
                        accountID: "fixture", itemID: item.id, providerKind: .jellyfin,
                        serverName: "Living room server", accountName: "Household", locality: .local
                    ),
                    selectedVersion: MediaVersion(
                        id: "file", fileName: "A film (2026) - [WEBDL-2160p][DV HDR10Plus][EAC3 5.1][h265].mkv",
                        width: 3840, height: 2160, bitrate: 25_300_000, sizeBytes: 17_800_000_000,
                        videoCodec: "hevc", videoRange: "DOVI", audioCodec: "eac3", audioChannels: 6
                    )
                )
            }
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(nativeCards(in: window).isEmpty,
                      "Lower metadata must not acquire permanent card surfaces.")
        let image = DetailTransitionSnapshot.image(of: window)
        let attachment = XCTAttachment(image: image)
        attachment.name = "detail-fact-keylines-and-insets"
        attachment.lifetime = .keepAlways
        add(attachment)
        var headingYs: [CGFloat] = []
        let contentFrame = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 80, dy: 0)
        let spacing = DetailInformationLayout.sectionSpacing
        let columnWidth = (contentFrame.width - 2 * spacing) / 3
        for (index, heading) in ["Details", "Crew", "Playback"].enumerated() {
            let frame = CGRect(x: contentFrame.minX + CGFloat(index) * (columnWidth + spacing),
                               y: 0, width: columnWidth, height: 1080)
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: frame))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let observations = try XCTUnwrap(request.results)
            XCTAssertFalse(observations.isEmpty)
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let title = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == heading })
            XCTAssertLessThanOrEqual(title.boundingBox.minX * columnWidth, 3)
            headingYs.append((1 - title.boundingBox.maxY) * 1080)
            if index == 0 {
                XCTAssertFalse(text.contains("MORE"), "Short facts must not inherit truncation from a fitting probe: \(text)")
                XCTAssertTrue(text.contains("TV-MA"), "The complete classification must remain visible: \(text)")
                let labels = observations.filter {
                    ["Year", "Runtime", "Content Rating"].contains($0.topCandidates(1).first?.string ?? "")
                }
                XCTAssertEqual(labels.count, 3)
                XCTAssertEqual(Set(labels.map { Int($0.boundingBox.midY * 1080) }).count, 3,
                               "Facts stack under their section instead of stretching across the page.")
            }
            if index == 1 {
                let writerLabel = try XCTUnwrap(observations.first {
                    $0.topCandidates(1).first?.string == "Written By"
                })
                let directors = try XCTUnwrap(observations.first {
                    $0.topCandidates(1).first?.string.contains("Saul Metzstein") == true
                })
                XCTAssertGreaterThan(directors.boundingBox.minY, writerLabel.boundingBox.maxY)
            }
            if index == 2 {
                let filename = try XCTUnwrap(observations.first {
                    $0.topCandidates(1).first?.string.contains(".mkv") == true
                })
                XCTAssertLessThanOrEqual(filename.boundingBox.maxX, 1)
            }
        }
        XCTAssertEqual(headingYs[0], headingYs[1], accuracy: 3)
        XCTAssertEqual(headingYs[0], headingYs[2], accuracy: 5)
    }

    private func paintedTextBounds(_ pixels: [UInt8], in region: CGRect) -> CGRect {
        let interior = region.intersection(CGRect(x: 0, y: 0, width: 1920, height: 1080)).integral
        var bounds = CGRect.null
        for y in Int(interior.minY)..<Int(interior.maxY) {
            for x in Int(interior.minX)..<Int(interior.maxX) {
                let offset = (y * 1920 + x) * 4
                if pixels[offset] > 140 && pixels[offset + 1] > 140 && pixels[offset + 2] > 140 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds
    }

    func testMoreOverlayDoesNotParticipateInTextSizing() {
        let plain = UIHostingController(rootView: Text("TV-MA").font(.system(size: 24)))
        let expanded = UIHostingController(rootView:
            DetailInlineMoreLabel(isTruncated: true, fadeWidth: 120, textFont: .system(size: 24)) {
                Text("TV-MA").font(.system(size: 24))
            }
        )
        let proposal = CGSize(width: 600, height: 200)
        let expected = plain.sizeThatFits(in: proposal)
        let actual = expanded.sizeThatFits(in: proposal)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }

    func testInlineMoreDoesNotEraseThePreviousLine() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: InlineMorePixelFixture(showsMore: false))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        let before = try informationPixels(window)
        host.rootView = InlineMorePixelFixture(showsMore: true)
        try await Task.sleep(for: .milliseconds(400))
        let after = try informationPixels(window)
        let earlierLines = Int(floor(UIFont.systemFont(ofSize: 24).lineHeight * 2))
        var earlierInk = 0
        var earlierChanges = 0
        var lastLineChanges = 0
        for y in 0..<100 {
            for x in 0..<340 {
                let offset = (y * 1920 + x) * 4
                let changed = (0..<3).contains { abs(Int(before[offset + $0]) - Int(after[offset + $0])) > 3 }
                if y < earlierLines {
                    if before[offset] > 30 { earlierInk += 1 }
                    if changed { earlierChanges += 1 }
                } else if changed {
                    lastLineChanges += 1
                }
            }
        }
        XCTAssertGreaterThan(earlierInk, 100, "The comparison must include rendered text, not an empty crop.")
        XCTAssertLessThanOrEqual(earlierChanges, 20, "More must not alter glyphs on an earlier line.")
        XCTAssertGreaterThan(lastLineChanges, 50, "The final line must actually show the fade and More.")
        let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        attachment.name = "inline-more-final-line-only"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUnboxedFactTruncationUpdatesSettleWithoutCreatingCards() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let model = NativeInformationRefreshModel()
        model.item = MediaItem(
            id: "facts", title: "Series", originalTitle: "Original title", kind: .series,
            productionYear: 2026, genres: ["Drama"],
            people: [MediaPerson(id: "director", name: "Director", kind: "Director")],
            studios: ["Studio"]
        )
        let host = NativeInformationFocusHost(rootView: AnyView(NativeInformationFactFixture(model: model)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        for expanded in [true, false, true, false] {
            model.item.originalTitle = expanded
                ? String(repeating: "A very long original title ", count: 40) : "Original title"
            model.item.studios = expanded ? (1...30).map { "Production Studio \($0)" } : ["Studio"]
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(nativeCards(in: window).isEmpty)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(DetailTransitionSnapshot.image(of: window).cgImage))
                .perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertEqual(text.contains("MORE"), expanded, text)
        }
    }

    func testEagerInformationRowsIncludeTheirLastNativeCard() async throws {
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
        let host = NativeInformationFocusHost(rootView: AnyView(
            VStack(alignment: .leading) {
                ProportionalWrapLayout(
                    preferredColumns: 4, minimumCellWidth: 300, spacing: 40, rowSpacing: 28
                ) {
                    ForEach(0..<8) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Field \(index)").font(.system(size: 18))
                            Text(index == 7 ? "FINAL VALUE" : "Value \(index)")
                                .font(.system(size: 24))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .plozzFocusableCard(cornerRadius: 12)
                    }
                }
                Spacer()
            }
            .frame(width: 1600, height: 1080, alignment: .topLeading)
            .environment(\.plozzNativeInformationFocus, true)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .background(.black)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let cards = nativeCards(in: window).sorted {
            let first = $0.convert($0.bounds, to: window)
            let second = $1.convert($1.bounds, to: window)
            return abs(first.minY - second.minY) > 1 ? first.minY < second.minY : first.minX < second.minX
        }
        XCTAssertEqual(cards.count, 8)
        for card in cards {
            XCTAssertEqual(card.cardBackgroundColor, UIColor(ThemePalette.dark.raised.fill))
            XCTAssertGreaterThan(card.bounds.height, 60)
        }
        let firstCard = try XCTUnwrap(cards.first)
        let lastCard = try XCTUnwrap(cards.last)
        let first = firstCard.convert(firstCard.bounds, to: window)
        let last = lastCard.convert(lastCard.bounds, to: window)
        XCTAssertGreaterThan(last.minY, first.maxY + 20)
        let image = DetailTransitionSnapshot.image(of: window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(recognized.contains { $0.contains("FINAL VALUE") }, "\(recognized)")
        let attachment = XCTAttachment(image: image)
        attachment.name = "eager-information-two-rows"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
        XCTAssertEqual(cards.count, 6, "Only About, four scores and guidance own permanent card surfaces.")
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
        XCTAssertGreaterThanOrEqual(cards.count, 3)
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
        let placedSize = card.contentSize
        XCTAssertEqual(placedSize.width, 300, accuracy: 1)
        XCTAssertGreaterThan(placedSize.height, 70)
        XCTAssertLessThanOrEqual(placedSize.height, 280)
        let baseline = try informationPixels(window)
        let region = card.contentView.convert(card.contentView.bounds, to: window).insetBy(dx: 12, dy: 12).integral
        var sizes: [CGSize] = []
        var changedPixels: [Int] = []
        for tick in 0..<8 {
            withAnimation(.easeInOut(duration: 0.3)) { model.generation = tick }
            try await Task.sleep(for: .milliseconds(60))
            sizes.append(card.contentSize)
            XCTAssertEqual(card.contentSize.width, 300, accuracy: 1)
            XCTAssertEqual(card.contentSize.height, placedSize.height, accuracy: 1)
            XCTAssertEqual(card.contentView.bounds.width, 300, accuracy: 1)
            XCTAssertEqual(card.contentView.bounds.height, placedSize.height, accuracy: 1)
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
        XCTAssertGreaterThanOrEqual(cards.count, 3)
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

private struct InlineMorePixelFixture: View {
    let showsMore: Bool

    var body: some View {
        DetailInlineMoreLabel(isTruncated: showsMore, fadeWidth: 120, textFont: .system(size: 24)) {
            Text(verbatim: "Upper line ending in gypqy\nMiddle line ending in gypqy\nLast line ending in several words")
                .font(.system(size: 24))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 340, alignment: .leading)
        }
        .foregroundStyle(.white)
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .background(.black)
        .ignoresSafeArea()
    }
}

private struct NativeInformationFactFixture: View {
    let model: NativeInformationRefreshModel

    var body: some View {
        ScrollView {
            DetailInformationSections(item: model.item, horizontalInset: 80)
        }
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.gradientBackgroundsEnabled, false)
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
