#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import Observation
import SwiftUI
import UIKit

enum PlaybackStatus: Equatable { case idle, buffering, playing, paused }
enum TransportDirection { case forward, backward }

struct ArtworkRef: Equatable {
    let key: String
    let url: URL
}

struct Track: Equatable {
    let source: CoreModels.MusicTrack
    var feedback: MusicFeedback?
    var quality: PlaybackQuality?
    var artworkOverride: URL?

    var id: String {
        let account = source.sourceAccountID ?? ""
        return "\(account.utf8.count):\(account)\(source.id)"
    }
    var title: String { source.title }
    var artistName: String { source.artistName ?? "" }
    var albumTitle: String? { source.albumTitle }
    var albumID: String? { source.albumID }
    var artwork: ArtworkRef? { (artworkOverride ?? source.artworkURL).map { ArtworkRef(key: id, url: $0) } }
    var isFavorite: Bool {
        if case let .favorite(value) = feedback { return value }
        return false
    }
    var rating: Double? {
        if case let .rating(value) = feedback { return value }
        return nil
    }
    var format: FormatLabel { FormatLabel(nowPlayingLabel: quality?.detail) }

    struct FormatLabel {
        let nowPlayingLabel: String?
    }
}

@MainActor
@Observable
final class MusicPlayerAdapter {
    let controller: AudioPlaybackController
    var feedback: [String: MusicFeedback] = [:]
    var artwork: [String: URL] = [:]

    init(controller: AudioPlaybackController) {
        self.controller = controller
    }

    @MainActor
    struct Snapshot {
        let controller: AudioPlaybackController
        let currentTrackID: String?
        var status: PlaybackStatus {
            if !controller.hasActivePlayback { return .idle }
            if controller.isBuffering { return .buffering }
            return controller.isPlaying ? .playing : .paused
        }
        var elapsed: TimeInterval { controller.currentTime }
        var duration: TimeInterval { controller.duration }
        var repeatMode: AudioPlaybackController.RepeatMode { controller.repeatMode }
        var isShuffled: Bool { controller.isShuffled }
        var hasNext: Bool { controller.index + 1 < controller.queue.count || controller.repeatMode == .all }
        var hasPrevious: Bool { controller.index > 0 || controller.currentTime > 3 }
        var transportGeneration: Int { controller.transportGeneration }
        var transportDirection: TransportDirection { controller.lastTransportWasBackward ? .backward : .forward }
    }

    var snapshot: Snapshot { Snapshot(controller: controller, currentTrackID: currentTrack?.id) }
    var currentTrack: Track? { controller.currentTrack.map(track) }
    var history: [Track] { controller.queue.prefix(controller.index).map(track) }
    var upNext: [Track] { controller.upNext.map(track) }
    var queueRevision: Int { controller.queueRevision }
    var peekNextTrack: Track? {
        upNext.first ?? (controller.repeatMode == .all ? controller.queue.first.map(track) : nil)
    }
    var peekPreviousTrack: Track? { history.last }

    func track(_ source: CoreModels.MusicTrack) -> Track {
        var value = Track(source: source)
        value.feedback = feedback[value.id]
        value.artworkOverride = artwork[value.id]
        if source.isSameQueueEntry(as: controller.currentTrack ?? source) {
            value.quality = controller.currentQuality
        }
        return value
    }

    func togglePlayPause() { controller.togglePlayPause() }
    func next() { controller.next() }
    func previous() { controller.previous() }
    func toggleShuffle() { controller.toggleShuffle() }
    func cycleRepeatMode() { controller.cycleRepeatMode() }
    func jump(toOrderPosition position: Int) { controller.play(at: position) }
    func clearHistory() { controller.clearHistory() }
    func clearUpNext() { controller.clearUpNext() }
    func moveUpNext(fromOffset: Int, toOffset: Int) {
        controller.moveUpNext(fromOffset: fromOffset, toOffset: toOffset)
    }
    func seek(to seconds: TimeInterval) {
        let revision = controller.queueRevision
        let generation = controller.transportGeneration
        Task {
            guard controller.queueRevision == revision, controller.transportGeneration == generation else { return }
            await controller.seek(to: seconds)
        }
    }
}

struct MusicPlayerArtworkResolver {
    func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? { artwork.url }
}

@MainActor
final class ToastCenter: ObservableObject {
    @Published var message: String?
    func confirm(_ message: String, icon: String) { self.message = message }
}

@MainActor
final class MusicPlayerEnvironment: ObservableObject {
    let playback: MusicPlayerAdapter
    let toasts: ToastCenter
    let navigation: MusicNavigation
    let ui: PlayerUIModel
    private(set) var scopeID = ""
    private(set) var accounts: [ResolvedAccount] = []
    private var generation = 0
    private var writes: [String: Task<Bool, Never>] = [:]
    private var revisions: [String: Int] = [:]
    private var confirmedFeedback: [String: MusicFeedback] = [:]
    private var isAuthorized: () -> Bool = { false }

    struct Active {
        struct Connection { let id: String }
        let connection: Connection
        let backend = MusicPlayerArtworkResolver()
    }
    var active: Active? { accounts.isEmpty ? nil : Active(connection: .init(id: scopeID)) }
    var usesRatings: Bool { feedbackProvider(for: playback.currentTrack)?.musicFeedbackKind == .rating }
    var supportsFeedback: Bool { feedbackProvider(for: playback.currentTrack) != nil }

    init(playback: MusicPlayerAdapter, toasts: ToastCenter, navigation: MusicNavigation, ui: PlayerUIModel) {
        self.playback = playback
        self.toasts = toasts
        self.navigation = navigation
        self.ui = ui
    }

    func configure(accounts: [ResolvedAccount], scopeID: String, isAuthorized: @escaping () -> Bool) {
        if self.scopeID != scopeID {
            invalidate()
            self.scopeID = scopeID
        }
        self.accounts = accounts
        self.isAuthorized = isAuthorized
        objectWillChange.send()
    }

    func invalidate() {
        generation &+= 1
        for task in writes.values { task.cancel() }
        writes.removeAll()
        revisions.removeAll()
        confirmedFeedback.removeAll()
        accounts = []
        isAuthorized = { false }
        playback.feedback = [:]
        playback.artwork = [:]
        playback.controller.stop()
        navigation.reset()
        ui.isFullPresented = false
        toasts.message = nil
    }

    private func feedbackProvider(for track: Track?) -> (any MusicFeedbackProviding)? {
        guard isAuthorized(), let accountID = track?.source.sourceAccountID else { return nil }
        return accounts.first { $0.account.id == accountID }?.provider as? any MusicFeedbackProviding
    }

    func loadFeedback() async {
        guard let track = playback.currentTrack, let provider = feedbackProvider(for: track) else { return }
        let generation = generation
        let revision = revisions[track.id, default: 0]
        do {
            let value = try await provider.musicFeedback(for: track.source.id)
            guard !Task.isCancelled, isAuthorized(), self.generation == generation,
                  revisions[track.id, default: 0] == revision, writes[track.id] == nil else { return }
            confirmedFeedback[track.id] = value
            playback.feedback[track.id] = value
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isAuthorized(), self.generation == generation else { return }
            PlozzLog.playback.error("Music feedback could not be loaded")
            toasts.confirm("Couldn't load your rating or favorite.", icon: "exclamationmark.triangle")
        }
    }

    func loadArtwork(policy: ArtworkPresentationPolicy) async {
        guard isAuthorized(), let track = playback.currentTrack,
              accounts.contains(where: { $0.account.id == track.source.sourceAccountID }) else { return }
        let generation = generation
        let resolved = await MusicArtworkFallback.resolveTrack(track.source, policy: policy)
        guard !Task.isCancelled, isAuthorized(), self.generation == generation else { return }
        if case let .remote(url) = resolved?.reference { playback.artwork[track.id] = url }
    }

    @discardableResult
    func setLiked(_ value: Bool, track: Track) async -> Bool {
        await save(.favorite(value), track: track)
    }

    @discardableResult
    func setRating(_ value: Double?, track: Track) async -> Bool {
        await save(.rating(value), track: track)
    }

    private func save(_ value: MusicFeedback, track: Track) async -> Bool {
        guard let provider = feedbackProvider(for: track) else {
            toasts.confirm("This server doesn't support this action.", icon: "exclamationmark.triangle")
            return false
        }
        let generation = generation
        let previous = writes[track.id]
        let revision = revisions[track.id, default: 0] + 1
        revisions[track.id] = revision
        if confirmedFeedback[track.id] == nil {
            confirmedFeedback[track.id] = playback.feedback[track.id] ?? track.feedback
        }
        playback.feedback[track.id] = value
        let task = Task { @MainActor () -> Bool in
            _ = await previous?.value
            defer {
                if self.generation == generation, self.revisions[track.id] == revision {
                    self.writes[track.id] = nil
                }
            }
            guard !Task.isCancelled, self.isAuthorized(), self.generation == generation else { return false }
            do {
                try await provider.setMusicFeedback(value, for: track.source.id)
                guard !Task.isCancelled, self.isAuthorized(), self.generation == generation else { return false }
                self.confirmedFeedback[track.id] = value
                if self.revisions[track.id] == revision { self.playback.feedback[track.id] = value }
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard self.isAuthorized(), self.generation == generation else { return false }
                if self.revisions[track.id] == revision {
                    self.playback.feedback[track.id] = self.confirmedFeedback[track.id]
                }
                PlozzLog.playback.error("Music feedback could not be saved")
                self.toasts.confirm("Couldn't save your rating or favorite. Try again.", icon: "exclamationmark.triangle")
                return false
            }
        }
        writes[track.id] = task
        return await task.value
    }

    func navigate(to route: MusicRoute, track: Track) {
        guard isAuthorized(), accounts.contains(where: { $0.account.id == track.source.sourceAccountID }) else { return }
        ui.isFullPresented = false
        navigation.open(route)
    }
}

@MainActor
public final class MusicPlayerSession {
    public let controller: AudioPlaybackController
    public let navigation = MusicNavigation()
    let playback: MusicPlayerAdapter
    let environment: MusicPlayerEnvironment
    let ui = PlayerUIModel()
    let toasts = ToastCenter()

    public init() {
        let controller = AudioPlaybackController()
        self.controller = controller
        playback = MusicPlayerAdapter(controller: controller)
        environment = MusicPlayerEnvironment(playback: playback, toasts: toasts, navigation: navigation, ui: ui)
    }

    public var isPresented: Bool {
        get { ui.isFullPresented }
        set { ui.isFullPresented = newValue }
    }

    public func configure(accounts: [ResolvedAccount], authorizationID: String, isAuthorized: @escaping () -> Bool) {
        environment.configure(accounts: accounts, scopeID: authorizationID, isAuthorized: isAuthorized)
    }

    public func stop() {
        ui.isFullPresented = false
        environment.invalidate()
    }
}

public struct MusicPlayerOverlay: View {
    let session: MusicPlayerSession
    let hasBottomBar: Bool
    let contentLeft: CGFloat
    let appearance: MusicPlayerAppearance
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    @Environment(\.themePalette) private var palette

    public static func contentClearance(hasBottomBar: Bool) -> CGFloat {
        BottomBar.contentClearance(hasBottomBar: hasBottomBar)
    }

    static func resolvedAppearance(_ appearance: MusicPlayerAppearance, palette: ThemePalette) -> MusicPlayerAppearance {
        guard appearance == .matchTheme else { return appearance }
        if palette == .pureBlack { return .pureBlack }
        return palette == .light ? .light : .dark
    }

    public init(session: MusicPlayerSession, hasBottomBar: Bool, contentLeft: CGFloat = 0, appearance: MusicPlayerAppearance = .matchTheme) {
        self.session = session
        self.hasBottomBar = hasBottomBar
        self.contentLeft = contentLeft
        self.appearance = appearance
    }

    public var body: some View {
        let appearance = Self.resolvedAppearance(appearance, palette: palette)
        Group {
            if session.controller.hasActivePlayback {
                NowPlayingMorphContainer(
                    playback: session.playback, ui: session.ui,
                    contentLeft: contentLeft, hasBottomBar: hasBottomBar,
                    wide: sizeClass == .regular,
                    surfaceColorScheme: appearance == .light ? .light : .dark
                )
                .environmentObject(session.environment)
                .environmentObject(session.toasts)
                .environment(\.musicPlayerBackground, appearance == .pureBlack ? .oled : appearance == .light ? .theme : .adaptive)
                .transaction { if reduceMotion { $0.disablesAnimations = true } }
                .task(id: session.playback.currentTrack?.id) {
                    await session.environment.loadFeedback()
                }
                .task(id: "\(session.playback.currentTrack?.id ?? "")|\(artworkPolicy.forArea(.music).identity)") {
                    await session.environment.loadArtwork(policy: artworkPolicy.forArea(.music))
                }
                .overlay(alignment: .top) {
                    VStack {
                        if session.controller.playbackFailed {
                            HStack {
                                Text("Couldn't play this track.")
                                Button("Retry") { session.controller.retryPlayback() }
                            }
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .padding()
                        }
                        PlayerStatusMessage(toasts: session.toasts)
                    }
                }
            }
        }
        .tint(.musicPlayerAccent)
    }
}

private struct PlayerStatusMessage: View {
    @ObservedObject var toasts: ToastCenter
    var body: some View {
        if let message = toasts.message {
            Text(message)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
                .accessibilityAddTraits(.updatesFrequently)
                .onAppear { UIAccessibility.post(notification: .announcement, argument: message) }
                .onTapGesture { toasts.message = nil }
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    toasts.message = nil
                }
        }
    }
}
#endif
