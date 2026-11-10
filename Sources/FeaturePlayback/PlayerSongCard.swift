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
        }, style: SongServiceChooser.presentationStyle) {
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
        case spotify, appleMusic, youtubeMusic, amazonMusic, deezer, tidal

        var title: LocalizedStringResource {
            switch self {
            case .appleMusic: "Apple Music"
            case .spotify: "Search Spotify"
            case .youtubeMusic: "Search YouTube Music"
            case .amazonMusic: "Search Amazon Music"
            case .deezer: "Search Deezer"
            case .tidal: "Search TIDAL"
            }
        }

        var image: Image {
            switch self {
            case .appleMusic: Image("SongAppleMusic", bundle: .module)
            case .spotify: Image("SongSpotify", bundle: .module)
            case .youtubeMusic: Image("SongYouTubeMusic", bundle: .module)
            case .amazonMusic: Image(systemName: "music.note")
            case .deezer: Image("SongDeezer", bundle: .module)
            case .tidal: Image("SongTidal", bundle: .module)
            }
        }
    }
    let service: Service
    let url: URL
    var id: Service { service }

    static func links(for song: SongMatch) -> [Self] {
        let query = [song.title, song.artist].compactMap { $0 }.joined(separator: " ")
        var youtube = URLComponents(string: "https://music.youtube.com/search")!
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        youtube.percentEncodedQueryItems = [
            URLQueryItem(name: "q", value: query.addingPercentEncoding(withAllowedCharacters: unreserved))
        ]
        return [
            Self(service: .spotify, url: URL(string: "https://open.spotify.com/search")!.appending(component: query)),
            song.appleMusicURL.map { Self(service: .appleMusic, url: $0) },
            Self(service: .youtubeMusic, url: youtube.url!),
            Self(service: .amazonMusic, url: URL(string: "https://music.amazon.com/search")!.appending(component: query)),
            Self(service: .deezer, url: URL(string: "https://www.deezer.com/search")!.appending(component: query)),
            Self(service: .tidal, url: URL(string: "https://listen.tidal.com/search")!.appending(component: query))
        ].compactMap { $0 }
    }
}

struct SongServiceChooser: View {
    private struct Request {
        let id = UUID()
        let link: SongServiceLink
    }
    let song: SongMatch
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var request: Request?
    @State private var phoneLink: SongServiceLink?
    @State private var contentHeight: CGFloat = 0
    #if os(iOS)
    @State private var presentationInsets: CGFloat = 0
    #endif

    static var presentationStyle: PlozzSheetStyle {
        #if os(tvOS)
        .floatingCard
        #else
        .standard
        #endif
    }

    var body: some View {
        presentation
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

    @ViewBuilder private var presentation: some View {
        #if os(tvOS)
        GeometryReader { geometry in
            ZStack {
                PlozzDialogBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            PlozzDialogHeading(Text("Open song"))
                            Spacer()
                            Button("Done") { dismiss() }
                                .buttonStyle(.bordered)
                        }
                        SongServiceChooserContent(song: song, phoneLink: phoneLink, select: select)
                            .padding(12)
                    }
                    .padding(32)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    width: min(phoneLink == nil ? 820 : 1180, max(0, geometry.size.width - 96)),
                    height: min(max(contentHeight, 300), max(0, geometry.size.height - 96))
                )
                .plozzSurface(.overlay, cornerRadius: 32)
                .accessibilityIdentifier("song-service-chooser")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand { dismiss() }
        #else
        NavigationStack {
            ScrollView {
                SongServiceChooserContent(song: song, phoneLink: phoneLink, select: select)
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.safeAreaInsets.top + $0.safeAreaInsets.bottom
            } action: {
                presentationInsets = $0
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Open song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(idealHeight: contentHeight + presentationInsets)
        .presentationDetents([.height(max(300, contentHeight + presentationInsets)), .large])
        .presentationDragIndicator(.visible)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .accessibilityIdentifier("song-service-chooser")
        #endif
    }

    private func select(_ link: SongServiceLink) {
        phoneLink = nil
        request = Request(link: link)
    }
}

struct SongServiceChooserContent: View {
    let song: SongMatch
    let phoneLink: SongServiceLink?
    let select: (SongServiceLink) -> Void

    var body: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 32) {
            SongServiceOptions(song: song, select: select)
            if let phoneLink {
                SongServicePhoneLink(link: phoneLink)
                    .frame(width: 300)
            }
        }
        #else
        VStack(alignment: .leading, spacing: 24) {
            SongServiceOptions(song: song, select: select)
            if let phoneLink {
                SongServicePhoneLink(link: phoneLink)
            }
        }
        #endif
    }
}

private struct SongServiceOptions: View {
    let song: SongMatch
    let select: (SongServiceLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SongServiceHeader(song: song)
                #if os(tvOS)
                .padding(.vertical, 12)
                #endif
            VStack(spacing: 12) {
                ForEach(SongServiceLink.links(for: song)) { link in
                    SongServiceButton(link: link) { select(link) }
                }
            }
        }
    }
}

private struct SongServiceHeader: View {
    let song: SongMatch
    @ScaledMetric(relativeTo: .title3) private var artworkSize: CGFloat = 88
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(tvOS)
        let artworkSpacing: CGFloat = 32
        #else
        let artworkSpacing: CGFloat = 20
        #endif
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: artworkSpacing))
        layout {
            AsyncImage(url: song.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note")
                    .font(.title)
                    .plozzForeground(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
            .frame(width: min(artworkSize, 112), height: min(artworkSize, 112))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: song.title)
                    .font(.headline)
                    .plozzForeground(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let artist = song.artist {
                    Text(verbatim: artist)
                        .font(.subheadline)
                        .plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SongServiceButton: View {
    let link: SongServiceLink
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 28

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                link.service.image
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)
                Text(link.service.title)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.body)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .plozzActionButton(role: .secondary)
        #endif
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityIdentifier("song-service-\(link.service.rawValue)")
    }
}

private struct SongServicePhoneLink: View {
    let link: SongServiceLink

    var body: some View {
        VStack(spacing: 16) {
            Text("This app couldn’t open the link. Scan with your phone.")
                .font(.callout)
                .plozzForeground(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            QRCodeView(link.url.absoluteString)
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .frame(width: 260, height: 260)
                .accessibilityIdentifier("song-service-qr")
            Text(link.service.title).font(.caption).plozzForeground(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
