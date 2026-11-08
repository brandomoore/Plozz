#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct DiscMenuPlayerContent: View {
    let model: PlayerViewModel
    let state: DiscMenuPlaybackState
    let dismiss: () -> Void
    let showVideos: () -> Void
    @State private var showsActions = false
    @State private var pendingAction: (() -> Void)?
    @FocusState private var menuFocused: Bool
    @FocusState private var actionFocused: Bool

    var body: some View {
        ZStack {
            VideoSurfaceContainer(
                engine: model.videoEngine, zoom: .init(),
                fitsInsideSafeArea: false
            )
            .ignoresSafeArea()
            DiscMenuArtwork(state: state)
            if let failure = state.failure {
                PlaybackFailureView(
                    title: "Disc menu unavailable", message: "\(failure)", report: nil
                ) {
                    Button("Retry") { model.retryDiscMenu() }.plozzActionButton()
                    Button("Play video") { model.playVideoWithoutMenus() }.discPlaybackActionButton()
                    Button("Disc videos", action: showVideos).discPlaybackActionButton()
                    Button("Try another region") { tryAnotherRegion() }.discPlaybackActionButton()
                    Button("Close", action: dismiss).discPlaybackActionButton()
                }
                #if os(tvOS)
                .onExitCommand(perform: dismiss)
                #endif
            } else {
                #if os(tvOS)
                if !showsActions && !model.showsDiscVideos {
                    Button { state.sendKey(16) } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(DiscMenuInputStyle())
                    .focusEffectDisabled()
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
                }
                #else
                DiscMenuTouchControls(state: state) {
                    Section {
                        Button("Open disc menu", systemImage: "opticaldisc") { state.openMenu() }
                        Button("Play video", systemImage: "play") { model.playVideoWithoutMenus() }
                        Button("Disc videos", systemImage: "list.bullet", action: showVideos)
                        Button("Try another region", systemImage: "globe", action: tryAnotherRegion)
                    } header: {
                        Text("Disc-menu playback does not update watched or resume progress.")
                    }
                    Section {
                        Button("Close player", systemImage: "xmark", action: dismiss)
                    }
                }
                #endif
            }
        }
        #if os(tvOS)
        .discPlaybackSheet(isPresented: $showsActions, onDismiss: performPendingAction) {
            DiscPlaybackDialog(title: "Disc menu", close: { showsActions = false }) {
                Text("Disc-menu playback does not update watched or resume progress.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                actionButton("Open disc menu") { state.openMenu() }
                    .focused($actionFocused)
                actionButton("Play video") { model.playVideoWithoutMenus() }
                actionButton("Disc videos", action: showVideos)
                actionButton("Try another region", action: tryAnotherRegion)
                actionButton("Close player", action: dismiss)
            }
            .defaultFocus($actionFocused, true, priority: .userInitiated)
        }
        #endif
    }

    #if os(tvOS)
    private struct DiscMenuInputStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }
    #endif

    private func tryAnotherRegion() {
        model.retryDiscMenu(region: state.region == 1 ? 2 : state.region == 2 ? 4 : 1)
    }

    private func actionButton(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button { performAfterDismissal(action) } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .discPlaybackActionButton()
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }

    private func performAfterDismissal(_ action: @escaping () -> Void) {
        pendingAction = action
        showsActions = false
    }

    private func performPendingAction() {
        let action = pendingAction
        pendingAction = nil
        menuFocused = true
        action?()
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
struct DiscMenuTouchControls<Actions: View>: View {
    let state: DiscMenuPlaybackState
    @ViewBuilder let menuActions: () -> Actions
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
            Menu(content: menuActions) {
                Image(systemName: "opticaldisc")
                    .font(.title3)
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
            .accessibilityLabel("Disc menu")
            .accessibilityIdentifier("disc-menu-control-opticaldisc")
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
