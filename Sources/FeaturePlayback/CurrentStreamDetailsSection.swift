#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// Uses only active rendition facts. The selected quality limit is a separate
/// control; absent measurements must not be filled with that limit or file data.
public struct CurrentStreamDetailsSection: View {
    public let details: PlaybackStreamDetails

    public init(details: PlaybackStreamDetails) {
        self.details = details
    }

    public var body: some View {
        let d = details.diagnostics
        Section("Current stream") {
            detail("Resolution", d.resolutionText)
            detail("Video codec", d.videoCodecText)
            LabeledContent {
                value(d.hdrText)
            } label: {
                Text(verbatim: "HDR")
            }
            detail("Audio", d.audioCodecText)
            detail("Channels", d.audioChannelsText)
            if let bitrate = details.declaredBitrate, bitrate > 0 {
                detail("Declared stream bitrate", PlaybackDiagnostics.formatBitrate(bitrate))
            }
        }
    }

    private func detail(_ label: LocalizedStringResource, _ value: String) -> some View {
        LabeledContent {
            self.value(value)
        } label: {
            Text(label)
        }
    }

    @ViewBuilder
    private func value(_ text: String) -> some View {
        if text == PlaybackDiagnostics.placeholder {
            Text("Not available").foregroundStyle(.secondary)
        } else {
            Text(verbatim: text)
        }
    }
}
#endif
