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
    func testInfoRetainsReadOnlyAudioWithSourceLabelDuringConversion() throws {
        let model = PlayerControlsModel()
        model.infoCard.headline = "Fixture Movie"
        model.infoCard.overview = "A movie with a single audio track."
        model.audioOptions = TrackMenuBuilder.audioOptions(tracks: [
            .init(id: 1, kind: .audio, displayTitle: "AC3 5.1 (Default)", codec: "ac3", channels: 6)
        ], selectedID: 1, preferred: [], locale: .init(identifier: "en_US"))
        XCTAssertFalse(model.hasAudioControls)
        for transcoding in [false, true] {
            model.infoCard.audioIsSourceTrack = transcoding
            for width in [CGFloat(390), 1024, 1920] {
                let renderer = ImageRenderer(content:
                    InfoAudioFixture(model: model)
                        .environment(\.playerCardMetrics, width == 1920 ? .tv : .resolved(forWidth: width, height: 844))
                        .environment(\.themePalette, .dark)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .frame(width: width)
                        .background(.black)
                )
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let text = try recognizedText(image)
                XCTAssertTrue(text.contains("Dolby Digital 5.1"), text)
                XCTAssertEqual(text.contains("Source audio"), transcoding, text)
                XCTAssertFalse(text.contains("AC3"), text)
                XCTAssertFalse(text.contains("Default"), text)
                attach(image, name: "Info audio \(Int(width)) converted \(transcoding)")
            }
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
            scroll.setContentOffset(CGPoint(
                x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            ), animated: false)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
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
