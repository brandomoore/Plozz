#if canImport(SwiftUI)
import CoreModels
import SwiftUI

@MainActor
private struct HeroExposureObserver: ViewModifier {
    private struct ExposureID: Equatable {
        var itemID: String?
        var scopeID: ObjectIdentifier?
        var isVisible: Bool
    }

    let item: MediaItem?
    let isVisible: Bool
    let scopeID: ObjectIdentifier?
    let onExposure: @MainActor (MediaItem) -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let eligible = isVisible && scenePhase == .active
        content.task(id: ExposureID(
            itemID: item?.id,
            scopeID: scopeID,
            isVisible: eligible
        )) {
            guard eligible, let item else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onExposure(item)
        }
    }
}

public extension View {
    @MainActor
    func trackHeroExposure(
        item: MediaItem?,
        isVisible: Bool,
        scopeID: ObjectIdentifier? = nil,
        onExposure: @escaping @MainActor (MediaItem) -> Void
    ) -> some View {
        modifier(HeroExposureObserver(
            item: item,
            isVisible: isVisible,
            scopeID: scopeID,
            onExposure: onExposure
        ))
    }
}
#endif
