#if canImport(SwiftUI)
import SwiftUI

/// Registers one visible content surface with the shared refresh coordinator.
/// The view owns only the action it performs; the coordinator owns timing and
/// foreground/background decisions.
public extension View {
    func contentRefreshSurface(
        id: ContentRefreshSurfaceID,
        isVisible: Bool,
        perform: @escaping @MainActor (ContentRefreshRequest) async -> Void
    ) -> some View {
        modifier(ContentRefreshSurfaceModifier(
            id: id,
            isVisible: isVisible,
            perform: perform
        ))
    }
}

private struct ContentRefreshSurfaceModifier: ViewModifier {
    @Environment(ContentRefreshCoordinator.self) private var coordinator: ContentRefreshCoordinator?

    let id: ContentRefreshSurfaceID
    let isVisible: Bool
    let perform: @MainActor (ContentRefreshRequest) async -> Void
    @State private var registeredID: ContentRefreshSurfaceID?

    func body(content: Content) -> some View {
        content
            .onAppear { updateRegistration() }
            .onDisappear { clearRegistration() }
            .onChange(of: isVisible) { _, _ in updateRegistration() }
            .onChange(of: id) { _, _ in updateRegistration() }
            .onChange(of: coordinator?.resetRevision) { _, _ in updateRegistration() }
            .onChange(of: coordinator?.request) { _, request in
                guard let request, request.surface == id else { return }
                Task { await perform(request) }
            }
    }

    private func updateRegistration() {
        guard let coordinator else { return }
        if let registeredID, registeredID != id || !isVisible {
            coordinator.unregister(registeredID)
            self.registeredID = nil
        }
        guard isVisible else { return }
        coordinator.register(id)
        coordinator.surfaceDidBecomeVisible(id)
        registeredID = id
    }

    private func clearRegistration() {
        guard let coordinator, let registeredID else { return }
        coordinator.surfaceDidDisappear(registeredID)
        coordinator.unregister(registeredID)
        self.registeredID = nil
    }
}
#endif
