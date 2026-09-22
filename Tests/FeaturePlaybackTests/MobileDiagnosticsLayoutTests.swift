#if os(iOS) && canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeaturePlayback

@MainActor
final class MobileDiagnosticsLayoutTests: XCTestCase {
    func testTranscodeInfoAndQualityUseMeasuredStreamInsteadOfOriginalBadges() throws {
        let details = PlaybackStreamDetails(metadata: .init(
            video: .init(codec: "h264", width: 426, height: 230, videoRangeType: "SDR"),
            audio: .init(codec: "aac", channels: 2)
        ), declaredBitrate: 500_000)
        let model = PlayerControlsModel()
        model.infoCard.headline = "Converted Movie"
        model.infoCard.overview = String(repeating: "A long synopsis about a movie with a converted stream. ", count: 8)
        model.infoCard.runtimeLabel = "2h 9m"
        model.infoCard.isTranscoding = true
        model.infoCard.badges = details.technicalBadges
        for width in [CGFloat(390), 844, 1920] {
            let metrics: PlayerCardMetrics = width == 1920 ? .tv : .resolved(forWidth: width, height: 844)
            let renderer = ImageRenderer(content:
                InfoAudioFixture(model: model)
                    .environment(\.playerCardMetrics, metrics)
                    .environment(\.mediaBadgeScale, metrics.badgeScale)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .frame(width: width)
                    .background(.black)
            )
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let text = try recognizedText(image)
            XCTAssertTrue(text.contains("Transcoding"), text)
            XCTAssertTrue(text.contains("426"), text)
            XCTAssertTrue(text.contains("230"), text)
            XCTAssertFalse(text.contains("4K"), text)
            XCTAssertFalse(text.contains("5.1"), text)
            XCTAssertFalse(text.contains("Source audio"), text)
            attach(image, name: "Measured Info \(Int(width))")
        }
        let quality = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 12) {
                CurrentStreamDetailsSection(details: details)
            }
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: 390)
            .padding(20)
            .background(.black)
            .foregroundStyle(.white)
        )
        quality.scale = 2
        let text = try recognizedText(try XCTUnwrap(quality.cgImage))
        XCTAssertTrue(text.contains("426"), text)
        XCTAssertTrue(text.contains("230"), text)
        XCTAssertTrue(text.contains("AAC"), text)
        XCTAssertFalse(text.contains("4K"), text)
    }

    func testDiagnosticsClearlySeparateCurrentStreamOriginalFileAndNetworkRate() throws {
        var diagnostics = PlaybackDiagnostics.base(from: .init(
            video: .init(codec: "h264", width: 426, height: 230, videoRangeType: "SDR"),
            audio: .init(codec: "aac", channels: 2)
        ), mode: .transcode)
        diagnostics.originalSource = .init(
            video: .init(codec: "hevc", width: 3840, height: 2076, videoRangeType: "HDR10Plus"),
            audio: .init(codec: "ac3", channels: 6)
        )
        diagnostics.indicatedBitrate = 500_000
        diagnostics.observedBitrate = 8_000_000
        let renderer = ImageRenderer(content:
            PlaybackDiagnosticsOverlay(diagnostics: diagnostics, presentation: .mobile)
                .mobileContent(width: 390)
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(width: 390)
                .fixedSize(horizontal: false, vertical: true)
                .background(.black)
        )
        renderer.scale = 2
        let text = try recognizedText(try XCTUnwrap(renderer.cgImage))
        for label in ["CURRENT VIDEO", "CURRENT AUDIO", "ORIGINAL FILE", "426", "230",
                      "AAC", "3840", "Declared stream bitrate", "Network throughput"] {
            XCTAssertTrue(text.contains(label), text)
        }
    }

    func testInfoKeepsAudioBadgeWithoutDuplicateTrackDescription() throws {
        let model = PlayerControlsModel()
        model.infoCard.headline = "Fixture Movie"
        model.infoCard.overview = "A movie with a single audio track."
        model.infoCard.badges = [.init("Dolby Digital", style: .dolby, detail: "5.1")]
        model.audioOptions = TrackMenuBuilder.audioOptions(tracks: [
            .init(id: 1, kind: .audio, displayTitle: "AC3 5.1 (Default)", codec: "ac3", channels: 6)
        ], selectedID: 1, preferred: [], locale: .init(identifier: "en_US"))
        let audioOptions = model.audioOptions
        XCTAssertFalse(model.hasAudioControls)
        for width in [CGFloat(390), 1024, 1920] {
            let metrics: PlayerCardMetrics = width == 1920 ? .tv : .resolved(forWidth: width, height: 844)
            let renderer = ImageRenderer(content:
                InfoAudioFixture(model: model)
                    .environment(\.playerCardMetrics, metrics)
                    .environment(\.mediaBadgeScale, metrics.badgeScale)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .frame(width: width)
                    .background(.black)
            )
            renderer.scale = 2
            model.audioOptions = audioOptions
            let image = try XCTUnwrap(renderer.cgImage)
            let text = try recognizedText(image)
            XCTAssertTrue(text.contains("Fixture Movie"), text)
            XCTAssertFalse(text.lowercased().contains("audio:"), text)
            XCTAssertFalse(text.contains("AC3"), text)
            XCTAssertFalse(text.contains("Default"), text)
            model.audioOptions = []
            let withoutTrack = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(UIImage(cgImage: image).pngData(), UIImage(cgImage: withoutTrack).pngData(),
                           "Track options must not add another description beneath the unchanged badge row")
            XCTAssertEqual(model.infoCard.badges, [.init("Dolby Digital", style: .dolby, detail: "5.1")])
            attach(image, name: "Info audio badge \(Int(width))")
        }
    }

    private var fixture: PlaybackDiagnostics {
        var value = PlaybackDiagnostics(
            videoCodec: "HEVC", audioCodec: "AAC", audioChannels: 2, container: "mkv",
            mode: .transcode, engineName: "AVPlayer", frameRate: 23.976
        )
        value.sourceProvider = .emby
        value.serverName = "Fixture Server"
        value.sourceFileName = "A long movie filename with multiple words and 2160p HDR.mkv"
        value.playbackState = "Buffering"
        value.observedBitrate = 1_872_000
        return value
    }

    func testPhoneRowsUseReadableFullWidthValuesAtNormalAndLargeType() throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let renderer = ImageRenderer(content:
                PlaybackDiagnosticsOverlay.MobileDiagnosticsRow(label: "File", value: Text(verbatim: fixture.sourceFileName!))
                    .environment(\.themePalette, .dark)
                    .environment(\.dynamicTypeSize, size)
                    .frame(width: 280)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.black)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 280)
            XCTAssertLessThan(image.height, size == .large ? 120 : 350,
                              "A full-width value must not wrap one or two characters per line")
            let text = try recognizedText(image)
            XCTAssertTrue(text.contains("movie"), text)
            attach(image, name: "Full-width row \(size)")
        }
    }

    func testPortraitAndLandscapeDiagnosticsRenderReadableContentAtActualColumnWidths() throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let panel = PlaybackDiagnosticsOverlay(diagnostics: fixture, presentation: .mobile)
            let renderer = ImageRenderer(content:
                panel.mobileContent(width: size.width)
                    .padding(20)
                    .frame(width: size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(.black)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(size.width))
            XCTAssertGreaterThan(image.height, Int(size.height), "The content must be scrollable, not squeezed into the viewport")
            XCTAssertLessThan(image.height, size.width < 700 ? 2_500 : 1_500)
            let text = try recognizedText(image)
            XCTAssertTrue(text.contains("Fixture Server"), text)
            XCTAssertTrue(text.contains("Delivery"), text)
            XCTAssertTrue(text.contains("movie filename"), text)
            XCTAssertTrue(text.contains("SYSTEM"), text)
            attach(image, name: "Diagnostics \(Int(size.width))x\(Int(size.height))")
        }
    }

    func testDiagnosticsCanScrollThroughTheWholeContentInBothOrientations() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let host = UIHostingController(rootView:
                PlaybackDiagnosticsOverlay(diagnostics: fixture, presentation: .mobile)
                    .environment(\.themePalette, .dark)
            )
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            let container = UIViewController()
            window.rootViewController = container
            container.addChild(host)
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let scroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertEqual(scroll.bounds.width, size.width, accuracy: 1)
            XCTAssertLessThanOrEqual(scroll.bounds.height, size.height)
            XCTAssertGreaterThan(scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom,
                                 scroll.bounds.height)
            // Lazy grid rows resolve their final heights as they enter view.
            for _ in 0..<5 {
                scroll.setContentOffset(CGPoint(
                    x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                ), animated: false)
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                if scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom >= scroll.contentSize.height - 1 {
                    break
                }
            }
            XCTAssertGreaterThan(scroll.contentOffset.y, -scroll.adjustedContentInset.top,
                                 "viewport=\(size) bounds=\(scroll.bounds) content=\(scroll.contentSize) inset=\(scroll.adjustedContentInset)")
            XCTAssertGreaterThanOrEqual(scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom,
                                        scroll.contentSize.height - 1)
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
    private func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct InfoAudioFixture: View {
    let model: PlayerControlsModel
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        InfoPanelView(model: model, actions: .init(), focus: $focus, onClose: {})
    }
}
#endif
