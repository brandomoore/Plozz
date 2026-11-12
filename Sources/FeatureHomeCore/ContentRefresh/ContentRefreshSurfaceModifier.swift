#if canImport(SwiftUI)
import SwiftUI

public extension View {
    func contentRefreshSurface(
        id: ContentRefreshSurfaceID?,
        isVisible: Bool,
        perform: @escaping @MainActor (ContentRefreshRequest) async -> Void
    ) -> some View {
        modifier(ContentRefreshSurfaceModifier(id: id, isVisible: isVisible, perform: perform))
    }
}

private struct ContentRefreshSurfaceModifier: ViewModifier {
    @Environment(ContentRefreshCoordinator.self) private var coordinator: ContentRefreshCoordinator?
    let id: ContentRefreshSurfaceID?
    let isVisible: Bool
    let perform: @MainActor (ContentRefreshRequest) async -> Void
    @State private var registration: ContentRefreshRegistration?
    @State private var isMounted = false

    private var currentRequest: ContentRefreshRequest? {
        guard isMounted, isVisible, let registration,
              registration.surface == id,
              let coordinator, let request = coordinator.request,
              request.registrationID == registration.id, coordinator.isCurrent(request) else { return nil }
        return request
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isMounted = true
                updateRegistration()
            }
            .onDisappear {
                isMounted = false
                if let registration { coordinator?.surfaceDidDisappear(registration) }
            }
            .onChange(of: isVisible) { _, _ in updateRegistration() }
            .onChange(of: id) { _, _ in updateRegistration() }
            .onChange(of: coordinator?.resetRevision) { _, _ in updateRegistration() }
            .task(id: currentRequest) { [request = currentRequest] in
                guard let request, !Task.isCancelled,
                      coordinator?.isCurrent(request) == true else { return }
                await perform(request)
            }
    }

    private func updateRegistration() {
        guard let coordinator else { return }
        if let registration, registration.surface != id {
            coordinator.surfaceDidDisappear(registration)
            self.registration = nil
        }
        if registration == nil, let id {
            registration = ContentRefreshRegistration(surface: id)
        }
        guard let registration else { return }
        if isMounted && isVisible {
            coordinator.surfaceDidBecomeVisible(registration)
        } else {
            coordinator.surfaceDidDisappear(registration)
        }
    }
}
#endif
