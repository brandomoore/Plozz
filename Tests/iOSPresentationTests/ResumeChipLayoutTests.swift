#if os(iOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class ResumeChipLayoutTests: XCTestCase {
    private enum Contents: CaseIterable {
        case full, progressAndText, text, smallerText
    }

    func testPortraitChipDropsDecorationsBeforeReducingText() throws {
        let metrics = PlozzMetrics.touch(density: .standard)
        let item = MediaItem(
            id: "resume-fit", title: "Episode", kind: .episode,
            seasonNumber: 1, episodeNumber: 12, runtime: 3600, resumePosition: 900
        )
        let detail = try XCTUnwrap(item.seasonEpisodeLabel)
        let label = detail + " · " + (try XCTUnwrap(item.resumeRemainingText))
        var selected = Set<Contents>()
        for width: CGFloat in [260, 190, 170, 150, 132, 100, 86] {
            let spacing = min(metrics.resumeChipInset, width * 0.05) * 0.5
            let available = width - metrics.resumeChipInset * 2 - spacing * 2
            let choice = try Contents.allCases.first { contents in
                if contents == .smallerText { return true }
                return try render(row(contents, label: label, metrics: metrics, spacing: spacing)).size.width <= available
            }
            let contents = try XCTUnwrap(choice)
            selected.insert(contents)
            let actual = try render(
                ResumeChipOverlay(
                    item: item, detailText: detail, showsPlayGlyphWhenIdle: true,
                    compactHorizontalLayout: true
                )
                .withoutScrim
                .environment(\.plozzMetrics, metrics)
                .frame(width: width, height: 160)
                .background(.black)
            )
            let expected = try render(
                HStack(spacing: spacing) {
                    row(contents, label: label, metrics: metrics, spacing: spacing)
                    Spacer(minLength: spacing)
                }
                .padding(metrics.resumeChipInset)
                .frame(width: width, height: 160, alignment: .bottom)
                .background(.black)
            )
            try assertPixelsEqual(actual, expected, context: "\(width): \(contents)")
            if [260, 190, 150, 132, 86].contains(width) {
                attach(actual, name: "Portrait chip \(width) \(contents)")
            }
        }
        XCTAssertEqual(selected, Set(Contents.allCases), "Exercise every fallback, not just text-only.")
    }

    func testNarrowAndAccessibilityChipsKeepCompleteEpisodeAndTime() throws {
        let item = MediaItem(
            id: "long-resume-fit", title: "Episode", kind: .episode,
            seasonNumber: 12, episodeNumber: 123, runtime: 7200, resumePosition: 300
        )
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            let metrics = PlozzMetrics.touch(density: .standard, dynamicTypeSize: size)
            for width: CGFloat in [86, 132, 180] {
                for downloaded in [false, true] {
                    let image = try render(
                        ResumeChipOverlay(
                            item: item, downloadState: downloaded ? .completed : nil,
                            detailText: item.seasonEpisodeLabel, showsPlayGlyphWhenIdle: true,
                            compactHorizontalLayout: true
                        )
                        .withoutScrim
                        .environment(\.plozzMetrics, metrics)
                        .environment(\.dynamicTypeSize, size)
                        .frame(width: width, height: 300)
                        .background(.black)
                    )
                    let strings = try recognizedText(image)
                    let text = strings.joined(separator: " ").replacingOccurrences(of: " ", with: "")
                    let context = "\(width), \(size), downloaded: \(downloaded): \(strings)"
                    XCTAssertFalse(text.contains("…") || text.contains("..."), context)
                    XCTAssertTrue(text.contains("12") && text.contains("123"), context)
                    XCTAssertTrue(text.contains("1h") && text.contains("55m"), context)
                    if width == 132 { attach(image, name: "Long portrait chip \(size) downloaded \(downloaded)") }
                }
            }
        }
    }

    func testUnknownRuntimeRetainsProgressAndIdleEpisodesKeepIdentity() throws {
        for resumePosition: Double? in [nil, 900] {
            let item = MediaItem(
                id: "unknown-runtime", title: "Episode", kind: .episode,
                seasonNumber: 1, episodeNumber: 12, resumePosition: resumePosition,
                playedPercentage: resumePosition == nil ? nil : 0.25
            )
            let image = try render(
                ResumeChipOverlay(
                    item: item, detailText: item.seasonEpisodeLabel, showsPlayGlyphWhenIdle: true,
                    compactHorizontalLayout: true
                )
                .withoutScrim
                .environment(\.plozzMetrics, PlozzMetrics.touch(density: .standard))
                .frame(width: 100, height: 120)
                .background(.black)
            )
            let text = try recognizedText(image).joined()
            XCTAssertTrue(text.contains("12"), text)
            XCTAssertFalse(text.contains("…"), text)
        }
    }

    func testPlaybackReservationCannotConsumeMoreThanThirtyPercentOfThePoster() throws {
        func image(reserved: CGFloat, detailed: Bool = true) throws -> UIImage {
            try render(
                ExtendedArtworkFill(
                    picture: Color.white, artworkAspectRatio: 2.0 / 3.0, sideCrop: 0,
                    minimumReflectionShare: detailed ? 0.1 : 0
                )
                .environment(\.portraitPlaybackReflectionHeight, reserved)
                .frame(width: 120, height: 180)
            )
        }

        let capped = try image(reserved: 600)
        XCTAssertEqual(capped.size, CGSize(width: 120, height: 180))
        try assertPixelsEqual(capped, image(reserved: 54), context: "The bottom band is capped at 30%, never half.")
        XCTAssertNotEqual(capped.pngData(), try image(reserved: 0).pngData(), "Measured text must reserve room.")
        try assertPixelsEqual(
            image(reserved: 600, detailed: false), image(reserved: 0, detailed: false),
            context: "Progress only must not reserve a playback-text band."
        )
    }

    func testHiddenCardProgressPreservesPlayGlyphAndRemainingTimeButNotPlayerBars() throws {
        let item = MediaItem(id: "resume", title: "Movie", kind: .movie, runtime: 3600, resumePosition: 900)
        let pill = EpisodeWatchStatePill(item: item, showsBackground: false)
            .environment(\.plozzChromeIsFocused, true)
        let actual = try render(pill.environment(\.plozzShowsProgressBars, false))
        let remaining = try XCTUnwrap(item.resumeRemainingText)
        let expected = try render(
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(verbatim: remaining)
            }
            .foregroundStyle(.white)
            .lineLimit(1)
        )
        try assertPixelsEqual(actual, expected, context: "Only the bar should disappear from the resume chip.")
        XCTAssertNotEqual(actual.pngData(), try render(pill.environment(\.plozzShowsProgressBars, true)).pngData())
        let playerBar = ResumeProgressCapsule(progress: 0.25, onLight: false, width: 54, height: 5)
        try assertPixelsEqual(
            render(playerBar.environment(\.plozzShowsProgressBars, false)),
            render(playerBar.environment(\.plozzShowsProgressBars, true)),
            context: "The shared player/download bar primitive must not observe card visibility."
        )
    }

    private func row(
        _ contents: Contents, label: String, metrics: PlozzMetrics, spacing: CGFloat
    ) -> some View {
        HStack(spacing: spacing) {
            if contents == .full { Image(systemName: "play.fill") }
            if contents == .full || contents == .progressAndText {
                ResumeProgressCapsule(
                    progress: 0.25, onLight: false,
                    width: metrics.resumeChipBarWidth, height: metrics.resumeChipBarHeight
                )
            }
            Text(verbatim: label)
                .lineLimit(contents == .smallerText ? nil : 1)
                .fixedSize(horizontal: contents != .smallerText, vertical: true)
        }
        .font(.system(
            size: metrics.resumeChipFontSize * (contents == .smallerText ? 0.85 : 1), weight: .semibold
        ))
        .foregroundStyle(.white)
    }

    private func render(_ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(content: view.environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func assertPixelsEqual(_ actual: UIImage, _ expected: UIImage, context: String) throws {
        func pixels(_ image: UIImage) throws -> [UInt8] {
            let cg = try XCTUnwrap(image.cgImage)
            let buffer = try XCTUnwrap(CGContext(
                data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            buffer.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return Array(UnsafeBufferPointer(
                start: try XCTUnwrap(buffer.data).assumingMemoryBound(to: UInt8.self),
                count: cg.width * cg.height * 4
            ))
        }
        XCTAssertEqual(actual.size, expected.size, context)
        let actualPixels = try pixels(actual), expectedPixels = try pixels(expected)
        let difference = zip(actualPixels, expectedPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
        XCTAssertLessThanOrEqual(difference / Double(actualPixels.count), 0.1, context)
    }

    private func recognizedText(_ image: UIImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
