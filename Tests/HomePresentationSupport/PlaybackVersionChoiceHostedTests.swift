import CoreModels
import CoreImage
@testable import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlaybackVersionChoiceHostedTests: XCTestCase {
    func testSourceMenuOnlyDiscoversInventoryAfterOpeningItsVersionPage() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let menu = PlaybackSourceMenuState()
        let probe = VersionChoiceHostedProbe()
        let loader = MediaVersionInventoryLoader(id: "explicit-inventory") {
            probe.inventoryRequests += 1
            return [.init(id: "hd", fileName: "Discovered.First.mkv", height: 1080),
                    .init(id: "uhd", fileName: "Discovered.Second.mkv", height: 2160)]
        }
        let window = UIWindow(windowScene: scene)
        #if os(tvOS)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #else
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        #endif
        window.rootViewController = UIHostingController(rootView:
            Color.black.ignoresSafeArea()
                .playbackSourceMenu(
                    state: menu, sources: [], selectedSourceID: "account",
                    versions: [], selectedVersionID: nil, loadVersions: loader,
                    onSelectSource: { _ in XCTFail("Inventory does not select a server.") },
                    onSelectVersion: { _ in XCTFail("Inventory does not select or play a file.") }
                )
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.makeKeyAndVisible()
        defer {
            menu.isPresented = false
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        menu.open(from: CGRect(x: 100, y: 100, width: 80, height: 48))
        try await waitUntil { window.rootViewController?.presentedViewController != nil }
        let root = try await visibleText(in: window, name: "inventory-root")
        XCTAssertTrue(root.localizedCaseInsensitiveContains("version"), "Lazy sources remain discoverable.")
        XCTAssertEqual(probe.inventoryRequests, 0, "Opening/focusing overflow must remain metadata-only.")
        menu.page = .versions
        try await waitUntil { probe.inventoryRequests == 1 }
        let versions = try await visibleText(in: window, name: "inventory-discovered")
        XCTAssertTrue(versions.contains("1080"), "The previously unknown file must reach the native picker.")
        menu.page = .root
        _ = try await visibleText(in: window, name: "inventory-back")
        XCTAssertEqual(probe.inventoryRequests, 1, "Returning to the menu root must not repeat discovery.")
    }

    func testIntroductionHandsOffToNativeVersionChoicesWithoutStartingPlayback() async throws {
        #if os(tvOS)
        let layouts: [(CGFloat, DynamicTypeSize)] = [(1920, .large)]
        #else
        let layouts: [(CGFloat, DynamicTypeSize)] = [(320, .large), (768, .large), (390, .accessibility2)]
        #endif
        for (width, typeSize) in layouts {
            try await exercise(width: width, typeSize: typeSize)
        }
    }

    func testAutomaticIntroductionStartsPlaybackWithoutShowingVersionChoices() async throws {
        #if os(tvOS)
        try await exercise(width: 1920, typeSize: .large, automaticAtIntroduction: true)
        #else
        try await exercise(width: 390, typeSize: .large, automaticAtIntroduction: true)
        #endif
    }

    #if os(tvOS)
    func testLongVersionListStaysBoundedWithReducedTransparencyAndLargerText() async throws {
        try await exercise(width: 1920, typeSize: .accessibility1, versionCount: 12, reduceTransparency: true)
    }
    #else
    func testLongVersionCardsStayReadableInLightAppearance() async throws {
        try await exercise(width: 390, typeSize: .large, versionCount: 8, colorScheme: .light)
    }

    func testLeadingCloseCancelsWithoutSelectingOrStartingPlayback() async throws {
        try await exercise(width: 390, typeSize: .large, closeInsteadOfSelect: true)
    }

    func testFilenameBreaksAvoidWastedLinesWithoutCappingContent() {
        let filename = "Spider-Man.Brand.New.Day.2026.IMAX.MULTI.VF2.2160p.CORE.WEB-DL.DV.HDR10+.DDP.Atmos.5.1.HEVC-HYPERION.mkv"
        func height(_ text: String, width: CGFloat) -> CGFloat {
            let host = UIHostingController(rootView:
                Text(verbatim: text).font(.caption2)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .environment(\.dynamicTypeSize, .large)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            return host.sizeThatFits(in: CGSize(width: width, height: 1_000)).height
        }
        let wrapped = MediaSourceDisplayName.wrappingFileName(filename)
        for (width, lines): (CGFloat, Int) in [(330, 3), (390, 2)] {
            let reference = Array(repeating: "Full line", count: lines).joined(separator: "\n")
            XCTAssertEqual(height(wrapped, width: width), height(reference, width: width), accuracy: 1)
            XCTAssertLessThanOrEqual(height(wrapped, width: width), height(filename, width: width))
        }
        let measurements = stride(from: CGFloat(280), through: 440, by: 10).map { width in
            (width: width, original: height(filename, width: width), wrapped: height(wrapped, width: width))
        }
        let evidence = measurements.map { "\($0.width)pt: original=\($0.original), wrapped=\($0.wrapped)" }
            .joined(separator: "\n")
        let attachment = XCTAttachment(string: evidence)
        attachment.lifetime = .keepAlways
        add(attachment)
        for measurement in measurements {
            XCTAssertLessThanOrEqual(measurement.wrapped, measurement.original, evidence)
        }
        XCTAssertTrue(measurements.contains { $0.wrapped < $0.original }, evidence)
    }
    #endif

    func testInternationalReleaseNamesWrapWithoutTruncation() async throws {
        #if os(tvOS)
        let layouts: [(CGFloat, DynamicTypeSize)] = [(720, .large), (1_100, .accessibility1)]
        #else
        let layouts: [(CGFloat, DynamicTypeSize)] = [(320, .accessibility2), (768, .large)]
        #endif
        let names: [(String, String, LayoutDirection)] = [
            ("Example.Brand.New.Day.Special.Edition.", "en_US", .leftToRight),
            ("Le.Fabuleux.Destin.d’Amélie.Édition.spéciale.", "fr_FR", .leftToRight),
            ("千と千尋の神隠し.特別版.日本語.", "ja_JP", .leftToRight),
            ("رحلة.إلى.القمر.نسخة.خاصة.", "ar", .rightToLeft)
        ]
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for (width, typeSize) in layouts {
            for (prefix, localeID, direction) in names {
                let filename = String(repeating: prefix, count: 12) + "2160p.WEB-DL.HEVC-GROUP.mkv"
                let locale = Locale(identifier: localeID)
                let presentation = MediaVersion.PickerPresentation(.init(
                    id: "international", fileName: filename, height: 2160,
                    sourceMetadata: .init(audioLanguages: ["eng", "fra"])
                ), locale: locale)
                XCTAssertEqual(presentation.releaseName, filename)
                let contentWidth = width - 32
                let reference = UIHostingController(rootView:
                    Text(verbatim: MediaSourceDisplayName.wrappingFileName(filename)).font(.caption2)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .environment(\.dynamicTypeSize, typeSize)
                        .environment(\.locale, locale)
                        .environment(\.layoutDirection, direction)
                )
                let fullTextHeight = reference.sizeThatFits(in: CGSize(width: contentWidth, height: 10_000)).height
                let card = MediaVersionChoiceButton(presentation: presentation, isFocused: true) {}
                    .environment(\.dynamicTypeSize, typeSize)
                    .environment(\.locale, locale)
                    .environment(\.layoutDirection, direction)
                    .environment(\.versionPickerAudioLanguage, "en")
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                let sizingHost = UIHostingController(rootView: card)
                let size = sizingHost.sizeThatFits(in: CGSize(width: contentWidth, height: 10_000))
                XCTAssertGreaterThanOrEqual(size.height, fullTextHeight,
                                            "The card must accommodate every filename line for \(localeID), not truncate it.")
                XCTAssertLessThanOrEqual(size.width, contentWidth + 1)

                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: width >= 720 ? 1080 : 844)
                window.overrideUserInterfaceStyle = .dark
                window.rootViewController = UIHostingController(rootView:
                    ScrollView { card.padding(16) }.background(.black)
                )
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                window.layoutIfNeeded()
                let scroll = try XCTUnwrap(scrollViews(in: window).first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                _ = try await visibleText(
                    in: window, name: "version-filename-\(localeID)-\(Int(width))", screenshotsOnly: true
                )
            }
        }
    }

    private func exercise(
        width: CGFloat, typeSize: DynamicTypeSize, versionCount: Int = 2, reduceTransparency: Bool = false,
        colorScheme: ColorScheme = .dark, closeInsteadOfSelect: Bool = false,
        automaticAtIntroduction: Bool = false
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "version-choice-hosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let probe = VersionChoiceHostedProbe()
        let settings = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        let preferences = VersionPreferenceStore(defaults: defaults)
        let model = PlaybackVersionChoiceModel()
        var versions: [MediaVersion] = [
            .init(id: "4k", fileName: "Example.Movie.2026.MULTi.2160p.Dolby.Vision.TrueHD.Atmos.REMUX-GROUP.mkv",
                  height: 2160, sizeBytes: 42_000_000_000,
                  duration: 7_200, videoCodec: "hevc", videoRange: "HDR10",
                  audioCodec: "truehd", sourceMetadata: .init(
                      video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
                      audio: .init(codec: "truehd", profile: "Atmos"),
                      audioLanguages: ["eng", "fra"]
                  )),
            .init(id: "1080", height: 1080, videoRange: "SDR")
        ]
        for index in 2..<versionCount {
            versions.append(.init(id: "extra-\(index)", fileName: "Alternative-\(index).mkv", height: 1080))
        }
        let item = MediaItem(id: "movie", title: "Version fixture", kind: .movie, versions: versions)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: width >= 768 ? 1080 : 844)
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView:
            VersionChoiceHostedFixture(
                model: model, probe: probe, item: item, settings: settings, preferences: preferences
            )
            .environment(\.themePalette, colorScheme == .dark ? .dark : .light)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.versionPickerAudioLanguage, "en")
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.plozzReduceTransparency, reduceTransparency)
        )
        window.makeKeyAndVisible()
        defer {
            model.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await waitUntil { model.prompt != nil }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        XCTAssertFalse(probe.disappeared, "Presenting the prompt must not disappear/cancel its playback owner.")
        XCTAssertNil(probe.selected)
        XCTAssertNil(probe.error)
        let introduction = try await visibleText(in: window, name: "version-introduction-\(Int(width))-\(typeSize)")
        for label in ["choose a version every time", "Ask every time", "Choose automatically", "Settings"] {
            XCTAssertTrue(introduction.localizedCaseInsensitiveContains(label), "Missing \(label): \(introduction)")
        }
        XCTAssertFalse(introduction.contains("Remember"), "Remembering is a separate default-on setting, not a first-use choice.")
        #if os(tvOS)
        XCTAssertTrue(introduction.contains("Cancel"))
        XCTAssertNotNil(UIFocusSystem(for: window)?.focusedItem, "An introduction action must own native focus.")
        try assertCompactCard(in: window, maximumHeight: typeSize.isAccessibilitySize ? 860 : 800)
        #else
        XCTAssertFalse(introduction.contains("Cancel"), "The leading X replaces the bottom Cancel button.")
        _ = try assertCloseToolbar(in: window)
        #endif
        let id = try XCTUnwrap(model.prompt?.id)
        if automaticAtIntroduction {
            model.chooseMode(.automatic, promptID: id)
            XCTAssertNil(model.prompt)
            try await waitUntil { probe.selected != nil }
            XCTAssertNil(probe.error)
            XCTAssertFalse(probe.disappeared)
            XCTAssertTrue(settings.settings.rememberVersionPerSeries)
            XCTAssertEqual(settings.settings.versionSelectionMode, .automatic)
            XCTAssertNil(preferences.preferredVersionID(forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item)))
            return
        }
        model.chooseMode(.askEveryTime, promptID: id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(probe.selected, "Choosing the mode alone must not select a file.")
        XCTAssertFalse(try XCTUnwrap(model.prompt).needsIntroduction)
        #if os(tvOS)
        if typeSize == .large, versionCount == 2 {
            try await assertVersionTypography(in: window)
        }
        #endif
        let choices = try await visibleText(in: window, name: "version-choice-\(Int(width))-\(typeSize)")
        for fact in ["Choose a version", "4K", "42 GB", "English", "HEVC", "TrueHD"] {
            XCTAssertTrue(choices.localizedCaseInsensitiveContains(fact), "Missing \(fact): \(choices)")
        }
        XCTAssertTrue(
            choices.contains("+1") || choices.localizedCaseInsensitiveContains("French"),
            "The second language must remain visible, abbreviated on one line or expanded after wrapping: \(choices)"
        )
        #if os(tvOS)
        XCTAssertNotNil(UIFocusSystem(for: window)?.focusedItem, "The version picker must receive native focus.")
        try assertCompactCard(in: window, maximumHeight: versionCount > 2 ? 860 : 600)
        if versionCount > 2 {
            let scroll = try XCTUnwrap(scrollViews(in: window).first { $0.contentSize.height > $0.bounds.height + 1 })
            XCTAssertGreaterThan(scroll.contentOffset.y, 0, "The long list must actually scroll.")
            let lastFile = try XCTUnwrap(model.prompt?.versions.last?.fileName)
            XCTAssertTrue(choices.contains(lastFile), "The final version must remain reachable.")
        }
        #else
        XCTAssertFalse(choices.contains("Cancel"), "The picker must not retain a second bottom dismissal action.")
        let close = try assertCloseToolbar(in: window)
        if closeInsteadOfSelect {
            let action = try XCTUnwrap(close.action)
            XCTAssertTrue(UIApplication.shared.sendAction(action, to: close.target, from: close, for: nil))
            try await waitUntil { !model.isPreparing }
            XCTAssertNil(model.prompt)
            XCTAssertNil(probe.selected)
            XCTAssertFalse(probe.disappeared)
            return
        }
        #endif
        model.chooseVersion("4k", promptID: id)
        try await waitUntil { probe.selected != nil }
        XCTAssertEqual(probe.selected?.selectedVersionID, "4k")
        XCTAssertEqual(settings.settings.versionSelectionMode, .askEveryTime)
        XCTAssertFalse(probe.disappeared)
        XCTAssertNil(probe.error)
    }

    #if os(iOS)
    private func assertCloseToolbar(in window: UIWindow) throws -> UIBarButtonItem {
        func navigationBar(in view: UIView) -> UINavigationBar? {
            (view as? UINavigationBar) ?? view.subviews.lazy.compactMap { navigationBar(in: $0) }.first
        }
        func titleLabel(in view: UIView) -> UILabel? {
            if let label = view as? UILabel, label.text == "Choose a version" { return label }
            return view.subviews.lazy.compactMap { titleLabel(in: $0) }.first
        }
        let bar = try XCTUnwrap(navigationBar(in: window))
        let item = try XCTUnwrap(bar.topItem)
        XCTAssertEqual(item.title, "Choose a version")
        XCTAssertLessThanOrEqual(bar.bounds.height, 64, "The title must use the inline navigation bar.")
        let label = try XCTUnwrap(titleLabel(in: bar))
        XCTAssertEqual(label.convert(label.bounds, to: bar).midX, bar.bounds.midX, accuracy: 2)
        let buttons = (item.leftBarButtonItems ?? []) + item.leadingItemGroups.flatMap(\.barButtonItems)
        XCTAssertEqual(buttons.count, 1, "The X must be the single leading toolbar action.")
        XCTAssertTrue((item.rightBarButtonItems ?? []).isEmpty && item.trailingItemGroups.isEmpty)
        let close = try XCTUnwrap(buttons.first)
        XCTAssertNotNil(close.image, "The close action must show an icon rather than a text button.")
        return close
    }
    #endif

    #if os(tvOS)
    private func assertVersionTypography(in window: UIWindow) async throws {
        var previousImage: Data?
        var settledImage: UIImage?
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let bytes = try XCTUnwrap(image.pngData())
            if bytes == previousImage {
                settledImage = image
                break
            }
            previousImage = bytes
        }
        let image = try XCTUnwrap(settledImage, "Native focus must settle before measuring badge typography.")
        let attachment = XCTAttachment(image: image)
        attachment.name = "TV version picker typography"
        attachment.lifetime = .keepAlways
        add(attachment)

        let cgImage = try XCTUnwrap(image.cgImage)
        let inverted = CIImage(cgImage: cgImage).applyingFilter("CIColorInvert")
        let invertedImage = try XCTUnwrap(CIContext().createCGImage(inverted, from: inverted.extent))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.001
        request.customWords = ["4K", "1080P", "HEVC", "SDR", "HDR10"]
        // HDR10 shares the range typography without the short DV label's OCR ambiguity.
        let minimumHeights: [String: CGFloat] = [
            "Choose a version": 20, "4K": 12, "1080P": 12,
            "HEVC": 12, "English": 12, "SDR": 12, "HDR10": 12
        ]
        var heights: [String: CGFloat] = [:]
        func measure(_ recognitionImage: CGImage, pointHeight: CGFloat) throws -> [VNRecognizedTextObservation] {
            try VNImageRequestHandler(cgImage: recognitionImage).perform([request])
            let observations = request.results ?? []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                for label in minimumHeights.keys {
                    guard let range = candidate.string.range(of: label, options: .caseInsensitive),
                          let box = try candidate.boundingBox(for: range) else { continue }
                    let height = box.boundingBox.height * pointHeight
                    heights[label] = min(heights[label] ?? height, height)
                }
            }
            return observations
        }
        for recognitionImage in [cgImage, invertedImage] {
            let observations = try measure(recognitionImage, pointHeight: image.size.height)
            // Whole-screen OCR downsamples compact labels. Preserve point units in cropped passes.
            // A merged badge row's box can be taller than the compact glyphs it contains.
            for observation in observations {
                let box = observation.boundingBox
                let region = CGRect(
                    x: box.minX * CGFloat(cgImage.width),
                    y: (1 - box.maxY) * CGFloat(cgImage.height),
                    width: box.width * CGFloat(cgImage.width),
                    height: box.height * CGFloat(cgImage.height)
                ).insetBy(dx: -8, dy: -8).intersection(
                    CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
                )
                let crop = try XCTUnwrap(recognitionImage.cropping(to: region))
                let enlarged = CIImage(cgImage: crop).applyingFilter(
                    "CILanczosScaleTransform", parameters: [kCIInputScaleKey: 4]
                )
                let enlargedImage = try XCTUnwrap(CIContext().createCGImage(enlarged, from: enlarged.extent))
                _ = try measure(enlargedImage, pointHeight: CGFloat(crop.height) / image.scale)
            }
        }
        for (label, minimum) in minimumHeights {
            let height = try XCTUnwrap(heights[label], "Missing visible picker text: \(label)")
            XCTAssertGreaterThanOrEqual(height, minimum, "\(label) must be readable at TV viewing distance.")
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(heights["Choose a version"]), 40,
                                "The heading must remain a compact hint, not a large TV title.")
    }

    private func assertCompactCard(in window: UIWindow, maximumHeight: CGFloat) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func isSurface(x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return pixels[offset..<offset + 3].contains { $0 > 12 }
        }
        let horizontal = (0..<width).filter { isSurface(x: $0, y: height / 2) }
        let vertical = (0..<height).filter { isSurface(x: width / 2, y: $0) }
        let left = try XCTUnwrap(horizontal.first), right = try XCTUnwrap(horizontal.last)
        let top = try XCTUnwrap(vertical.first), bottom = try XCTUnwrap(vertical.last)
        let scale = image.scale
        XCTAssertLessThanOrEqual(CGFloat(right - left + 1) / scale, 1_104, "The card, not only its text, must be width-bounded.")
        XCTAssertLessThanOrEqual(CGFloat(bottom - top + 1) / scale, maximumHeight + 4, "Short content must not fill the screen.")
        XCTAssertEqual(CGFloat(left + right) / (2 * scale), window.bounds.midX, accuracy: 4)
        XCTAssertEqual(CGFloat(top + bottom) / (2 * scale), window.bounds.midY, accuracy: 4)
    }
    #endif

    private func visibleText(in window: UIWindow, name: String, screenshotsOnly: Bool = false) async throws -> String {
        var result = ""
        let scrolls = scrollViews(in: window).filter { !$0.isHidden && $0.window != nil }
        // Capture the initial layout and the bottom of each native scroll area,
        // including accessible text that does not fit a compact sheet at once.
        for index in 0...scrolls.count {
            if index > 0 {
                let scroll = scrolls[index - 1]
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                let bottom = max(-scroll.adjustedContentInset.top,
                                 scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(name)-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            // Geometry checks need these screenshots, not OCR of pathological
            // filenames whose rectification can exceed simulator texture limits.
            if screenshotsOnly { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.001
            request.customWords = ["4K", "HEVC", "Mbps", "TrueHD"]
            let cgImage = try XCTUnwrap(image.cgImage)
            let inverted = CIImage(cgImage: cgImage).applyingFilter("CIColorInvert")
            let invertedImage = try XCTUnwrap(CIContext().createCGImage(inverted, from: inverted.extent))
            // Vision can omit small white-on-black resolution chips in a whole-screen pass.
            for recognitionImage in [cgImage, invertedImage] {
                try VNImageRequestHandler(cgImage: recognitionImage).perform([request])
                let observations = request.results ?? []
                result += " " + observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                // Tiny badge lettering needs a cropped pass on both platforms, not a downsampled whole screen.
                for observation in observations where observation.boundingBox.height * image.size.height < 24 {
                    let box = observation.boundingBox
                    let rect = CGRect(
                        x: box.minX * CGFloat(cgImage.width),
                        y: (1 - box.maxY) * CGFloat(cgImage.height),
                        width: box.width * CGFloat(cgImage.width),
                        height: box.height * CGFloat(cgImage.height)
                    ).insetBy(dx: -8, dy: -8).intersection(
                        CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
                    )
                    var regions = [rect]
                    #if os(iOS)
                    // The isolated resolution pill may be omitted entirely. Include its actual badge row.
                    if observation.topCandidates(1).first?.string.contains("HEVC") == true {
                        for x in stride(from: CGFloat(0), to: CGFloat(cgImage.width), by: 160 * image.scale) {
                            regions.append(CGRect(
                                x: x, y: rect.minY, width: min(192 * image.scale, CGFloat(cgImage.width) - x),
                                height: rect.height
                            ))
                        }
                    }
                    #endif
                    for region in regions {
                        let crop = try XCTUnwrap(recognitionImage.cropping(to: region))
                        let enlarged = CIImage(cgImage: crop).applyingFilter(
                            "CILanczosScaleTransform", parameters: [kCIInputScaleKey: 4]
                        )
                        let enlargedImage = try XCTUnwrap(CIContext().createCGImage(enlarged, from: enlarged.extent))
                        try VNImageRequestHandler(cgImage: enlargedImage).perform([request])
                        result += " " + (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    }
                }
            }
        }
        return result
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "The native version-choice flow did not reach its expected state.")
    }
}

@MainActor @Observable
private final class VersionChoiceHostedProbe {
    var inventoryRequests = 0
    var selected: MediaItem?
    var disappeared = false
    var error: String?
}

private struct VersionChoiceHostedFixture: View {
    let model: PlaybackVersionChoiceModel
    let probe: VersionChoiceHostedProbe
    let item: MediaItem
    let settings: PlaybackSettingsModel
    let preferences: VersionPreferenceStore

    var body: some View {
        Color.black.ignoresSafeArea()
            .task {
                do {
                    probe.selected = try await model.prepare(
                        item, provider: VersionChoiceHostedProvider(resolvedItem: item),
                        settings: settings, preferences: preferences
                    )
                } catch is CancellationError {
                } catch {
                    probe.error = String(describing: error)
                }
            }
            .onDisappear {
                probe.disappeared = true
                model.cancel()
            }
            .playbackVersionChoice(model)
    }
}

private struct VersionChoiceHostedProvider: MediaProvider {
    let resolvedItem: MediaItem
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://example.invalid")!, provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard id == resolvedItem.id else { throw AppError.notFound }
        return resolvedItem
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        XCTFail("The version introduction must not resolve a playback stream.")
        throw AppError.notFound
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
