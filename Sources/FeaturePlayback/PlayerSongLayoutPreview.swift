#if canImport(SwiftUI) && canImport(UIKit)
import CoreUI
import SwiftUI

enum PlayerSongLayoutPreview: String, Sendable {
    case original, integrated, separate
}

private struct PlayerSongLayoutPreviewKey: EnvironmentKey {
    static let defaultValue = PlayerSongLayoutPreview.original
}

extension EnvironmentValues {
    var playerSongLayoutPreview: PlayerSongLayoutPreview {
        get { self[PlayerSongLayoutPreviewKey.self] }
        set { self[PlayerSongLayoutPreviewKey.self] = newValue }
    }
}

struct PlayerSongPreviewLayout<Content: View>: View {
    let state: SongIDState
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    @ViewBuilder var content: () -> Content
    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.playerSongLayoutPreview) private var songLayout

    var body: some View {
        Group {
            if songLayout == .separate {
                let layout = metrics.isVertical
                    ? AnyLayout(VStackLayout(spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    content()
                    PlayerSongPreviewCard(state: state, horizontal: metrics.isVertical, focus: $focus)
                        .padding(metrics.contentPadding)
                        .frame(
                            width: metrics.isVertical ? nil : metrics.contentHeight * 1.3,
                            height: metrics.isVertical ? 80 + metrics.contentPadding * 2 : metrics.cardHeight
                        )
                        .frame(maxWidth: metrics.isVertical ? .infinity : nil)
                        .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius, mediaGlass: true))
                        .opacity(state == .idle ? 0 : 1)
                }
            } else {
                content()
            }
        }
        .onChange(of: state) { _, state in
            if songLayout != .original, state == .idle, focus == .infoSong {
                focus = .infoStats
            }
        }
    }
}

/// Preview-only alternatives; normal playback retains the contributor's layout.
struct PlayerSongPreviewCard: View {
    let state: SongIDState
    let horizontal: Bool
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    @Environment(\.playerControlForeground) private var foreground
    @Environment(\.openURL) private var openURL

    var body: some View {
        if case let .found(song) = state {
            Button {
                if let url = song.appleMusicURL { openURL(url) }
            } label: {
                PlayerSongPreviewLabel(song: song, horizontal: horizontal)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(foreground.opacity(focus == .infoSong ? 0.16 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(foreground.opacity(focus == .infoSong ? 0.85 : 0), lineWidth: 2)
            }
            .focused($focus, equals: .infoSong)
            .disabled(song.appleMusicURL == nil)
            .accessibilityLabel([song.title, song.artist].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

private struct PlayerSongPreviewLabel: View {
    let song: SongMatch
    let horizontal: Bool
    @Environment(\.playerCardMetrics) private var metrics

    var body: some View {
        let artSize = horizontal
            ? (metrics.isVertical ? 56 : max(52, metrics.contentHeight * 0.28))
            : metrics.contentHeight * 0.42
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        layout {
            AsyncImage(url: song.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: song.title)
                    .font(.system(
                        size: horizontal ? min(metrics.bodySize, metrics.actionSize + 3) : metrics.bodySize,
                        weight: .semibold
                    ))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let artist = song.artist {
                    Text(verbatim: artist)
                        .font(.system(size: horizontal ? min(metrics.captionSize, metrics.actionSize) : metrics.captionSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
