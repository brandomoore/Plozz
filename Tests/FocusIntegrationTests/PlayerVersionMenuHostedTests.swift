import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerVersionMenuHostedTests: XCTestCase {
    func testVersionFilenameQueriesRejectControlCharactersInOptimizedBuild() {
        XCTAssertEqual(
            MediaSourceDisplayName.fileName(from: "filename=Movie.Extended-GROUP.mkv"),
            "Movie.Extended-GROUP.mkv"
        )
        for encodedControl in ["%00", "%09", "%0A", "%0D", "%7F", "%C2%85", "%E2%80%8B"] {
            XCTAssertNil(
                MediaSourceDisplayName.fileName(from: "filename=Movie\(encodedControl)Name.mkv"),
                encodedControl
            )
        }
    }

    func testReturningFromScrolledVersionsRestoresVisibleRootAndNativeFocus() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let navigation = PlaybackSourceMenuState()
        let versions = (0..<12).map { index in
            MediaVersion(
                id: "version-\(index)",
                fileName: """
                UHD
                Example Movie (2026)
                WEB-DL HDR10+ Dolby Vision HEVC
                Atmos DDP 5.1
                English and French
                Release Group \(index)
                Ready
                """,
                height: 2160, bitrate: 26_700_000, sizeBytes: 25_400_000_000,
                duration: 7_620, videoCodec: "hevc", videoRange: "DOVIWithHDR10",
                audioCodec: "eac3", audioChannels: 6
            )
        }
        let host = UIHostingController(rootView:
            Color.black.ignoresSafeArea()
            .playbackSourceMenu(
                state: navigation, sources: [], selectedSourceID: nil,
                versions: versions, selectedVersionID: versions.sortedForPicker().last?.id,
                onSelectSource: { _ in }, onSelectVersion: { _ in }
            )
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        navigation.open(
            from: CGRect(x: 700, y: 950, width: 80, height: 80),
            actions: [.init(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise")]
        )
        try await waitUntil { host.presentedViewController != nil }
        for trigger in [
            CGRect(x: 700, y: 950, width: 80, height: 80),
            CGRect(x: 1_760, y: 120, width: 80, height: 80)
        ] {
            navigation.triggerFrame = trigger
            withAnimation(.easeInOut(duration: 0.28)) { navigation.page = .versions }
            try await waitUntil {
                (self.focusFrame(in: window)?.width ?? 0) > 500
                    && self.scrollViews(in: window).contains { $0.contentSize.height > $0.bounds.height * 2 }
            }
            let scroll = try XCTUnwrap(scrollViews(in: window).first)
            try await waitUntil { scroll.contentOffset.y > 1_000 }
            XCTAssertGreaterThan(scroll.contentOffset.y, 1_000, "Exercise a genuinely scrolled version list.")
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            let versionsImage = DetailTransitionSnapshot.image(of: window)
            let panelFrame = try renderedPanelFrame(in: versionsImage)
            XCTAssertEqual(panelFrame.width, 800, accuracy: 2)
            XCTAssertEqual(panelFrame.height, 820, accuracy: 2)
            XCTAssertTrue(window.bounds.insetBy(dx: 31, dy: 31).contains(panelFrame))
            let versionsAttachment = XCTAttachment(image: versionsImage)
            versionsAttachment.name = "TV expanded multiline versions"
            versionsAttachment.lifetime = .keepAlways
            add(versionsAttachment)
            withAnimation(.easeInOut(duration: 0.28)) { navigation.page = .root }
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            let rootScroll = try XCTUnwrap(scrollViews(in: window).first)
            XCTAssertFalse(rootScroll === scroll, "Pages must not reuse the outgoing scroll container.")
            XCTAssertEqual(rootScroll.contentOffset.y, -rootScroll.adjustedContentInset.top, accuracy: 4,
                           "Returning to the short root menu must not retain the version list's scroll offset.")
            let focus = try XCTUnwrap(focusFrame(in: window))
            XCTAssertTrue(rootScroll.convert(rootScroll.bounds, to: window).intersects(focus),
                          "A visible root action must receive native focus after Back.")
            let image = DetailTransitionSnapshot.image(of: window)
            let attachment = XCTAttachment(image: image)
            attachment.name = "TV source menu after returning from scrolled versions"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            for label in ["Version", "Refresh"] {
                XCTAssertTrue(text.localizedCaseInsensitiveContains(label), "Blank root menu: \(text)")
            }
        }
    }

    private struct NoSystemAudio: SystemPlaybackAudioControlling {
        func read() -> SystemPlaybackAudioState { .init(values: [:]) }
        func setEnabled(_ enabled: Bool, for setting: SystemPlaybackAudioSetting) throws {
            XCTFail("Version tests must not change system audio.")
            throw SystemPlaybackAudio.Failure.unavailable
        }
    }

    func testDetailVersionPanelShowsTheSameRichFactsWithNativeFocus() async throws {
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
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let version = MediaVersion(
            id: "remux",
            fileName: "n?\nfilename=Movie.Extended.2160p.REMUX.HEVC.TrueHD-GROUP.mkv&id=tt123&media_type=movie",
            edition: "Extended", height: 2160, bitrate: 80_000_000, sizeBytes: 42_000_000_000,
            duration: 7_200, videoCodec: "hevc", audioCodec: "truehd", audioChannels: 8,
            sourceMetadata: .init(audioLanguages: ["eng", "fra"])
        )
        let panel = PlaybackSourceMenuPanel(
            page: .constant(.versions), sources: [], selectedSourceID: nil,
            versions: [version, .init(id: "other", height: 1080)], selectedVersionID: version.id,
            actions: [], onSelectSource: { _ in }, onSelectVersion: { _ in }, onPerformAction: { _ in }
        )
        XCTAssertEqual(MediaSourceDisplayName.fileName(from: version.fileName),
                       "Movie.Extended.2160p.REMUX.HEVC.TrueHD-GROUP.mkv")
        XCTAssertEqual(MediaVersion.PickerPresentation(version).releaseName,
                       "Movie.Extended.2160p.REMUX.HEVC.TrueHD-GROUP.mkv")
        window.rootViewController = UIHostingController(rootView:
            panel.environment(\.locale, Locale(identifier: "en_US"))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await waitUntil { (self.focusFrame(in: window)?.width ?? 0) > 500 }
        try await Task.sleep(for: .milliseconds(400))
        let image = DetailTransitionSnapshot.image(of: window)
        let request = textRequest()
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        for fact in ["Extended", "4K", "42 GB", "English", "+1", "HEVC", "TrueHD", "80 Mbps", "2h", "GROUP.mkv"] {
            XCTAssertTrue(visible.localizedCaseInsensitiveContains(fact), "Missing detail version fact \(fact): \(visible)")
        }
        XCTAssertFalse(visible.contains("filename="))
        XCTAssertFalse(visible.contains("media_type"))
        let title = try XCTUnwrap(request.results?.first { $0.topCandidates(1).first?.string.contains("Extended") == true })
        let center = CGPoint(x: title.boundingBox.midX * 1920, y: (1 - title.boundingBox.midY) * 1080)
        XCTAssertTrue(try XCTUnwrap(focusFrame(in: window)).contains(center))
        let attachment = XCTAttachment(image: image)
        attachment.name = "Apple TV detail version picker"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVersionControlReceivesNativeFocusAndTheMenuFocusesThePlayingVersion() async throws {
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
        defer {
            PlayerScreenshotHook.pendingPanel = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = PlayerControlsModel(systemAudio: SystemPlaybackAudio(backend: NoSystemAudio()))
        model.controlsVisible = true
        model.versions.options = [
            .init(version: .init(id: "1080", fileName: "Movie-1080.mkv", edition: "Theatrical", height: 1080), isSelected: false),
            .init(version: .init(
                id: "4k",
                fileName: "https://media.example/stream?file_name=Movie.Extended.2160p.REMUX.HEVC.TrueHD.Atmos-GROUP.mkv&id=tt123&media_type=movie",
                edition: "Extended", height: 2160, bitrate: 80_000_000, sizeBytes: 42_000_000_000,
                duration: 7_200, videoCodec: "hevc", audioCodec: "truehd", audioProfile: "Atmos",
                sourceMetadata: .init(audioLanguages: ["eng", "fra"])
            ), isSelected: true)
        ]
        model.versions.onSelect = { _ in }
        let host = UIHostingController(rootView: controls(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        model.controlBarVisible = true
        try await waitUntil {
            guard let frame = self.focusFrame(in: window) else { return false }
            return frame.midX > window.bounds.midX && frame.width < 200
        }
        XCTAssertEqual(model.trackControlCategories, [.version])
        model.controlBar.settled = true

        PlayerScreenshotHook.pendingPanel = .versions
        host.rootView = AnyView(controls(model).id(UUID()))
        window.layoutIfNeeded()
        try await waitUntil {
            (self.focusFrame(in: window)?.width ?? 0) > 500 && model.isPanelOpen
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(model.isPanelOpen)
        let image = DetailTransitionSnapshot.image(of: window)
        let text = textRequest()
        let pixels = try XCTUnwrap(image.cgImage)
        try VNImageRequestHandler(cgImage: pixels).perform([text])
        let focusedFrame = try XCTUnwrap(focusFrame(in: window))
        let crop = focusedFrame.applying(CGAffineTransform(scaleX: image.scale, y: image.scale)).integral
        let focusedPixels = try XCTUnwrap(pixels.cropping(to: crop))
        let focusedText = textRequest()
        // The full-frame OCR pass can miss small format text; keep the same pixels and scope a second pass.
        try VNImageRequestHandler(cgImage: focusedPixels).perform([focusedText])
        let visibleText = ((text.results ?? []) + (focusedText.results ?? []))
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        for fact in ["Extended", "4K", "42 GB", "English", "+1", "HEVC", "TrueHD", "Atmos", "80 Mbps", "2h", "GROUP.mkv"] {
            XCTAssertTrue(visibleText.localizedCaseInsensitiveContains(fact), "Missing version fact \(fact): \(visibleText)")
        }
        XCTAssertFalse(visibleText.contains("file_name="))
        XCTAssertFalse(visibleText.contains("media_type"))
        let selectedText = try XCTUnwrap(text.results?.first {
            $0.topCandidates(1).first?.string.contains("Extended") == true
        })
        let rect = selectedText.boundingBox
        let center = CGPoint(
            x: rect.midX * window.bounds.width,
            y: (1 - rect.midY) * window.bounds.height
        )
        XCTAssertTrue(try XCTUnwrap(focusFrame(in: window)).contains(center),
                      "Native focus must land on the playing Extended version, not the first row.")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Apple TV version menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func controls(_ model: PlayerControlsModel) -> AnyView {
        AnyView(PlayerControls(
            model: model, palette: .dark,
            actions: PlayerOptionsActions(), onExitToSurface: {}
        ).background(.black))
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func renderedPanelFrame(in snapshot: UIImage) throws -> CGRect {
        let image = try XCTUnwrap(snapshot.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, maxX = -1, minY = height, maxY = -1
        // The fixture is black outside the glass; ignore its faint outer shadow.
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if max(bytes[index], bytes[index + 1], bytes[index + 2]) > 16 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX)
        return CGRect(
            x: CGFloat(minX) / snapshot.scale, y: CGFloat(minY) / snapshot.scale,
            width: CGFloat(maxX - minX + 1) / snapshot.scale,
            height: CGFloat(maxY - minY + 1) / snapshot.scale
        )
    }

    private func textRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.001
        request.customWords = ["4K", "HEVC", "Mbps", "TrueHD"]
        return request
    }

    private func focusFrame(in window: UIWindow) -> CGRect? {
        guard let item = UIFocusSystem(for: window)?.focusedItem else { return nil }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }

            environment = current.parentFocusEnvironment
        }
        return nil
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native focus did not reach the requested player control or menu.", file: file, line: line)
    }
}
