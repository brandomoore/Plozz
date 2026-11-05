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
            if let image = state.image {
                Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea().allowsHitTesting(false)
            }
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
                VStack {
                    HStack {
                        Button("Close", action: dismiss)
                        Spacer()
                        Button("Disc menu") { showsActions = true }
                    }
                    Spacer()
                    if state.isMenuVisible {
                        HStack(spacing: 20) {
                            key("Up", symbol: "arrow.up", code: 12)
                            key("Down", symbol: "arrow.down", code: 13)
                            key("Left", symbol: "arrow.left", code: 14)
                            key("Right", symbol: "arrow.right", code: 15)
                            key("Select", symbol: "checkmark", code: 16)
                        }
                    }
                }.padding()
                #endif
            }
        }
        .overlay {
            if state.isOpening && state.failure == nil && (!model.showBringUpSpinner || state.image != nil) {
                ProgressView()
                    .allowsHitTesting(false)
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

    #if !os(tvOS)
    private func key(_ title: LocalizedStringResource, symbol: String, code: UInt32) -> some View {
        Button { state.sendKey(code) } label: { Label(title, systemImage: symbol) }
            .labelStyle(.iconOnly)
    }
    #endif
}
#endif
