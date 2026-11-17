#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

/// The in-player subtitle **search + download** screen, extracted from
/// `PlayerControls`. Shows a spinner while searching, the ranked results (with
/// Forced/SDH badges) to pick from, or a friendly empty/error state. Picking a
/// result downloads it server-side and hot-loads it into the running player.
///
/// Pure content: it reads `model.subtitleDownload.state` and drives
/// `actions.downloadRemoteSubtitle`, threading the shared `@FocusState` so its
/// result rows participate in the same focus engine. No panel morph coupling.
struct SubtitleDownloadScreen: View {
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?

    @ViewBuilder
    var body: some View {
        switch model.subtitleDownload.state {
        case .idle, .searching:
            subtitleDownloadStatus(
                systemImage: "magnifyingglass",
                title: "Searching for subtitles…",
                detail: "Looking through your server's subtitle source.",
                showSpinner: true
            )
        case .results(let subs):
            subtitleResultsList(subs)
        case .empty:
            subtitleDownloadStatus(
                systemImage: "text.magnifyingglass",
                title: "No subtitles found",
                detail: "Nothing matched in your language. Check that a subtitle source, such as OpenSubtitles, is set up on your server."
            )
        case .downloading:
            subtitleDownloadStatus(
                systemImage: "arrow.down.circle",
                title: "Downloading subtitle…",
                detail: "Fetching it and loading it into the player.",
                showSpinner: true
            )
        case .added:
            subtitleDownloadStatus(
                systemImage: "checkmark.circle.fill",
                title: "Subtitle added",
                detail: "It's now playing and available in your subtitle list."
            )
        case .failed:
            subtitleDownloadStatus(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't get that subtitle",
                detail: "Something went wrong searching or downloading. Try again."
            )
        case .unavailable(let message):
            subtitleDownloadStatus(
                systemImage: "exclamationmark.triangle",
                title: "Subtitles unavailable",
                detail: message
            )
        }
    }

    private func subtitleDownloadStatus(systemImage: String, title: LocalizedStringResource, detail: LocalizedStringResource, showSpinner: Bool = false) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if showSpinner {
                    ProgressView()
                } else {
                    Image(systemName: systemImage).font(.title3)
                }
                Text(title).font(.callout.weight(.semibold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        // Fill the pinned Download-screen height and centre, so the spinner /
        // message sits in the middle of the box rather than jammed top-left.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func subtitleResultsList(_ subs: [RemoteSubtitle]) -> some View {
        // A plain column (NOT a ScrollView): the enclosing `morphingBody` already
        // provides the scroll + height measurement that drives the open/height
        // morph, exactly like the track list. A nested ScrollView here is greedy
        // vertically, breaks that measurement (so the panel wouldn't animate open),
        // and reads as janky.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(subs.prefix(30).enumerated()), id: \.element.id) { index, sub in
                Button {
                    actions.downloadRemoteSubtitle(sub)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(text: Self.remoteSubtitleTitle(sub), font: .body)
                        HStack(spacing: 8) {
                            Text(Self.remoteSubtitleDetail(sub))
                                .font(.caption2)
                                .playerMenuRowSecondary()
                                .lineLimit(1)
                            SubtitleFileMatchBadge(isHashMatch: sub.isHashMatch)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerMenuRowButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .row(index))
            }
        }
        .padding(.horizontal, 14)
    }

    /// The candidate's display name, falling back to language when unnamed.
    private static func remoteSubtitleTitle(_ sub: RemoteSubtitle) -> String {
        if !sub.name.isEmpty { return sub.name }
        if let language = sub.language { return SubtitleLanguageCatalog.displayName(forCode: language) ?? language }
        return "Subtitle"
    }

    /// The language · downloads · badges line beneath a candidate. The provider is
    /// omitted for OpenSubtitles (Plex's only source, and Jellyfin's usual one — so
    /// it's noise); a *different* provider is shown since then it's informative.
    private static func remoteSubtitleDetail(_ sub: RemoteSubtitle) -> String {   // l10n:content — subtitle file metadata from the provider
        var parts: [String] = []
        if let provider = sub.providerName, !provider.isEmpty,
           !provider.lowercased().replacingOccurrences(of: " ", with: "").contains("opensubtitles") {
            parts.append(provider)
        }
        if let language = sub.language,
           let name = SubtitleLanguageCatalog.displayName(forCode: language) { parts.append(name) }
        if let count = sub.downloadCount, count > 0 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            parts.append("\(formatted) downloads")
        }
        if sub.isForced { parts.append("Forced") }
        if sub.isHearingImpaired { parts.append("SDH") }
        return parts.isEmpty ? "Tap to download" : parts.joined(separator: " · ")
    }
}

#if DEBUG && os(tvOS)
/// An opt-in visual fixture using the real search rows, without a player or server.
@MainActor
public struct SubtitleFileMatchPreview: View {
    @State private var model = SubtitleFileMatchPreview.makeModel()
    @State private var selectedExample: String?
    @FocusState private var focus: PlayerControls.FocusSlot?
    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["PLOZZ_SUBTITLE_FILE_MATCH_PREVIEW"] == "1"
    }

    static func makeModel() -> PlayerControlsModel {
        let model = PlayerControlsModel()
        model.subtitleDownload.state = .results([
            RemoteSubtitle(
                id: "preview-hash-match",
                name: "Example.with.file.match.en.srt",
                language: "eng",
                isHashMatch: true
            ),
            RemoteSubtitle(
                id: "preview-unconfirmed",
                name: "Example.without.file.match.en.srt",
                language: "eng"
            )
        ])
        return model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SubtitleFileMatchPreviewHeader()
            SubtitleDownloadScreen(
                model: model,
                actions: PlayerOptionsActions(downloadRemoteSubtitle: {
                    selectedExample = $0.name
                }),
                focus: $focus
            )
            .padding(.vertical, 14)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 32))
            SubtitleFileMatchPreviewFooter(selectedExample: selectedExample, onClose: onClose)
        }
        .frame(width: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .defaultFocus($focus, .row(0))
        .onExitCommand(perform: onClose)
    }
}

private struct SubtitleFileMatchPreviewHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Subtitle badge preview")
                .font(.title2.bold())
            Text(verbatim: "Visual examples only, not matches from your server.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SubtitleFileMatchPreviewFooter: View {
    let selectedExample: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(verbatim: selectedExample.map {
                "Selected example: \($0)\nNothing was downloaded."
            } ?? "Move between the rows to compare the badge with and without focus. Selecting an example will not download anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done", action: onClose)
        }
    }
}
#endif

/// The compact subtitle **timing** screen reached from the header Sync chip:
/// nudge the primary subtitle earlier/later to line it up with the audio. A
/// single-focus settings stepper in 50 ms steps, with held Left/Right and Reset.
/// Changes apply immediately to the subtitle timeline. Only
/// offered when the app's overlay owns the active subtitle, so the chip that
/// opens it is gated the same way. Extracted from `PlayerControls`; the shared
/// `delayLabel` / `subtitleSyncHint` formatters stay on `PlayerControls` because
/// the A/V Sync pane uses them too.
struct SubtitleSyncScreen: View {
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    var allowsResetFocus = true
    var onControlFocus: () -> Void = {}

    var body: some View {
        PlaybackSyncScreen(
            value: model.subtitleDelaySeconds,
            hint: PlayerControls.subtitleSyncHint(model.subtitleDelaySeconds),
            range: -10...10, showsReset: true,
            onChange: actions.setSubtitleDelay, focus: $focus,
            allowsResetFocus: allowsResetFocus, onControlFocus: onControlFocus
        )
    }
}

struct PlaybackSyncScreen: View {
    let value: TimeInterval
    let hint: LocalizedStringResource
    let range: ClosedRange<TimeInterval>
    var showsReset = false
    var step: TimeInterval = 0.05
    let onChange: (TimeInterval) -> Void
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    var allowsResetFocus = true
    var onControlFocus: () -> Void = {}

    private var indices: ClosedRange<Int> {
        Int((range.lowerBound / step).rounded())...Int((range.upperBound / step).rounded())
    }

    var body: some View {
        VStack(spacing: 20) {
            SettingsStepper(
                options: Array(indices),
                selection: Binding(
                    get: { Int((value / step).rounded()) },
                    set: { onChange(Double($0) * step) }
                ),
                compact: true,
                onFocusChange: {
                    if $0 {
                        focus = .row(0)
                        onControlFocus()
                    }
                },
                verbatimTitle: { PlayerControls.delayLabel(Double($0) * step) }
            )
            .reservingValueWidth(for: [indices.lowerBound, indices.upperBound])
            .accessibilityLabel("Subtitle Delay")
            .frame(maxWidth: .infinity)
            .plozzFocusSection()
            Text(hint)
                .font(.callout)
                .foregroundStyle(Color.primary.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.15), value: value)
            if showsReset {
                Button("Reset") { onChange(0) }
                    .focused($focus, equals: .row(1))
                    .disabled(value == 0 || !allowsResetFocus)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }
}

struct AudioSyncScreen: View {
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    var allowsResetFocus = true
    var onControlFocus: () -> Void = {}
    private var adjustment: PlayerAudioSyncEditor { model.audioSyncAdjustment }

    private var value: TimeInterval { adjustment.value ?? model.audioDelaySeconds }

    var body: some View {
        VStack(spacing: 20) {
            SettingsStepper(
                options: Array(-200...200),
                selection: Binding(
                    get: { Int((value * 100).rounded()) },
                    set: { change(Double($0) / 100) }
                ),
                compact: true,
                onFocusChange: {
                    if $0 {
                        focus = .row(0)
                        onControlFocus()
                    }
                },
                verbatimTitle: { PlayerControls.delayLabel(Double($0) / 100) }
            )
            .reservingValueWidth(for: [-200, 200])
            .onDirectionalAdjustment({ forward, repeating in
                adjustment.nudge(from: model.audioDelaySeconds, forward: forward, repeating: repeating,
                                 applyLive: actions.setAudioDelayLive, commit: actions.setAudioDelay)
            }, onEditingEnded: {
                adjustment.endEditing(cancelled: $0, commit: actions.setAudioDelay)
            })
            .accessibilityLabel("Audio Delay")
            .frame(maxWidth: .infinity)
            .plozzFocusSection()
            Text(PlayerControlsModel.audioSyncHint(for: value))
                .font(.callout)
                .foregroundStyle(Color.primary.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            Button("Reset") {
                adjustment.cancel()
                change(0)
            }
            .focused($focus, equals: .row(1))
            .disabled(value == 0 || !allowsResetFocus)
        }
        .padding(28)
        .onDisappear { adjustment.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            adjustment.cancel()
        }
        .onChange(of: model.infoCard.sourceItemID) { _, _ in adjustment.cancel() }
        .onChange(of: model.infoCard.sourceAccountID) { _, _ in adjustment.cancel() }
    }

    private func change(_ value: TimeInterval) {
        adjustment.change(to: value, current: model.audioDelaySeconds,
                          applyLive: actions.setAudioDelayLive, commit: actions.setAudioDelay)
    }
}
#endif
