#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit

struct MobileMusicAlbumDetail: View {
    let album: MusicAlbum
    let tracks: [MusicTrack]
    let nowPlayingTrack: MusicTrack?
    let isPlaying: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onPlayTrack: (MusicTrack) -> Void

    var body: some View {
        MobileMusicDetailScaffold(
            title: album.title,
            subtitle: album.artistName,
            metadata: [album.year.map(String.init), album.trackCount.map {
                String(localized: "\($0) tracks · \(MusicFormat.duration(album.totalDuration))")
            }].compactMap { $0 }.joined(separator: " · "),
            artworkURL: album.artworkURL,
            artworkID: "\(album.sourceAccountID ?? ""):album:\(album.id)",
            artworkFallback: MusicArtworkFallback.albumCover(title: album.title, artist: album.artistName),
            isArtist: false
        ) {
            MobileMusicDetailActions(isEmpty: tracks.isEmpty, onPlay: onPlay, onShuffle: onShuffle)
        } content: {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    MobileMusicDetailTrackRow(
                        track: track,
                        number: track.trackNumber ?? index + 1,
                        isCurrent: nowPlayingTrack?.isSameQueueEntry(as: track) == true,
                        isPlaying: isPlaying,
                        action: { onPlayTrack(track) }
                    )
                    if index < tracks.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }
}

struct MobileMusicPlaylistDetail: View {
    let playlist: MusicPlaylist
    let tracks: [MusicTrack]
    let nowPlayingTrack: MusicTrack?
    let isPlaying: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onPlayTrack: (MusicTrack) -> Void

    var body: some View {
        MobileMusicDetailScaffold(
            title: playlist.title,
            subtitle: String(localized: "Playlist"),
            metadata: String(localized: "\(tracks.count) tracks"),
            artworkURL: playlist.artworkURL,
            artworkID: "\(playlist.sourceAccountID ?? ""):playlist:\(playlist.id)",
            artworkFallback: nil,
            isArtist: false,
            artworkPlaceholder: "music.note.list"
        ) {
            MobileMusicDetailActions(isEmpty: tracks.isEmpty, onPlay: onPlay, onShuffle: onShuffle)
        } content: {
            TrackListView(
                tracks: tracks,
                artworkFallback: playlist.artworkURL,
                showArtist: true,
                showArtwork: true,
                nowPlayingTrack: nowPlayingTrack,
                isPlaying: isPlaying,
                nowPlayingTint: .primary,
                onPlayTrack: onPlayTrack
            )
        }
    }
}

struct MobileMusicArtistDetail: View {
    let artist: MusicArtist
    let albums: [MusicAlbum]
    let onSelectAlbum: (MusicAlbum) -> Void

    var body: some View {
        MobileMusicDetailScaffold(
            title: artist.name,
            subtitle: nil,
            metadata: GenreDisplayFormatter.displayNames(for: artist.genres).joined(separator: " · "),
            artworkURL: artist.artworkURL,
            artworkID: "\(artist.sourceAccountID ?? ""):artist:\(artist.id)",
            artworkFallback: MusicArtworkFallback.artistImage(name: artist.name),
            isArtist: true
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                Text("Albums").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], alignment: .leading, spacing: 24) {
                    ForEach(albums) { album in
                        Button { onSelectAlbum(album) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MusicArtworkImage(
                                    url: album.artworkURL,
                                    systemPlaceholder: "opticaldisc",
                                    cornerRadius: 10,
                                    variant: .posterCard,
                                    showsMediaEdge: false,
                                    asyncFallbackURL: MusicArtworkFallback.albumCover(title: album.title, artist: album.artistName),
                                    pinIdentity: "\(album.sourceAccountID ?? ""):album:\(album.id)"
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityHidden(true)
                                Text(album.title).font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let year = album.year {
                                    Text(String(year)).font(.caption).foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("music.detail.album.\(album.id)")
                    }
                }
            }
        }
    }
}

private struct MobileMusicDetailActions: View {
    let isEmpty: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("music.detail.play")
            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("music.detail.shuffle")
        }
        .tint(.white)
        .controlSize(.large)
        .disabled(isEmpty)
    }
}

private struct MobileMusicDetailTrackRow: View {
    let track: MusicTrack
    let number: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Group {
                    if isCurrent {
                        NowPlayingEqualizer(isAnimating: isPlaying && !reduceMotion, tint: .primary)
                    } else {
                        Text(String(number)).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 28)
                .accessibilityHidden(true)
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(MusicFormat.duration(track.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize()
            }
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("music.detail.track.\(track.id)")
    }
}

private struct MobileMusicDetailScaffold<Actions: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let metadata: String
    let artworkURL: URL?
    let artworkID: String
    let artworkFallback: (@Sendable () async -> URL?)?
    let isArtist: Bool
    var artworkPlaceholder: String = "opticaldisc"
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content
    @Environment(\.themePalette) private var theme
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resolvedArtwork: ResolvedArtwork?
    @State private var colors = MusicDetailColors.neutral

    private var isBlack: Bool { theme == .pureBlack }
    private var heroColor: Color { isBlack ? .black : colors.hero }
    private var deepColor: Color { isBlack ? .black : colors.deep }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize
            ScrollView {
                VStack(spacing: 0) {
                    if isArtist && !wide && !isBlack && !dynamicTypeSize.isAccessibilitySize {
                        artistHero(width: geometry.size.width, topInset: geometry.safeAreaInsets.top)
                    } else {
                        framedHero(width: geometry.size.width, wide: wide, topInset: geometry.safeAreaInsets.top)
                    }
                    content()
                        .padding(.horizontal, wide ? 32 : 20)
                        .padding(.top, 24)
                        .padding(.bottom, 32)
                        .frame(maxWidth: 1_000)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .background(alignment: .top) {
                            LinearGradient(colors: [heroColor, deepColor], startPoint: .top, endPoint: .bottom)
                                .frame(height: 420)
                                .allowsHitTesting(false)
                        }
                }
            }
            .coordinateSpace(name: "musicDetailScroll")
            .modifier(MusicDetailScrollEdge())
            // The hero paints under native chrome; its foreground clears the top inset.
            .ignoresSafeArea(.container, edges: .top)
            .background(deepColor.ignoresSafeArea())
        }
        .environment(\.colorScheme, .dark)
        .environment(\.themePalette, isBlack ? .pureBlack : .dark)
        .tint(.musicPlayerAccent)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: PaletteRequest(resolution: resolvedArtwork, identity: artworkID, policy: artworkPolicy.forArea(.music).identity, isBlack: isBlack)) {
            colors = .neutral
            guard !isBlack, let resolvedArtwork,
                  resolvedArtwork.policy == artworkPolicy.forArea(.music).identity,
                  let reference = resolvedArtwork.reference,
                  let image = await ArtworkImageCache.shared.image(for: reference, variant: .heroBackdrop),
                  !Task.isCancelled else { return }
            colors = MusicDetailColors(image: image)
        }
    }

    private func artwork(cornerRadius: CGFloat) -> some View {
        MusicArtworkImage(
            url: artworkURL,
            systemPlaceholder: isArtist ? "music.mic" : artworkPlaceholder,
            cornerRadius: cornerRadius,
            variant: .heroBackdrop,
            showsMediaEdge: false,
            asyncFallbackURL: artworkFallback,
            pinIdentity: artworkID,
            onResolveReference: {
                resolvedArtwork = ResolvedArtwork(reference: $0, policy: artworkPolicy.forArea(.music).identity)
            }
        )
        .accessibilityHidden(true)
    }

    private func framedHero(width: CGFloat, wide: Bool, topInset: CGFloat) -> some View {
        let edge = wide ? min(width * 0.32, 300) : min(240, max(0, width - 80))
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 28))
            : AnyLayout(VStackLayout(spacing: 24))
        return layout {
            artwork(cornerRadius: isArtist ? edge / 2 : 14)
                .frame(width: edge, height: edge)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            heading(centered: !wide)
        }
        .padding(.horizontal, wide ? 32 : 20)
        .padding(.top, topInset + 20)
        .padding(.bottom, 8)
        .frame(maxWidth: 1_000)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [wide ? deepColor : heroColor, heroColor],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private func artistHero(width: CGFloat, topInset: CGFloat) -> some View {
        heading(centered: false)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 460 + topInset, alignment: .bottomLeading)
            .background {
                GeometryReader { geometry in
                    let pull = reduceMotion ? 0 : max(0, geometry.frame(in: .named("musicDetailScroll")).minY)
                    artwork(cornerRadius: 0)
                        .frame(width: width, height: geometry.size.height + pull)
                        .clipped()
                        .overlay {
                            LinearGradient(
                                stops: [.init(color: .black.opacity(0.15), location: 0),
                                        .init(color: heroColor.opacity(0.8), location: 0.55),
                                        .init(color: heroColor, location: 1)],
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                        .offset(y: -pull)
                }
            }
            .background(heroColor)
    }

    private func heading(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            Text(title).font(.title.bold()).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("music.detail.title")
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.title3).foregroundStyle(.white.opacity(0.8))
            }
            if !metadata.isEmpty {
                Text(metadata).font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            actions().padding(.top, 12).frame(maxWidth: 520)
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private struct ResolvedArtwork: Equatable {
        let reference: ArtworkReference?
        let policy: String
    }

    private struct PaletteRequest: Equatable {
        let resolution: ResolvedArtwork?
        let identity: String
        let policy: String
        let isBlack: Bool
    }
}

private struct MusicDetailScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

struct MusicDetailColors {
    let hero: Color
    let deep: Color

    static let neutral = MusicDetailColors(hero: Color(white: 0.14), deep: Color(white: 0.07))

    private init(hero: Color, deep: Color) {
        self.hero = hero
        self.deep = deep
    }

    init(image: UIImage) {
        guard let prominent = ArtworkColorExtractor.palette(from: image, maxColors: 1).first else {
            self = .neutral
            return
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(prominent).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            self = .neutral
            return
        }
        hero = Color(hue: hue, saturation: min(1, saturation * 1.15), brightness: min(brightness, 0.36))
        deep = Color(hue: hue, saturation: min(saturation, 0.6), brightness: 0.18)
    }
}
#endif
