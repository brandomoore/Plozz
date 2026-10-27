#if canImport(SwiftUI) && canImport(AVFoundation)
import CoreModels
import CoreNetworking
import CoreUI
import SwiftUI

private struct ThemeMusicControllerKey: EnvironmentKey {
    static let defaultValue: ThemeMusicController? = nil
}

private struct ThemeMusicSettingsKey: EnvironmentKey {
    static let defaultValue = ThemeMusicSettings.default
}

private struct ThemeMusicDetailAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

/// A render-time scope paired with a live provider resolver. The resolver must
/// reject a changed profile, excluded account, or effective credential identity.
public struct ThemeMusicPlaybackAuthorization {
    public let id: String?
    let provider: @MainActor (String) -> (any MediaProvider)?

    public init(
        id: String?,
        provider: @escaping @MainActor (String) -> (any MediaProvider)?
    ) {
        self.id = id
        self.provider = provider
    }

    public static let denied = Self(id: nil, provider: { _ in nil })
}

private struct ThemeMusicAuthorizationKey: EnvironmentKey {
    static let defaultValue = ThemeMusicPlaybackAuthorization.denied
}

public extension EnvironmentValues {
    var themeMusicAuthorization: ThemeMusicPlaybackAuthorization {
        get { self[ThemeMusicAuthorizationKey.self] }
        set { self[ThemeMusicAuthorizationKey.self] = newValue }
    }

    var themeMusicDetailAllowed: Bool {
        get { self[ThemeMusicDetailAllowedKey.self] }
        set { self[ThemeMusicDetailAllowedKey.self] = newValue }
    }

    var themeMusicController: ThemeMusicController? {
        get { self[ThemeMusicControllerKey.self] }
        set { self[ThemeMusicControllerKey.self] = newValue }
    }

    var themeMusicSettings: ThemeMusicSettings {
        get { self[ThemeMusicSettingsKey.self] }
        set { self[ThemeMusicSettingsKey.self] = newValue }
    }

}

private struct ThemeMusicPlaybackTaskID: Equatable {
    let playbackID: String?
    let settings: ThemeMusicSettings
    let isBlocked: Bool
    let isPreviewing: Bool
    let isAllowed: Bool
    let isAppActive: Bool
    let isInterrupted: Bool
    let authorizationID: String?
}

private struct ThemeMusicPlaybackModifier: ViewModifier {
    let playbackID: String?
    let source: MediaSourceRef?
    let isActive: Bool

    @Environment(\.themeMusicController) private var controller
    @Environment(\.themeMusicSettings) private var settings
    @Environment(\.themeMusicAuthenticatedHTTPResolver) private var authenticatedHTTPResolver
    @Environment(\.themeMusicDetailAllowed) private var detailAllowed
    @Environment(\.themeMusicAuthorization) private var authorization
    @State private var resolutionGeneration: UInt64 = 0
    @State private var owner = UUID()

    private var taskID: ThemeMusicPlaybackTaskID {
        ThemeMusicPlaybackTaskID(
            playbackID: playbackID,
            settings: settings,
            isBlocked: controller?.isBlocked ?? true,
            isPreviewing: controller?.isPreviewing ?? false,
            isAllowed: detailAllowed && isActive,
            isAppActive: controller?.isAppActive ?? false,
            isInterrupted: controller?.isInterrupted ?? false,
            authorizationID: authorization.id
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: taskID) {
                resolutionGeneration &+= 1
                let generation = resolutionGeneration
                guard let controller else { return }
                guard !controller.isPreviewing else { return }
                guard isActive, detailAllowed else {
                    controller.stopDetail(owner: owner, fadingOut: detailAllowed && !isActive)
                    return
                }
                guard let playbackID, let source, let authorizationID = authorization.id,
                      let provider = authorization.provider(source.accountID) else {
                    controller.stopDetail(owner: owner)
                    return
                }
                guard settings.shouldPlay, !controller.isBlocked, detailAllowed, isActive else {
                    controller.stopDetail(owner: owner)
                    return
                }
                guard controller.isAppActive, !controller.isInterrupted else { return }
                controller.setAuthorization(authorizationID)
                guard controller.claimDetail(
                    owner: owner, playbackID: playbackID, authorizationID: authorizationID
                ) else { return }
                defer {
                    if !Task.isCancelled, generation == resolutionGeneration,
                       controller.currentPlaybackID == nil {
                        controller.stopDetail(owner: owner)
                    }
                }
                if controller.currentPlaybackID == playbackID {
                    controller.updateVolume(settings.volume)
                    return
                }
                do {
                    guard let theme = try await provider.themeMusic(for: source.itemID),
                          !Task.isCancelled, generation == resolutionGeneration,
                          authorization.provider(source.accountID) != nil else { return }
                    let resolvedURL = try await resolveThemeMusicURL(
                        theme,
                        authenticatedHTTPResolver: authenticatedHTTPResolver
                    )
                    guard !Task.isCancelled,
                          generation == resolutionGeneration,
                          authorization.provider(source.accountID) != nil,
                          !controller.isBlocked else {
                        return
                    }
                    controller.play(
                        theme,
                        resolvedURL: resolvedURL,
                        playbackID: playbackID,
                        owner: owner,
                        authorizationID: authorizationID,
                        settings: settings
                    )
                } catch {
                    guard !Task.isCancelled,
                          generation == resolutionGeneration else {
                        return
                    }
                    controller.stopDetail(owner: owner)
                    guard !(error is CancellationError) else { return }
                    PlozzLog.app.error(
                        "Theme music: resolution failed type=\(String(describing: type(of: error)))"
                    )
                }
            }
            .onDisappear {
                resolutionGeneration &+= 1
                controller?.stopDetail(owner: owner, fadingOut: true)
            }
    }
}

private struct ThemeMusicScope: ViewModifier {
    let controller: ThemeMusicController
    let model: ThemeMusicSettingsModel
    let background: HeroBackgroundSettings
    let isBlocked: Bool
    let detailAllowed: Bool
    let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    let authorization: ThemeMusicPlaybackAuthorization
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.themeMusicController, controller)
            .environment(\.themeMusicPreviewController, controller)
            .environment(\.themeMusicSettings, model.settings)
            .environment(\.themeMusicAuthenticatedHTTPResolver, authenticatedHTTPResolver)
            .environment(\.themeMusicDetailAllowed, detailAllowed)
            .environment(\.themeMusicAuthorization, authorization)
            .onChange(of: authorization.id, initial: true) { _, id in
                controller.setAuthorization(id)
            }
            .onChange(of: background.themeMusicEnabled, initial: true) { _, enabled in
                if model.settings.isEnabled != enabled { model.settings.isEnabled = enabled }
                if !enabled { controller.stop() }
            }
            .onChange(of: ObjectIdentifier(model)) {
                controller.stop()
                model.settings.isEnabled = background.themeMusicEnabled
            }
            .onChange(of: isBlocked, initial: true) { _, blocked in
                controller.setBlocked(blocked)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                controller.setAppActive(phase == .active)
            }
            .onDisappear { controller.stop() }
    }
}

enum ThemeMusicSourceResolutionError: Error, Equatable {
    case missingAuthenticatedResolver
    case unsupportedSource
}

@MainActor
func resolveThemeMusicURL(
    _ theme: ThemeMusic,
    authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
) async throws -> URL {
    switch theme.playbackSource {
    case .publicURL(let source):
        return source.url
    case .authenticatedHTTP(let locator):
        guard let authenticatedHTTPResolver else {
            throw ThemeMusicSourceResolutionError.missingAuthenticatedResolver
        }
        return try await authenticatedHTTPResolver.resolve(locator)
    case .networkFile, .dlnaResource:
        throw ThemeMusicSourceResolutionError.unsupportedSource
    }
}

public extension View {
    func themeMusicScope(
        controller: ThemeMusicController,
        model: ThemeMusicSettingsModel,
        background: HeroBackgroundSettings,
        isBlocked: Bool,
        detailAllowed: Bool = true,
        authorization: ThemeMusicPlaybackAuthorization,
        authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    ) -> some View {
        modifier(ThemeMusicScope(
            controller: controller, model: model, background: background,
            isBlocked: isBlocked, detailAllowed: detailAllowed,
            authenticatedHTTPResolver: authenticatedHTTPResolver,
            authorization: authorization
        ))
    }

    func themeMusicPlayback(
        playbackID: String?,
        source: MediaSourceRef?,
        isActive: Bool = true
    ) -> some View {
        modifier(
            ThemeMusicPlaybackModifier(
                playbackID: playbackID,
                source: source,
                isActive: isActive
            )
        )
    }
}
#endif
