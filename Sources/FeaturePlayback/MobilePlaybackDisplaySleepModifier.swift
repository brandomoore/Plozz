enum MobilePlaybackDisplaySleepPolicy {
    static func shouldStayAwake(
        playbackActive: Bool, isVisible: Bool, sceneIsActive: Bool
    ) -> Bool {
        playbackActive && isVisible && sceneIsActive
    }
}

#if os(iOS)
import SwiftUI

@MainActor
struct MobilePlaybackDisplaySleepModifier: ViewModifier {
    let playbackActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var wakeLease: LiveChannelWakeLease

    init(playbackActive: Bool, wakeLease: LiveChannelWakeLease? = nil) {
        self.playbackActive = playbackActive
        _wakeLease = State(initialValue: wakeLease ?? LiveChannelWakeLease())
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updateWakeLease()
            }
            .onChange(of: playbackActive) { _, _ in updateWakeLease() }
            .onChange(of: scenePhase) { _, _ in updateWakeLease() }
            .onDisappear {
                isVisible = false
                wakeLease.allowSleep()
            }
    }

    private func updateWakeLease() {
        wakeLease.keepAwake(MobilePlaybackDisplaySleepPolicy.shouldStayAwake(
            playbackActive: playbackActive,
            isVisible: isVisible,
            sceneIsActive: scenePhase == .active
        ))
    }
}
#endif
