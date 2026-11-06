#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import CoreModels

struct DiscMenuPlayerContent: View {
    let model: PlayerViewModel
    let state: DiscMenuPlaybackState
    let dismiss: () -> Void
    let showVideos: () -> Void
    @State private var showsActions = false
    @FocusState private var menuFocused: Bool

    var body: some View {
        ZStack {
            VideoSurfaceContainer(
                engine: model.videoEngine, zoom: .init(),
                fitsInsideSafeArea: false
            )
            .ignoresSafeArea()
            DiscMenuArtwork(state: state)
            if let failure = state.failure {
                VStack(spacing: 24) {
                    Text("Disc menu unavailable").font(.title2)
                    Text(verbatim: failure).multilineTextAlignment(.center)
                    Button("Retry") { model.retryDiscMenu() }
                    Button("Play video") { model.playVideoWithoutMenus() }
                    Button("Disc videos", action: showVideos)
                    Button("Try another region") { tryAnotherRegion() }
                    Button("Close", action: dismiss)
                }
                .padding(40)
                .frame(maxWidth: 800)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                #if os(tvOS)
                .onExitCommand(perform: dismiss)
                #endif
            } else {
                #if os(tvOS)
                Button { state.sendKey(16) } label: {
                    Color.clear.contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select")
                    .accessibilityIdentifier("disc-menu-select")
                    .focused($menuFocused)
                    .onMoveCommand {
                        switch $0 {
                        case .up: state.sendKey(12)
                        case .down: state.sendKey(13)
                        case .left: state.sendKey(14)
                        case .right: state.sendKey(15)
                        @unknown default: break
                        }
                    }
                    .onPlayPauseCommand { model.togglePlayPause() }
                    .onExitCommand { showsActions = true }
                    .onAppear { menuFocused = true }
                #else
                DiscMenuTouchControls(
                    state: state, showActions: { showsActions = true }
                )
                #endif
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = state.notice, state.failure == nil {
                Text(verbatim: notice).padding().background(.regularMaterial)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog("Disc menu", isPresented: $showsActions, titleVisibility: .visible) {
            Button("Open disc menu") { state.openMenu() }
            Button("Play video") { model.playVideoWithoutMenus() }
            Button("Disc videos", action: showVideos)
            Button("Try another region") { tryAnotherRegion() }
            Button("Close", role: .destructive, action: dismiss)
        } message: {
            Text("Disc-menu playback does not update watched or resume progress.")
        }
    }

    private func tryAnotherRegion() {
        model.retryDiscMenu(region: state.region == 1 ? 2 : state.region == 2 ? 4 : 1)
    }

}

struct DiscMenuArtwork: View {
    let state: DiscMenuPlaybackState

    var body: some View {
        if let image = state.image {
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    #if os(iOS)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded {
                        state.activate(at: $0.location, in: CGRect(origin: .zero, size: geometry.size))
                    })
                    .accessibilityHidden(true)
                    #else
                    .allowsHitTesting(false)
                    #endif
            }
            .ignoresSafeArea()
        }
    }
}

#if os(iOS)
struct DiscMenuTouchControls: View {
    let state: DiscMenuPlaybackState
    let showActions: () -> Void
    @State private var hasPresentedNavigation = false

    var body: some View {
        VStack {
            if !state.showsLoadingIndicator {
                Spacer()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 44, height: 44)
                        Spacer(minLength: 0)
                        navigation
                        Spacer(minLength: 0)
                        actions
                    }
                    VStack {
                        navigation
                        HStack { Spacer(); actions }
                    }
                }
            }
        }
        .modifier(PlayerTouchChromePadding())
        .onChange(of: state.isMenuVisible, initial: true) { _, visible in
            if visible { hasPresentedNavigation = true }
        }
    }

    @ViewBuilder private var navigation: some View {
        if hasPresentedNavigation {
            PlayerGlassControlGroup {
                HStack(spacing: 0) {
                    DiscMenuTouchButton(title: "Up", symbol: "arrow.up") { state.sendKey(12) }
                    DiscMenuTouchButton(title: "Down", symbol: "arrow.down") { state.sendKey(13) }
                    DiscMenuTouchButton(title: "Left", symbol: "arrow.left") { state.sendKey(14) }
                    DiscMenuTouchButton(title: "Right", symbol: "arrow.right") { state.sendKey(15) }
                    DiscMenuTouchButton(title: "Select", symbol: "circle") { state.sendKey(16) }
                }
            }
            .disabled(!state.isMenuVisible)
        }
    }

    private var actions: some View {
        PlayerGlassControlGroup {
            DiscMenuTouchButton(title: "Disc menu", symbol: "opticaldisc", action: showActions)
        }
    }
}

private struct DiscMenuTouchButton: View {
    let title: LocalizedStringResource
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .imageScale(.large)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("disc-menu-control-\(symbol)")
    }
}
#endif
#endif
