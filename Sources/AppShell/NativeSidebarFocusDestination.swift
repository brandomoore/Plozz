#if os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

/// Keep native chrome, but make cold entry use the same content-first request as custom navigation.
struct NativeSidebarNavigation<Content: View>: View {
    let selection: NavigationRailDestination
    let handoff: NavigationDestinationFocusHandoff
    let content: Content
    @State private var hasStarted = false
    @State private var startupDestination: NavigationRailDestination?
    @State private var contentRequest: UInt64?
    @Environment(\.navigationStartupFocusAllowed) private var startupFocusAllowed

    var body: some View {
        NavigationRailFocusHost { _ in
            content.background {
                NavigationContentFocusRequester(
                    request: contentRequest,
                    onCompleted: { request, _ in
                        guard contentRequest == request else { return }
                        contentRequest = nil
                        startupDestination = nil
                    },
                    isStartupRequest: startupDestination != nil && startupFocusAllowed,
                    onStartupCancelled: {
                        startupDestination = nil
                        handoff.cancel()
                    }
                )
            }
        }
        // The native TabView owns overscan insets; its focus host must fill the window.
        .ignoresSafeArea()
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            startupDestination = selection
            if startupFocusAllowed { handoff.begin(selection) }
        }
        .onChange(of: startupFocusAllowed) { _, allowed in
            guard startupDestination == selection else { return }
            contentRequest = nil
            handoff.cancel()
            if allowed { handoff.begin(selection) }
        }
        .onChange(of: handoff.request) { previous, current in
            if startupFocusAllowed, current == nil, previous?.destination == startupDestination,
               startupDestination == selection {
                contentRequest = previous?.generation
            }
        }
        .onChange(of: selection) { _, _ in
            startupDestination = nil
            contentRequest = nil
        }
        .onDisappear {
            if startupFocusAllowed { startupDestination = nil }
            contentRequest = nil
        }
    }
}

/// Native TabView owns the transition; only the presented page may accept focus.
struct NativeSidebarFocusDestination<Content: View>: View {
    let destination: NavigationRailDestination
    let selection: NavigationRailDestination
    let handoff: NavigationDestinationFocusHandoff
    let content: Content

    var body: some View {
        content
            .navigationEntryFocus(selection == destination ? .fallback : nil)
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
