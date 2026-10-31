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
                let interfacePreference: [StreamingNetwork] = path.availableInterfaces.map { interface in
                    switch interface.type {
                    case .wifi: .wifi
                    case .cellular: .cellular
                    case .wiredEthernet: .wired
                    default: .unknown
                    }
                }
                let network = StreamingNetwork.classify(
                    isSatisfied: path.status == .satisfied,
                    usesCellular: path.usesInterfaceType(.cellular),
                    usesWiFi: path.usesInterfaceType(.wifi),
                    usesEthernet: path.usesInterfaceType(.wiredEthernet),
                    interfacePreference: interfacePreference
                )
                HandoffDiagnostics.emit(
                    "streaming PATH network=\(network) status=\(path.status) "
                        + "wifi=\(path.usesInterfaceType(.wifi)) cellular=\(path.usesInterfaceType(.cellular)) "
                        + "wired=\(path.usesInterfaceType(.wiredEthernet)) other=\(path.usesInterfaceType(.other)) "
                        + "preference=\(interfacePreference) "
                        + "expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
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

extension PlozziOSAppModel {
    var streamingQualitySupport: StreamingQualitySupport {
        let providers = accountsProviders.resolvedActiveAccounts.compactMap {
            $0.provider as? any StreamingQualityProviding
        }
        return !providers.isEmpty && providers.allSatisfy { $0.streamingQualitySupport == .silo }
            ? .silo : .standard
    }
}

struct PlozziOSStreamingSettings: View {
    @Binding var settings: StreamingQualitySettings
    let hasCompatibleServer: Bool
    var support: StreamingQualitySupport = .standard
    let onShowAdvanced: () -> Void

    var body: some View {
        SettingsSectionGroup("Streaming quality") {
            if hasCompatibleServer {
                StreamingQualityPicker(title: "Local network", selection: $settings.local, support: support).settingsSearchAnchor("quality-local")
                StreamingQualityPicker(title: "Remote Wi-Fi / Ethernet", selection: $settings.remote, support: support).settingsSearchAnchor("quality-remote")
                StreamingQualityPicker(title: "Cellular", selection: $settings.cellular, support: support).settingsSearchAnchor("quality-cellular")
                Button(action: onShowAdvanced) {
                    HStack {
                        Text("Advanced")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("streaming-advanced")
            } else {
                Picker("Quality", selection: .constant(StreamingQuality.original)) {
                    Text("Original quality").tag(StreamingQuality.original)
                }
                .disabled(true)
                .accessibilityIdentifier("streaming-unavailable")
                .settingsSearchAnchor(
                    "streaming-unavailable",
                    fallbackFor: ["quality-local", "quality-remote", "quality-cellular"]
                        + SettingsSearchCatalog.targets(on: .streamingAdvanced)
                )
            }
        } footer: {
            if !hasCompatibleServer {
                Text("Unavailable for network shares.")
            }
        }
        .settingsSearchGroup(
            ["quality-local", "quality-remote", "quality-cellular"]
                + SettingsSearchCatalog.targets(on: .streamingAdvanced)
        )
    }
}

struct PlozziOSAdvancedStreamingSettings: View {
    @Binding var settings: StreamingQualitySettings
    let support: StreamingQualitySupport

    var body: some View {
        List {
            SettingsSectionGroup {
                Menu {
                    ForEach(codecChoices) { codec in
                        Button { settings.codec = codec } label: {
                            if settings.codec == codec {
                                Label {
                                    Text(codec.title)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(codec.title)
                            }
                        }
                        .disabled(!support.codecs.contains(codec))
                    }
                } label: {
                    SettingsMenuLabel("Transcoding codec", value: settings.codec.title)
                }
                .accessibilityLabel("Transcoding codec")
                .accessibilityValue(Text(settings.codec.title))
                .accessibilityIdentifier("streaming-codec").settingsSearchAnchor("quality-codec")
                Toggle("Force transcoding", isOn: $settings.forceTranscoding)
                    .accessibilityIdentifier("streaming-force-transcoding").settingsSearchAnchor("quality-force")
            } footer: {
                if !support.codecs.contains(settings.codec) {
                    Text("Choose a supported codec.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.forceTranscoding {
                    Text("May change HDR and audio formats.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Streaming quality")
    }

    private var codecChoices: [StreamingCodecPreference] {
        support.codecs.contains(settings.codec) ? support.codecs : support.codecs + [settings.codec]
    }
}

struct StreamingQualityPicker: View {
    let title: LocalizedStringResource
    @Binding var selection: StreamingQuality
    var support: StreamingQualitySupport = .standard
    @State private var editingQuality: StreamingQuality?

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(availableQualities) { quality in
                    Text(quality.title).tag(quality)
                }
                if !availableQualities.contains(selection) {
                    Text(selection.title).tag(selection)
                        .disabled(support.validationMessage(for: selection) != nil)
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.inline)
            Button("Custom…") { editingQuality = selection }
        } label: {
            SettingsMenuLabel(title, value: selection.title)
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selection.title))
        .plozzSheet(item: $editingQuality) { quality in
            StreamingCustomQualityEditor(quality: quality, support: support) { selection = $0 }
        }
        if let message = support.validationMessage(for: selection) {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }

    private var availableQualities: [StreamingQuality] {
        StreamingQuality.allCases.filter { support.validationMessage(for: $0) == nil }
    }
}

struct StreamingCustomQualityEditor: View {
    let apply: (StreamingQuality) -> Void
    let support: StreamingQualitySupport
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StreamingQualityDraft
    @State private var applicationError: LocalizedStringResource?

    init(
        quality: StreamingQuality, support: StreamingQualitySupport,
        apply: @escaping (StreamingQuality) -> Void
    ) {
        self.apply = apply
        self.support = support
        _draft = State(initialValue: StreamingQualityDraft(quality: quality))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Maximum resolution", selection: $draft.maximumHeight) {
                        ForEach(support.heights, id: \.self) { height in
                            Text(verbatim: "\(height)p").tag(height)
                        }
                        if !support.heights.contains(draft.maximumHeight) {
                            Text(verbatim: "\(draft.maximumHeight)p").tag(draft.maximumHeight).disabled(true)
                        }
                    }.settingsSearchAnchor("quality-custom-height")
                    LabeledContent("Total bitrate (Kbps)") {
                        TextField("Kbps", text: $draft.bitrateKbps)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Total bitrate in Kbps").settingsSearchAnchor("quality-custom-bitrate")
                    }
                    if let message = validationMessage {
                        Text(message).foregroundStyle(.red)
                    } else if let applicationError {
                        Text(applicationError).foregroundStyle(.red)
                    } else if let bytes = try? draft.validatedQuality().estimatedBytesPerHour {
                        Text("About \(bytes.formatted(.byteCount(style: .file))) per hour")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Resolution and bitrate are independent limits. Smaller videos aren’t enlarged. Kbps means kilobits per second: 2,000 Kbps is 2 Mbps. Audio is included in the total; the server allocates the audio and video budgets.")
                    if let notice = support.notice { Text(notice) }
                }
            }
            .navigationTitle("Custom quality")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do {
                            let quality = try draft.validatedQuality()
                            if let message = support.validationMessage(for: quality) {
                                applicationError = message
                                return
                            }
                            apply(quality)
                            dismiss()
                        } catch let error as StreamingQualityValidationError {
                            applicationError = error.userMessage
                        } catch {
                            applicationError = "This custom quality couldn’t be applied. Check the values and try again."
                        }
                    }
                    .disabled(validationMessage != nil)
                }

            }
            .onChange(of: draft) { _, _ in applicationError = nil }
        }
    }

    private var validationMessage: LocalizedStringResource? {
        if let error = draft.validationError { return error.userMessage }
        guard let quality = try? draft.validatedQuality() else { return nil }
        return support.validationMessage(for: quality)
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
                    StreamingQualityPicker(
                        title: "Quality limit", selection: $selection.quality,
                        support: viewModel.streamingQualitySupport
                    )
                    if let bytes = selection.quality.estimatedBytesPerHour {
                        Text("About \(bytes.formatted(.byteCount(style: .file))) per hour")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Transcoding codec", selection: $selection.codec) {
                        ForEach(viewModel.streamingQualitySupport.codecs) { Text($0.title).tag($0) }
                        if !viewModel.streamingQualitySupport.codecs.contains(selection.codec) {
                            Text(selection.codec.title).tag(selection.codec).disabled(true)
                        }
                    }
                    if let notice = viewModel.streamingQualitySupport.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
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
            .toggleStyle(SettingsSwitchToggleStyle())
            .navigationTitle("Streaming quality")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        viewModel.changeStreamingOptions(selection)
                        dismiss()
                    }
                    .disabled(viewModel.streamingQualitySupport.validationMessage(for: selection.quality) != nil)
                }
            }
        }
    }
}
#endif
