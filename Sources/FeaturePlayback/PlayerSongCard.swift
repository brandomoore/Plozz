#if canImport(SwiftUI) && canImport(UIKit)
import CoreUI
import SwiftUI

struct PlayerSongArtworkBounds: PreferenceKey {
    enum Role: Hashable, Sendable {
        case info, song
    }

    static let defaultValue: [Role: CGRect] = [:]

    static func reduce(value: inout [Role: CGRect], nextValue: () -> [Role: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct PlayerSongLayout<Content: View>: View {
    let enabled: Bool
    let state: SongIDState
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    @ViewBuilder var content: () -> Content
    @Environment(\.playerCardMetrics) private var metrics

    private var song: SongMatch? {
        guard enabled, case let .found(song) = state else { return nil }
        return song
    }

    var body: some View {
        let artSize = PlayerSongCard.artworkSize(for: metrics)
        let layout = metrics.isVertical
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            content()
            if let song {
                PlayerSongCard(song: song, focus: $focus)
                    .frame(
                        width: metrics.isVertical ? nil : artSize * 2 + metrics.columnSpacing + metrics.contentPadding * 2,
                        height: artSize + metrics.contentPadding * 2
                    )
                    .frame(maxWidth: metrics.isVertical ? .infinity : nil)
            }
        }
        .onChange(of: song != nil) { _, isVisible in
            if !isVisible, focus == .infoSong { focus = .infoStats }
        }
    }
}

struct PlayerSongCard: View {
    let song: SongMatch
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.playerControlForeground) private var foreground
    @Environment(\.playerUsesNativeGlass) private var usesNativeGlass
    @Environment(\.openURL) private var openURL

    static func artworkSize(for metrics: PlayerCardMetrics) -> CGFloat {
        metrics.isVertical ? 112 : metrics.contentHeight
    }

    var body: some View {
        Group {
            if let url = song.appleMusicURL {
                #if os(tvOS)
                Group {
                    if #available(tvOS 26.0, *), usesNativeGlass {
                        GeometryReader { geometry in
                            Button { openURL(url) } label: {
                                Color.clear.overlay {
                                    // The card owns its insets, not the native button's text margins.
                                    label.frame(width: geometry.size.width, height: geometry.size.height)
                                }
                            }
                            .buttonStyle(.glass)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else {
                        Button { openURL(url) } label: { panelLabel }
                            .buttonStyle(.card)
                    }
                }
                .buttonBorderShape(.roundedRectangle(radius: metrics.panelCornerRadius))
                .focused($focus, equals: .infoSong)
                #else
                Button { openURL(url) } label: { panelLabel }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .infoSong)
                #endif
            } else {
                panelLabel
            }
        }
        .plozzFocusSection()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([song.title, song.artist].compactMap { $0 }.joined(separator: ", "))
    }

    private var panelLabel: some View {
        label.modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius, mediaGlass: true))
    }

    private var label: some View {
        let artSize = Self.artworkSize(for: metrics)
        return HStack(spacing: metrics.columnSpacing) {
            AsyncImage(url: song.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: artSize, height: artSize)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PlayerSongArtworkBounds.self,
                        value: [.song: geometry.frame(in: .global)]
                    )
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous
            ))
            .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: song.title)
                    .font(.system(size: metrics.bodySize, weight: .semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let artist = song.artist {
                    Text(verbatim: artist)
                        .font(.system(size: metrics.captionSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(foreground)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(metrics.contentPadding)
        .contentShape(RoundedRectangle(cornerRadius: metrics.panelCornerRadius, style: .continuous))
    }
}
#endif
