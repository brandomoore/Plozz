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

struct PlayerSongPreviewArtworkBounds: PreferenceKey {
    enum Role: Hashable, Sendable {
        case info, song
    }

    static let defaultValue: [Role: CGRect] = [:]

    static func reduce(value: inout [Role: CGRect], nextValue: () -> [Role: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
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
                let artSize = PlayerSongPreviewCard.artworkSize(for: metrics, fillsCard: true)
                let layout = metrics.isVertical
                    ? AnyLayout(VStackLayout(spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    content()
                    PlayerSongPreviewCard(state: state, fillsCard: true, focus: $focus)
                        .padding(metrics.contentPadding)
                        .frame(
                            width: metrics.isVertical ? nil : artSize * 2 + metrics.columnSpacing + metrics.contentPadding * 2,
                            height: artSize + metrics.contentPadding * 2
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
    var fillsCard = false
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    @Environment(\.playerControlForeground) private var foreground
    @Environment(\.openURL) private var openURL

    static func artworkSize(for metrics: PlayerCardMetrics, fillsCard: Bool) -> CGFloat {
        if fillsCard { return metrics.isVertical ? 112 : metrics.contentHeight }
        return metrics.isVertical ? 56 : max(52, metrics.contentHeight * 0.28)
    }

    var body: some View {
        if case let .found(song) = state {
            Button {
                if let url = song.appleMusicURL { openURL(url) }
            } label: {
                PlayerSongPreviewLabel(song: song, fillsCard: fillsCard)
                    .padding(fillsCard ? 0 : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(foreground.opacity(focus == .infoSong ? 0.16 : (fillsCard ? 0 : 0.08)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        foreground.opacity(focus == .infoSong ? 0.85 : (fillsCard ? 0 : 0.12)),
                        lineWidth: focus == .infoSong ? 2 : 1
                    )
            }
            .focused($focus, equals: .infoSong)
            .disabled(song.appleMusicURL == nil)
            .accessibilityLabel([song.title, song.artist].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

private struct PlayerSongPreviewLabel: View {
    let song: SongMatch
    let fillsCard: Bool
    @Environment(\.playerCardMetrics) private var metrics

    var body: some View {
        let artSize = PlayerSongPreviewCard.artworkSize(for: metrics, fillsCard: fillsCard)
        HStack(spacing: fillsCard ? metrics.columnSpacing : 14) {
            AsyncImage(url: song.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: artSize, height: artSize)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PlayerSongPreviewArtworkBounds.self,
                        value: [.song: geometry.frame(in: .global)]
                    )
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: fillsCard ? PlozzTheme.Metrics.mediumMediaCornerRadius : 8,
                style: .continuous
            ))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: song.title)
                    .font(.system(
                        size: fillsCard ? metrics.bodySize : min(metrics.bodySize, metrics.actionSize + 3),
                        weight: .semibold
                    ))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let artist = song.artist {
                    Text(verbatim: artist)
                        .font(.system(size: fillsCard ? metrics.captionSize : min(metrics.captionSize, metrics.actionSize)))
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
