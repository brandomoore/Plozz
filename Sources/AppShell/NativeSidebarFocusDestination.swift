#if os(tvOS)
import CoreModels
import SwiftUI

/// Native TabView owns the transition; only the presented page may accept focus.
struct NativeSidebarFocusDestination<Content: View>: View {
    let destination: NavigationRailDestination
    let selection: NavigationRailDestination
    let handoff: NavigationDestinationFocusHandoff
    let content: Content

    var body: some View {
        content
            .disabled(selection != destination || handoff.isWaiting)
            .background {
                NavigationDestinationPresentationAnchor(
                    destination: destination,
                    request: handoff.request,
                    onPresented: { request in
                        guard selection == request.destination else { return }
                        _ = handoff.complete(request)
                    }
                )
            }
    }
}
#endif
