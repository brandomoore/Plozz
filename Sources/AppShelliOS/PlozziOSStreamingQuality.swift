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
                let network = StreamingNetwork.classify(
                    isSatisfied: path.status == .satisfied,
                    usesCellular: path.usesInterfaceType(.cellular),
                    usesWiFi: path.usesInterfaceType(.wifi),
                    usesEthernet: path.usesInterfaceType(.wiredEthernet)
                )
                HandoffDiagnostics.emit(
                    "streaming PATH network=\(network) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
                )
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
    @State private var editingQuality: StreamingQuality?

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(StreamingQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
                if !StreamingQuality.allCases.contains(selection) {
                    Text(selection.title).tag(selection)
                }
            } label: {
                Text(title)
            }
            Button("Custom…") { editingQuality = selection }
        } label: {
            LabeledContent {
                Text(selection.title)
            } label: {
                Text(title)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selection.title))
        .sheet(item: $editingQuality) { quality in
            StreamingCustomQualityEditor(quality: quality) { selection = $0 }
        }
        if let error = selection.validationError {
            Text(error.userMessage).font(.footnote).foregroundStyle(.red)
        }
    }
}

private struct StreamingCustomQualityEditor: View {
    let apply: (StreamingQuality) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StreamingQualityDraft
    @State private var applicationError: LocalizedStringResource?

    init(quality: StreamingQuality, apply: @escaping (StreamingQuality) -> Void) {
        self.apply = apply
        _draft = State(initialValue: StreamingQualityDraft(quality: quality))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Maximum resolution", selection: $draft.maximumHeight) {
                        ForEach(CustomStreamingQuality.supportedHeights, id: \.self) { height in
                            Text(verbatim: "\(height)p").tag(height)
                        }
                    }
                    LabeledContent("Total bitrate (Kbps)") {
                        TextField("Kbps", text: $draft.bitrateKbps)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Total bitrate in Kbps")
                    }
                    if let error = draft.validationError {
                        Text(error.userMessage).foregroundStyle(.red)
                    } else if let applicationError {
                        Text(applicationError).foregroundStyle(.red)
                    } else if let bytes = try? draft.validatedQuality().estimatedBytesPerHour {
                        Text("About \(bytes.formatted(.byteCount(style: .file))) per hour")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Resolution and bitrate are independent limits. Smaller videos aren’t enlarged. Kbps means kilobits per second: 2,000 Kbps is 2 Mbps. The total includes 128 Kbps for audio; the rest is available for video.")
                }
            }
            .navigationTitle("Custom quality")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do {
                            let quality = try draft.validatedQuality()
                            apply(quality)
                            dismiss()
                        } catch let error as StreamingQualityValidationError {
                            applicationError = error.userMessage
                        } catch {
                            applicationError = "This custom quality couldn’t be applied. Check the values and try again."
                        }
                    }
                    .disabled(draft.validationError != nil)
                }
            }
            .onChange(of: draft) { _, _ in applicationError = nil }
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
                    StreamingQualityPicker(title: "Quality limit", selection: $selection.quality)
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
                if viewModel.deliveryMode == .transcode {
                    CurrentStreamDetailsSection(details: viewModel.currentStreamDetails)
                    if let codec = viewModel.streamingOutputVideoCodec,
                       codec == .h264, viewModel.streamingOptions?.codec == .preferHEVC {
                        Section {
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
                    .disabled(selection.quality.validationError != nil)
                }
            }
        }
    }
}
#endif
