#if canImport(SwiftUI)
import CoreModels
import SwiftUI

private struct DetailPlaybackPreparationKey: EnvironmentKey {
    static let defaultValue = DetailPlaybackPreparationEnvironment.disabled
}

private struct DetailPlaybackPreparationAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    var detailPlaybackPreparation: DetailPlaybackPreparationEnvironment {
        get { self[DetailPlaybackPreparationKey.self] }
        set { self[DetailPlaybackPreparationKey.self] = newValue }
    }

    var detailPlaybackPreparationAllowed: Bool {
        get { self[DetailPlaybackPreparationAllowedKey.self] }
        set { self[DetailPlaybackPreparationAllowedKey.self] = newValue }
    }
}

private struct DetailPlaybackPreparationModifier: ViewModifier {
    let item: MediaItem?
    let isActive: Bool
    let coordinator: DetailPlaybackPreparationCoordinator
    @Environment(\.detailPlaybackPreparation) private var preparation
    @Environment(\.detailPlaybackPreparationAllowed) private var allowed
    @Environment(\.scenePhase) private var scenePhase

    private struct Input: Equatable {
        let candidate: DetailPlaybackPreparationCandidate?
        let scope: DetailPlaybackPreparationScope?
        let active: Bool
    }

    private var input: Input {
        let candidate = item.flatMap { preparation.candidate(for: $0) }
        return Input(
            candidate: candidate,
            scope: candidate.flatMap { preparation.scope($0.accountID) },
            active: isActive && allowed && scenePhase == .active
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: input, initial: true) { _, input in
                if scenePhase != .active { coordinator.invalidate() }
                coordinator.update(
                    candidate: input.candidate, environment: preparation, isActive: input.active
                )
            }
            .onDisappear { coordinator.stop() }
    }
}

private struct DetailPlaybackPreparationEnvironmentModifier: ViewModifier {
    let preparation: DetailPlaybackPreparationEnvironment
    let accountIDs: [String]
    @State private var ownership = DetailPlaybackPreparationOwnership()
    @Environment(\.scenePhase) private var scenePhase

    private var scopes: [DetailPlaybackPreparationScope] {
        accountIDs.compactMap { preparation.scope($0) }
    }

    func body(content: Content) -> some View {
        var environment = preparation
        environment.ownership = ownership
        return content
            .environment(\.detailPlaybackPreparation, environment)
            .onChange(of: scopes, initial: true) { _, _ in
                ownership.validate(using: preparation)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { ownership.validate(using: .disabled) }
            }
    }
}

public extension View {
    func detailPlaybackPreparationEnvironment(
        _ preparation: DetailPlaybackPreparationEnvironment,
        accountIDs: [String]
    ) -> some View {
        modifier(DetailPlaybackPreparationEnvironmentModifier(
            preparation: preparation, accountIDs: accountIDs
        ))
    }

    func detailPlaybackPreparation(
        for item: MediaItem?,
        isActive: Bool,
        coordinator: DetailPlaybackPreparationCoordinator
    ) -> some View {
        modifier(DetailPlaybackPreparationModifier(
            item: item, isActive: isActive, coordinator: coordinator
        ))
    }
}
#endif
