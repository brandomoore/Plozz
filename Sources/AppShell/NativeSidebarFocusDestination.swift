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
                    isStartupRequest: startupDestination != nil,
                    onStartupCancelled: {
                        startupDestination = nil
                        handoff.cancel()
                    }
                )
            }
        }
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            startupDestination = selection
            handoff.begin(selection)
        }
        .onChange(of: handoff.completedRequest) { _, completed in
            if let completed, completed.destination == selection, completed.focusTarget == .content,
               startupDestination == selection || selection == .home {
                contentRequest = completed.generation
            }
        }
        .onChange(of: selection) { _, _ in
            startupDestination = nil
            contentRequest = nil
        }
        .onDisappear {
            startupDestination = nil
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
