#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI

public struct PlayerCommunityTimestampsView: View {
    private let model: PlayerCommunityTimestampsModel
    @State private var showsHighlights = false
    @State private var selection: CommunityPlaybackTimestamp?
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    public init(model: PlayerCommunityTimestampsModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    SettingsPageHeader("Community timestamps")
                    Text(verbatim: model.sourceName).font(.headline)
                    Text("These timestamps may describe a different release. Each jump needs confirmation. Server markers and automatic skipping are unchanged.")
                        .foregroundStyle(.secondary)
                    Toggle("Show highlights (may contain spoilers)", isOn: $showsHighlights)
                    if model.isLoading { ProgressView() }
                    if let failure = model.failure {
                        Text(verbatim: failure.localizedDescription).foregroundStyle(.secondary)
                    }
                    if model.loaded && model.entries.isEmpty { Text("No community timestamps") }
                    ForEach(model.entries) { entry in
                        PlayerCommunityTimestampRow(entry: entry, available: model.canSeek(entry)) {
                            selection = entry
                            confirming = true
                        }
                    }
                }
                .padding()
            }
            .accessibilityIdentifier("player-community-timestamps")
        }
        .task(id: showsHighlights) { await model.load(includeHighlights: showsHighlights) }
        .onChange(of: model.isCurrent) { _, current in if !current { dismiss() } }
        .onDisappear { model.cancel() }
        .confirmationDialog("Jump to this community timestamp?", isPresented: $confirming, presenting: selection) { entry in
            Button("Jump to start") {
                if model.seek(entry, toEnd: false) { dismiss() }
            }
            .disabled(!model.canSeek(entry))
            Button("Jump to end") {
                if model.seek(entry, toEnd: true) { dismiss() }
            }
            .disabled(!model.canSeek(entry, toEnd: true))
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\(PlayerControls.timeLabel(entry.start)) to \(PlayerControls.timeLabel(entry.end)). Release compatibility is unverified. Seeking can change the progress reported to your media server and enabled trackers.")
        }
    }
}

private struct PlayerCommunityTimestampRow: View {
    let entry: CommunityPlaybackTimestamp
    let available: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.kind.title).font(.headline)
            switch entry.release {
            case .streaming: Text("Streaming release")
            case .physical: Text("Physical release")
            case .unknown: Text("Release source unknown")
            }
            if let contributor = entry.contributor { Text(verbatim: contributor) }
            if let description = entry.description { Text(verbatim: description) }
            Text("\(PlayerControls.timeLabel(entry.start)) to \(PlayerControls.timeLabel(entry.end))")
                .monospacedDigit()
            if !available {
                Text("Unavailable for the current playback timeline.").foregroundStyle(.secondary)
            }
            Button("Review jump", action: select)
                .disabled(!available)
                .accessibilityIdentifier("player-community-timestamp-\(entry.id)")
        }
    }
}

private extension CommunityPlaybackTimestamp.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .intro: "Intro"
        case .credits: "Credits"
        case .recap: "Recap"
        case .preview: "Preview"
        case .highlight: "Highlight"
        }
    }
}
#endif
