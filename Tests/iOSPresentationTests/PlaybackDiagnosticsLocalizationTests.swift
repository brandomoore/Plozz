#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlaybackDiagnosticsLocalizationTests: XCTestCase {
    private let commonLabelKeys = [
        "File", "Size", "Delivery", "Stream", "Codec", "Resolution", "Frame Rate",
        "Color", "Codec Tag", "Channels", "Sample Rate", "Bitrate", "Output", "Track",
        "State", "Buffer", "Engine buffer", "Stalls", "Dropped",
        "Declared stream bitrate", "Network throughput", "Disk", "Memory", "Thermal", "Instances"
    ]

    func testMobileDiagnosticsLocalizeLabelsAndPreserveMediaContent() throws {
        for mode in [PlaybackDiagnostics.PlaybackMode.directPlay, .transcode, .plozzigen] {
            let panel = PlaybackDiagnosticsOverlay(diagnostics: fixture(mode: mode), presentation: .mobile)
            let text = try renderedText(
                panel.mobileContent(width: 844)
                    .frame(width: 844)
                    .fixedSize(horizontal: false, vertical: true),
                locale: "cs"
            )
            try assertLabels(in: text, mode: mode)
            assertMediaContent(in: text)
        }
    }

    func testTelevisionDiagnosticsUseTheSameLocalizedLabels() throws {
        let panel = PlaybackDiagnosticsOverlay(diagnostics: fixture(mode: .transcode), presentation: .television)
        let text = try renderedText(
            panel.frame(width: 1100).fixedSize(horizontal: false, vertical: true),
            locale: "cs"
        )
        try assertLabels(in: text, mode: .transcode, wrapped: true)
        assertMediaContent(in: text)
    }

    func testOneRowRespondsToTheEnvironmentLanguageWithoutTranslatingItsValue() throws {
        let row = PlaybackDiagnosticsOverlay.MobileDiagnosticsRow(
            label: Text(LocalizedStringResource("File")),
            value: Text(verbatim: "File")
        )
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        let english = try renderedText(row, locale: "en")
        let czech = try renderedText(row, locale: "cs")
        XCTAssertEqual(normalized(english).components(separatedBy: "file").count - 1, 2, english)
        XCTAssertTrue(normalized(czech).contains("soubor"), czech)
        XCTAssertTrue(normalized(czech).contains("file"), "Provider content must remain verbatim: \(czech)")
    }

    private func assertLabels(in text: String, mode: PlaybackDiagnostics.PlaybackMode, wrapped: Bool = false) throws {
        var labels = commonLabelKeys
        labels += mode == .plozzigen ? ["AVPlayer time", "AVPlayer window"] : ["Position", "Seekable"]
        labels += mode == .transcode ? ["Estimated bitrate", "Video", "Audio", "Container"] : ["Container"]
        let bundleURL = try XCTUnwrap(Bundle.main.url(forResource: "cs", withExtension: "lproj"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        for key in labels + ["playback.diagnostics.device"] {
            let translated = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            if ["File", "Size", "Delivery", "Resolution", "Memory", "playback.diagnostics.device"].contains(key) {
                XCTAssertNotEqual(translated, key, "Czech catalog must translate \(key)")
            }
            let expected = wrapped ? translated.split(separator: " ").map(String.init) : [translated]
            for fragment in expected {
                XCTAssertTrue(normalized(text).contains(normalized(fragment)),
                              "Missing Czech label \(key) (\(translated)): \(text)")
            }
        }
    }

    private func assertMediaContent(in text: String) {
        for content in ["Fixture Server", "Fixture.mkv", "AVPlayer", "HLS", "h264", "HDR10", "HDR", "hvc1"] {
            XCTAssertTrue(normalized(text).contains(normalized(content)), "Missing verbatim content \(content): \(text)")
        }
    }

    private func fixture(mode: PlaybackDiagnostics.PlaybackMode) -> PlaybackDiagnostics {
        var value = PlaybackDiagnostics(
            videoCodec: "h264", audioCodec: "aac", audioChannels: 2, container: "mkv",
            mode: mode, hdr: .hdr10, engineName: "AVPlayer", frameRate: 24
        )
        value.sourceProvider = .emby
        value.serverName = "Fixture Server"
        value.sourceFileName = "Fixture.mkv"
        value.sourceFileSizeBytes = 5_300_000_000
        value.resolution = .init(width: 720, height: 300)
        value.originalSource = .init(container: "mkv", video: .init(codec: "hevc", width: 3840, height: 2160),
                                     audio: .init(codec: "aac", channels: 2))
        value.streamTransport = PlaybackDiagnostics.streamTransportFacts(url: URL(string: "https://media.example/stream.m3u8"))
        value.videoBitrate = 500_000
        value.videoCodecTag = "hvc1"
        value.colorTransfer = "smpte2084"
        value.audioSampleRate = 48_000
        value.audioBitrate = 128_000
        value.audioOutputDescription = "Stereo"
        value.subtitleDescription = "SubRip"
        value.positionSeconds = 30
        value.durationSeconds = 300
        value.seekableStartSeconds = 0
        value.seekableEndSeconds = 300
        value.playbackState = "Ready"
        value.bufferedSecondsAhead = 10
        value.engineBufferedSecondsAhead = 20
        value.stallCount = 0
        value.droppedVideoFrames = 0
        value.indicatedBitrate = 628_000
        value.observedBitrate = 8_000_000
        value.deviceModel = "iPad"
        value.deviceMemoryBytes = 8_000_000_000
        value.freeDiskBytes = 10_000_000_000
        value.totalDiskBytes = 128_000_000_000
        value.memoryFootprintBytes = 200_000_000
        value.thermalState = .nominal
        value.liveViewModels = 1
        value.liveNativeEngines = 1
        return value
    }

    private func renderedText(_ view: some View, locale: String) throws -> String {
        let renderer = ImageRenderer(content: view
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: locale))
            .background(.black)
        )
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "Diagnostics \(locale)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Vision downsamples tall panels, obscuring otherwise readable caption text.
        // Overlapping strips retain the rendered font size and complete text lines.
        var lines: [String] = []
        for y in stride(from: 0, to: image.height, by: 1000) {
            let strip = try XCTUnwrap(image.cropping(to: CGRect(
                x: 0, y: y, width: image.width, height: min(1200, image.height - y)
            )))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = locale == "cs" && supported.contains("cs-CZ") ? ["cs-CZ", "en-US"] : ["en-US"]
            try VNImageRequestHandler(cgImage: strip).perform([request])
            lines += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        return lines.joined(separator: " ")
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "cs"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
#endif
