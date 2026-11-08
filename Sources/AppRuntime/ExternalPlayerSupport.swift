import CoreModels
import CoreUI
import SwiftUI

private struct ExternalPlaybackContextKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> ExternalPlaybackContext)? = nil
}

public extension EnvironmentValues {
    var externalPlaybackContext: (@MainActor () -> ExternalPlaybackContext)? {
        get { self[ExternalPlaybackContextKey.self] }
        set { self[ExternalPlaybackContextKey.self] = newValue }
    }
}

private struct ExternalPlayerSupport: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let context: @MainActor () -> ExternalPlaybackContext
    let legacySettings: @MainActor () -> ExternalPlayerSettings
    let onProgress: @MainActor (ExternalPlaybackCompletion) async throws -> Void
    @State private var runtime = ExternalPlaybackRuntime.shared

    func body(content: Content) -> some View {
        content
            .environment(\.externalPlaybackContext, context)
            .environment(\.externalPlaybackChoices, { item in
                runtime.availablePlayers(
                    for: item, context: context(), selection: ExternalPlayerSettingsModel.shared.settings
                )
            })
            .task(id: context().identity + (runtime.returnID?.uuidString ?? "") + String(describing: scenePhase)) {
                guard scenePhase == .active else { return }
                if context().isAuthorized {
                    ExternalPlayerSettingsModel.shared.migrateIfNeeded(from: legacySettings())
                }
                await runtime.processReturn(context: context, onProgress: onProgress)
            }
            .alert("External playback", isPresented: Binding(
                get: { runtime.error != nil },
                set: { if !$0 { runtime.error = nil } }
            )) {
                Button("OK") { runtime.error = nil }
            } message: {
                if let error = runtime.error { Text(error.message) }
            }
    }
}

public extension View {
    func externalPlayerSupport(
        context: @escaping @MainActor () -> ExternalPlaybackContext,
        legacySettings: @escaping @MainActor () -> ExternalPlayerSettings,
        onProgress: @escaping @MainActor (ExternalPlaybackCompletion) async throws -> Void
    ) -> some View {
        modifier(ExternalPlayerSupport(context: context, legacySettings: legacySettings, onProgress: onProgress))
    }
}
