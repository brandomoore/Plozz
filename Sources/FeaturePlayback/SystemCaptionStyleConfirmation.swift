#if canImport(SwiftUI)
import Observation
import SwiftUI

@MainActor
@Observable
final class SystemCaptionStyleConfirmation {
    var isPresented = false
    @ObservationIgnored private var pendingEnable = false

    func request(_ enabled: Bool, currentlyMatching: Bool, apply: (Bool) -> Void) {
        guard enabled != currentlyMatching else { return }
        if enabled {
            pendingEnable = true
            isPresented = true
        }
        else { apply(false) }
    }

    func confirm(apply: (Bool) -> Void) {
        guard pendingEnable else { return }
        pendingEnable = false
        isPresented = false
        apply(true)
    }

    func cancel() {
        pendingEnable = false
        isPresented = false
    }
}

struct SystemCaptionStyleConfirmationDialog: ViewModifier {
    @Bindable var confirmation: SystemCaptionStyleConfirmation
    let apply: (Bool) -> Void

    func body(content: Content) -> some View {
        content.alert("Use System Caption Style?", isPresented: $confirmation.isPresented) {
            Button("Cancel", role: .cancel) { confirmation.cancel() }
            Button("Use System Style", role: .destructive) { confirmation.confirm(apply: apply) }
        } message: {
            Text("This will overwrite your custom subtitle appearance with your device's system caption settings.")
        }
    }
}
#endif
