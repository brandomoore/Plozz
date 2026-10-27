#if os(iOS)
import CoreModels
import CoreImage
@testable import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class VersionPickerPresentationTests: XCTestCase {
    private var versions: [MediaVersion] {
        [
            MediaVersion(
                id: "remux",
                fileName: "https://media.example/stream?filename=Movie.Extended.2160p.REMUX.HEVC.TrueHD-GROUP.mkv&id=tt123&media_type=movie",
                edition: "Extended", height: 2160, bitrate: 80_000_000, sizeBytes: 42_000_000_000,
                duration: 7_200, videoCodec: "hevc", videoRange: "SDR", audioCodec: "truehd", audioChannels: 8,
                sourceMetadata: .init(
                    video: .init(codec: "hevc", width: 3840, height: 2160, bitDepth: 10, videoRange: "SDR"),
                    audioLanguages: ["fra", "deu", "spa", "eng", "ita", "por", "jpn", "kor", "zho", "ara", "en"]
                )
            ),
            MediaVersion(id: "current", name: "Current HDR copy", height: 1080, videoRange: "HDR10")
        ]
    }

    func testDetailPopoverKeepsVersionFactsReadableOnPhoneAndPad() async throws {
        for (width, typeSize) in [(320.0, DynamicTypeSize.large), (768.0, .large), (390.0, .accessibility2)] {
            try await assertFacts(
                PlozziOSVersionPickerPopover(versions: versions, selectedVersionID: "remux", onSelectVersion: { _ in }),
                width: width, typeSize: typeSize, name: "version-detail"
            )
        }
    }

    func testPlayerAndSDRSheetsUseTheSameRichVersionFacts() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, versions: versions)
        for onlySDR in [false, true] {
            for width in [320.0, 768.0] {
                try await assertFacts(
                    PlozziOSPlayerVersionSheet(item: item, mediaSourceID: "current", onlySDR: onlySDR, onSelect: { _ in }),
                    width: width, typeSize: .large, name: onlySDR ? "version-player-sdr" : "version-player",
                    expectedTitle: onlySDR ? "SDR versions" : "Version"
                )
            }
        }
    }

    func testContextMenuPickerUsesTheSameVersionCards() async throws {
        try await assertFacts(
            MediaVersionPicker(versions: versions, selectedVersionID: "remux", onSelect: { _ in }),
            width: 390, typeSize: .large, name: "version-context", expectedTitle: "Version"
        )
    }

    func testExplicitAudioPreferenceChangesTheCompactLanguageWithoutInventingTracks() async throws {
        try await assertFacts(
            MediaVersionPicker(versions: versions, selectedVersionID: "remux", onSelect: { _ in }),
            width: 390, typeSize: .large, name: "version-french-preference",
            preferredLanguage: "fra", visibleLanguage: "French", hiddenLanguage: "English"
        )
    }

    func testCompactVersionDisclosureKeepsFactsLeadingAndUntruncated() async throws {
        let version = MediaVersion(
            id: "imax", name: "Movie.IMAX.2160p.WEB-DL", edition: "IMAX",
            height: 2160, sizeBytes: 87_800_000_000, videoRange: "DOVI"
        )
        for (width, typeSize) in [
            (320.0, DynamicTypeSize.large), (390.0, .large), (768.0, .large),
            (320.0, .accessibility3), (390.0, .accessibility3)
        ] {
            try await assertCompactSummary(
                version, expectedFacts: ["IMAX", "4K", "Dolby Vision", "WEB-DL", "87.8 GB"],
                width: width, typeSize: typeSize
            )
        }
        try await assertCompactSummary(
            version, expectedFacts: ["IMAX", "4K", "Dolby Vision", "WEB-DL", "87.8 GB"],
            width: 390, typeSize: .large, direction: .rightToLeft
        )
    }

    func testTwoLanguagesExpandWhenBadgeRowWraps() throws {
        let version = MediaVersion(
            id: "bilingual", fileName: "Episode.2160p.mkv",
            height: 2160, videoCodec: "hevc", videoRange: "DOVI",
            audioCodec: "truehd", audioChannels: 6,
            sourceMetadata: .init(
                video: .init(codec: "hevc", height: 2160, videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "truehd", profile: "Dolby Atmos", channels: 6),
                audioLanguages: ["eng", "fra"]
            )
        )
        for (width, typeSize, expands) in [
            (280.0, DynamicTypeSize.large, true),
            (800.0, .large, false),
            (320.0, .accessibility3, true)
        ] {
            for selected in [false, true] {
                let renderer = ImageRenderer(content: MediaVersionChoiceButton(
                    presentation: .init(version, locale: Locale(identifier: "en_US")),
                    isSelected: selected, action: {}
                )
                .frame(width: width)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.versionPickerAudioLanguage, "eng")
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark)
                .padding(16)
                .background(.black))
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                let attachment = XCTAttachment(image: image)
                attachment.name = "bilingual-\(Int(width))-\(typeSize)-selected-\(selected)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.001
                let cgImage = try XCTUnwrap(image.cgImage)
                var recognized: [String] = []
                // Wide captures downsample small labels; overlapping strips keep whole words readable.
                for x in stride(from: 0, to: cgImage.width, by: 512) {
                    let region = CGRect(
                        x: x, y: 0, width: min(1_024, cgImage.width - x), height: cgImage.height
                    )
                    let strip = try XCTUnwrap(cgImage.cropping(to: region))
                    try VNImageRequestHandler(cgImage: strip).perform([request])
                    recognized += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                }
                let text = recognized.joined(separator: " ").uppercased()
                let context = "\(width)/\(typeSize)/selected:\(selected): \(text)"
                XCTAssertTrue(text.contains("ENGLISH"), context)
                XCTAssertEqual(text.contains("FRENCH"), expands, context)
                XCTAssertEqual(text.contains("+1"), !expands, context)
            }
        }
    }

    func testCompactVersionDisclosurePreservesLongProviderNameFallback() async throws {
        try await assertCompactSummary(
            MediaVersion(id: "archive", name: "Festival archive presentation with restored opening credits"),
            expectedFacts: ["Festival", "archive", "presentation", "with", "restored", "opening", "credits"],
            width: 320, typeSize: .accessibility2
        )
    }

    private func assertCompactSummary(
        _ version: MediaVersion, expectedFacts: [String], width: CGFloat, typeSize: DynamicTypeSize,
        direction: LayoutDirection = .leftToRight
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
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
        window.overrideUserInterfaceStyle = .dark
        let panel = PlaybackSourceMenuPanel(
            page: .constant(.root), maxHeight: 880,
            sources: [], selectedSourceID: nil,
            versions: [version, .init(id: "other", height: 1080)], selectedVersionID: version.id,
            actions: [], onSelectSource: { _ in }, onSelectVersion: { _ in }, onPerformAction: { _ in }
        )
        window.rootViewController = UIHostingController(rootView: panel
            .frame(width: min(390, width - 32))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .multilineTextAlignment(.center)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.layoutDirection, direction)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(scrollView(in: window))
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1,
                                 "These compact summaries should fit without hidden rows.")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "version-summary-\(version.id)-\(Int(width))-\(typeSize)-\(direction)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.001
        request.customWords = ["IMAX", "4K", "Dolby Vision", "WEB-DL"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let lines = (request.results ?? []).compactMap { result -> (String, CGRect)? in
            result.topCandidates(1).first.map { ($0.string, result.boundingBox) }
        }
        let visible = lines.map(\.0).joined(separator: "\n")
        // Native text can hyphenate a word at a line boundary. Do not remove
        // in-line hyphens from source facts such as WEB-DL.
        let unhyphenated = visible.replacingOccurrences(
            of: "(?<=\\p{L})-\\s*\\n\\s*(?=\\p{L})", with: "", options: .regularExpression
        )
        let compactVisible = unhyphenated.filter { !$0.isWhitespace }
        let compactOriginal = visible.filter { !$0.isWhitespace }
        for fact in expectedFacts {
            let expected = fact.filter { !$0.isWhitespace }
            XCTAssertTrue(compactVisible.localizedCaseInsensitiveContains(expected)
                          || compactOriginal.localizedCaseInsensitiveContains(expected),
                          "Missing compact fact \(fact) at \(width)/\(typeSize): \(visible)")
        }
        let heading = try XCTUnwrap(try (request.results ?? []).compactMap { result -> CGRect? in
            guard let candidate = result.topCandidates(1).first,
                  let range = candidate.string.range(of: "VERSION", options: .caseInsensitive) else { return nil }
            return try candidate.boundingBox(for: range)?.boundingBox
        }.first, "The category must remain intact, including beside its accessibility-layout chevron: \(visible)")
        let factWords = expectedFacts.flatMap { $0.split(separator: " ").map(String.init) }
        let factLines = try (request.results ?? []).compactMap { result -> (String, CGRect)? in
            guard let candidate = result.topCandidates(1).first else { return nil }
            let ranges = factWords.compactMap { candidate.string.range(of: $0, options: .caseInsensitive) }
            guard let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() else {
                return nil
            }
            // Vision can group the neighboring film icon into the same recognized line.
            let bounds = try XCTUnwrap(candidate.boundingBox(for: start..<end)).boundingBox
            return (candidate.string, bounds)
        }
        for (text, bounds) in factLines {
            let expected = direction == .leftToRight ? heading.minX : heading.maxX
            let actual = direction == .leftToRight ? bounds.minX : bounds.maxX
            let inwardOffset = (actual - expected) * width * (direction == .leftToRight ? 1 : -1)
            // Large glyphs can expand Vision's leading box into the empty margin.
            // Keep the inward limit strict so centered shorter lines still fail.
            let outwardTolerance: CGFloat = typeSize.isAccessibilitySize ? 10 : 5
            XCTAssertGreaterThanOrEqual(inwardOffset, -outwardTolerance,
                                        "Unexpected outward OCR bound for \(text) at \(width)/\(typeSize)/\(direction)")
            XCTAssertLessThanOrEqual(inwardOffset, 5,
                                     "Each fact line should follow the heading's leading edge: \(text) at \(width)/\(typeSize)/\(direction)")
            XCTAssertFalse(text.hasPrefix("·") || text.hasSuffix("·") || text.contains("…"),
                           "Compact facts must not leave orphan separators or truncate: \(text)")
        }
    }

    private func assertFacts<Content: View>(
        _ content: Content, width: CGFloat, typeSize: DynamicTypeSize, name: String,
        preferredLanguage: String = "en", visibleLanguage: String = "English", hiddenLanguage: String = "French",
        expectedTitle: String? = nil
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
        window.frame = CGRect(x: 0, y: 0, width: width, height: width >= 768 ? 1024 : 844)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: content
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.versionPickerAudioLanguage, preferredLanguage)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.horizontalSizeClass, width >= 768 ? .regular : .compact)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.bounds.width, width, accuracy: 0.5)
        if let expectedTitle {
            let bar = try XCTUnwrap(navigationBar(in: window))
            let item = try XCTUnwrap(bar.topItem)
            XCTAssertEqual(item.title, expectedTitle)
            XCTAssertLessThanOrEqual(bar.bounds.height, 64)
            let buttons = (item.leftBarButtonItems ?? []) + item.leadingItemGroups.flatMap(\.barButtonItems)
            XCTAssertEqual(buttons.count, 1)
            XCTAssertNotNil(buttons.first?.image)
            XCTAssertTrue((item.rightBarButtonItems ?? []).isEmpty && item.trailingItemGroups.isEmpty,
                          "The leading X replaces Done.")
        }
        let scroll = try XCTUnwrap(scrollView(in: window))
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        var visible = ""
        var observedBadgeFooter = false
        for (index, offset) in stride(from: top, through: bottom + scroll.bounds.height / 2, by: scroll.bounds.height / 2).enumerated() {
            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, bottom)), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(name)-\(Int(width))-\(typeSize)-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.001
            request.customWords = ["4K", "HEVC", "Mbps", "TrueHD"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let results = request.results ?? []
            visible += " " + results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if let filename = results.first(where: {
                $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains("GROUP.mkv") == true
            }), let language = results.first(where: {
                $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(visibleLanguage) == true
            }) {
                XCTAssertLessThan(language.boundingBox.midY, filename.boundingBox.midY,
                                  "Language badges must sit below the release filename.")
                observedBadgeFooter = true
            }
            let inverted = CIImage(cgImage: try XCTUnwrap(image.cgImage)).applyingFilter("CIColorInvert")
            let invertedImage = try XCTUnwrap(CIContext().createCGImage(inverted, from: inverted.extent))
            try VNImageRequestHandler(cgImage: invertedImage).perform([request])
            visible += " " + (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if offset >= bottom { break }
        }
        for fact in ["Extended", "4K", "42 GB", visibleLanguage, "+9", "HEVC", "TrueHD", "80 Mbps", "2h", "GROUP.mkv"] {
            XCTAssertTrue(visible.localizedCaseInsensitiveContains(fact), "Missing \(fact) in \(name) at \(width): \(visible)")
        }
        XCTAssertTrue(observedBadgeFooter, "The version card's filename and badge footer must remain visible together.")
        XCTAssertFalse(visible.contains("filename="))
        XCTAssertFalse(visible.contains("media_type"))
        XCTAssertFalse(visible.contains(hiddenLanguage), "Additional languages belong behind the compact count, not ten chips.")
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func navigationBar(in view: UIView) -> UINavigationBar? {
        (view as? UINavigationBar) ?? view.subviews.lazy.compactMap { self.navigationBar(in: $0) }.first
    }
}
#endif
