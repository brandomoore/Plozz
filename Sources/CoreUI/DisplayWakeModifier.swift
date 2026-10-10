#if canImport(UIKit)
import SwiftUI

@MainActor
struct DisplayWakeModifier: ViewModifier {
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var lease = DisplayWakeLease()

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updateLease()
            }
            .onChange(of: active) { _, _ in updateLease() }
            .onChange(of: scenePhase) { _, _ in updateLease() }
            .onDisappear {
                isVisible = false
                lease.allowSleep()
            }
    }

    private func updateLease() {
        lease.keepAwake(active && isVisible && scenePhase == .active)
    }
}

public extension View {
    /// Prevents idle sleep only while this foreground surface has active work.
    func keepsDisplayAwake(while active: Bool) -> some View {
        modifier(DisplayWakeModifier(active: active))
    }
}
#endif
