#if canImport(SwiftUI)
import SeerService
import SwiftUI

public extension View {
    /// Attach to the whole onboarding flow so page transitions retain prepared results.
    func prepareSeerrSetup(_ service: SeerService) -> some View {
        modifier(SeerSetupPreparation(service: service))
    }
}

private struct SeerSetupPreparation: ViewModifier {
    let service: SeerService

    func body(content: Content) -> some View {
        content
            .task(id: service.setupDiscoveryScope) {
                guard !service.isConfigured,
                      !service.setupDiscoveryScope.sources.isEmpty
                        || service.setupDiscoveryScope.preferredURL != nil else { return }
                service.prepareSetup()
            }
            .onDisappear { service.setupDiscovery.cancel() }
    }
}
#endif
