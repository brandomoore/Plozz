#if canImport(SwiftUI) && canImport(UIKit)
import CoreUI
import CoreModels
import CoreNetworking
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
    var onOptionsPresented: (Bool) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    @Environment(\.playerCardMetrics) private var metrics
    @State private var selection: SongSelection?
    @State private var optionsPresented = false

    private struct SongSelection: Identifiable {
        let id = UUID()
        let song: SongMatch
    }

    private var allowsSongFocus: Bool {
        #if os(tvOS)
        if optionsPresented { return true }
        switch focus {
        case .infoRestart, .infoPrev, .infoNext, .infoStats, .infoSong: return true
        default: return false
        }
        #else
        true
        #endif
    }

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
                PlayerSongCard(song: song, focus: $focus) {
                    optionsPresented = true
                    selection = SongSelection(song: song)
                }
                    .disabled(!allowsSongFocus)
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
        .plozzSheet(item: $selection, onDismiss: {
            focus = .button(.info)
            optionsPresented = false
        }) {
            SongServiceChooser(song: $0.song)
        }
        .onChange(of: optionsPresented) { _, presented in onOptionsPresented(presented) }
    }
}

struct PlayerSongCard: View {
    let song: SongMatch
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    let onSelect: () -> Void
    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.playerControlForeground) private var foreground

    static func artworkSize(for metrics: PlayerCardMetrics) -> CGFloat {
        metrics.isVertical ? 112 : metrics.contentHeight
    }

    var body: some View {
        Button(action: onSelect) {
            label
                #if !os(tvOS)
                .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius, mediaGlass: true))
                #endif
        }
        #if os(tvOS)
        .buttonStyle(PlayerOverVideoCardStyle(
            focused: focus == .infoSong, cornerRadius: metrics.panelCornerRadius,
            focusScale: metrics.isVertical ? 1 : 1.10,
            pressScale: metrics.isVertical ? 0.98 : 1, mediaGlass: true
        ))
        #else
        .buttonStyle(.plain)
        #endif
        .focused($focus, equals: .infoSong)
        .plozzFocusSection()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([song.title, song.artist].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("player-song")
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

struct SongServiceLink: Identifiable, Equatable {
    enum Service: String {
        case appleMusic, spotify, youtube

        var title: LocalizedStringResource {
            switch self {
            case .appleMusic: "Apple Music"
            case .spotify: "Search Spotify"
            case .youtube: "Search YouTube"
            }
        }
    }
    let service: Service
    let url: URL
    var id: Service { service }

    static func links(for song: SongMatch) -> [Self] {
        let query = [song.title, song.artist].compactMap { $0 }.joined(separator: " ")
        var youtube = URLComponents(string: "https://www.youtube.com/results")!
        youtube.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return [
            song.appleMusicURL.map { Self(service: .appleMusic, url: $0) },
            Self(service: .spotify, url: URL(string: "https://open.spotify.com/search")!.appending(component: query)),
            Self(service: .youtube, url: youtube.url!)
        ].compactMap { $0 }
    }
}

private struct SongServiceChooser: View {
    private struct Request {
        let id = UUID()
        let link: SongServiceLink
    }
    let song: SongMatch
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var request: Request?
    @State private var phoneLink: SongServiceLink?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text(verbatim: song.title).font(.title2)
                    if let artist = song.artist { Text(verbatim: artist).foregroundStyle(.secondary) }
                    ViewThatFits {
                        HStack { serviceButtons }
                        VStack { serviceButtons }
                    }
                    if let phoneLink {
                        Text("This app couldn’t open the link. Scan with your phone.")
                            .multilineTextAlignment(.center)
                        QRCodeView(phoneLink.url.absoluteString)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .frame(width: 260, height: 260)
                            .accessibilityIdentifier("song-service-qr")
                        Text(phoneLink.service.title).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            }
            .navigationTitle("Open song")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: request?.id) {
            guard let link = request?.link else { return }
            #if os(tvOS)
            let opened = await UIApplication.shared.open(link.url, options: [.universalLinksOnly: true])
            guard !Task.isCancelled else { return }
            if !opened {
                PlozzLog.app.info("Song service has no available app handler; showing phone link")
                phoneLink = link
            }
            #else
            openURL(link.url) { accepted in
                if !accepted {
                    PlozzLog.app.error("Unable to open song service link")
                    phoneLink = link
                }
            }
            #endif
        }
    }

    private var serviceButtons: some View {
        ForEach(SongServiceLink.links(for: song)) { link in
            Button {
                phoneLink = nil
                request = Request(link: link)
            } label: { Text(link.service.title) }
                .accessibilityIdentifier("song-service-\(link.service.rawValue)")
        }
    }
}
#endif
