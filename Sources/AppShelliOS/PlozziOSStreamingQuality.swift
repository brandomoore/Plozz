#if os(iOS)
import CoreModels
import CoreUI
import FeaturePlayback
import Network
import SwiftUI

enum PlozziOSStreamingNetwork {
    static func updates() -> AsyncStream<StreamingNetwork> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                let network: StreamingNetwork
                if path.status != .satisfied { network = .offline }
                else if path.usesInterfaceType(.cellular) || path.isExpensive { network = .cellular }
                else if path.usesInterfaceType(.wifi) { network = .wifi }
                else if path.usesInterfaceType(.wiredEthernet) { network = .wired }
                else { network = .unknown }
                continuation.yield(network)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
                monitor.pathUpdateHandler = nil
            }
            monitor.start(queue: DispatchQueue(label: "com.plozz.streaming-network"))
        }
    }
}

struct PlozziOSStreamingSettings: View {
    @Binding var settings: StreamingQualitySettings
    let hasCompatibleServer: Bool

    var body: some View {
        SettingsSectionGroup("Streaming quality") {
            if hasCompatibleServer {
                StreamingQualityPicker(title: "Local network", selection: $settings.local)
                StreamingQualityPicker(title: "Remote Wi-Fi / Ethernet", selection: $settings.remote)
                StreamingQualityPicker(title: "Cellular", selection: $settings.cellular)
                Picker("Transcoding codec", selection: $settings.codec) {
                    ForEach(StreamingCodecPreference.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.codec.explanation).font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Advanced") {
                    Toggle("Force transcoding", isOn: $settings.forceTranscoding)
                    Text("Uses your server to convert video even when the original can play. HDR and audio formats may change.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Original quality")
            }
        } footer: {
            if hasCompatibleServer {
                Text("For movies and episodes from Plex, Jellyfin, and Emby. The original plays when it fits the limit; otherwise your server converts it. Codec preferences may fall back without increasing the quality limit. Downloads, Live TV, and file shares are unchanged.")
            } else {
                Text("File shares play original files and can’t convert video. Quality controls become available when you connect a compatible media server.")
            }
        }
    }
}

struct StreamingQualityPicker: View {
    let title: LocalizedStringResource
    @Binding var selection: StreamingQuality

    var body: some View {
        Picker(selection: $selection) {
            ForEach(StreamingQuality.allCases) { quality in
                Text(quality.title).tag(quality)
            }
        } label: {
            Text(title)
        }
    }
}

struct PlozziOSStreamingQualitySheet: View {
    let viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: StreamingPlaybackOptions

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        _selection = State(initialValue: viewModel.streamingOptions ?? .init(quality: .original))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StreamingQualityPicker(title: "Quality", selection: $selection.quality)
                    if let bytes = selection.quality.estimatedBytesPerHour {
                        Text("About \(bytes.formatted(.byteCount(style: .file))) per hour")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Transcoding codec", selection: $selection.codec) {
                        ForEach(StreamingCodecPreference.allCases) { Text($0.title).tag($0) }
                    }
                    Text(selection.codec.explanation).font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Advanced") {
                        Toggle("Force transcoding", isOn: $selection.forceTranscoding)
                        Text("Uses your server to convert video even when the original can play. HDR and audio formats may change.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Applies to this video. Changing quality briefly reloads playback at the current position. Your server may use another codec within the selected limit. Data use is approximate.")
                }
                if let codec = viewModel.streamingOutputVideoCodec, viewModel.phase == .ready {
                    Section {
                        LabeledContent("Stream codec") {
                            Text(verbatim: PlaybackDiagnostics.friendlyCodecName(codec.rawValue) ?? codec.rawValue)
                        }
                        if codec == .h264, viewModel.streamingOptions?.codec == .preferHEVC {
                            Text("Using H.264 for this stream; HEVC remains your preference.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = viewModel.streamingQualityError {
                    Section { Text(error.userMessage).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Streaming quality")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        viewModel.changeStreamingOptions(selection)
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
