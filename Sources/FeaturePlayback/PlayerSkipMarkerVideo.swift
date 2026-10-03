#if DEBUG && os(tvOS)
import CoreModels
import CoreNetworking
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
public final class PlayerSkipMarkerVideo {
    public struct Source: Sendable {
        public let request: PlaybackRequest
        public let startPosition: TimeInterval
        public let release: @Sendable () async -> Void

        public init(
            request: PlaybackRequest, startPosition: TimeInterval,
            release: @escaping @Sendable () async -> Void
        ) {
            self.request = request
            self.startPosition = startPosition
            self.release = release
        }
    }

    enum State: Equatable {
        case idle, loading, ready, failed(AppError)
    }

    private(set) var state: State = .idle
    private(set) var isPaused = false
    private(set) var title = "" // l10n:content - selected library episode title
    private(set) var engine: (any VideoEngine)?
    @ObservationIgnored private let source: @MainActor () async throws -> Source
    @ObservationIgnored private let makeEngine: @MainActor () throws -> any VideoEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var activeSource: Source?
    @ObservationIgnored private var generation = 0

    public init(
        source: @escaping @MainActor () async throws -> Source,
        makeEngine: @escaping @MainActor () throws -> any VideoEngine
    ) {
        self.source = source
        self.makeEngine = makeEngine
    }

    func start() {
        guard task == nil, engine == nil else { return }
        generation += 1
        let stamp = generation
        state = .loading
        isPaused = false
        let source = source
        let previousRelease = releaseTask
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) }
            catch is CancellationError { return }
            catch {
                PlozzLog.playback.error("Marker preview startup deadline failed.")
                return
            }
            guard let self, generation == stamp, state == .loading else { return }
            fail(.serverUnreachable)
        }
        task = Task { [weak self] in
            await previousRelease?.value
            guard !Task.isCancelled else { return }
            do {
                let prepared = try await source()
                guard let self, generation == stamp, !Task.isCancelled else {
                    await prepared.release()
                    return
                }
                activeSource = prepared
                let engine = try makeEngine()
                self.engine = engine
                title = prepared.request.item.title
                engine.onFailure = { [weak self] error in
                    guard let self, generation == stamp else { return }
                    fail(error)
                }
                engine.onProgress = { [weak self] in
                    guard let self, generation == stamp else { return }
                    updateReadiness()
                }
                engine.onEnded = { [weak self, weak engine] in
                    guard let self, generation == stamp else { return }
                    engine?.pause()
                    isPaused = true
                }
                await engine.load(request: prepared.request, startPosition: prepared.startPosition)
                guard generation == stamp, !Task.isCancelled else {
                    engine.stop()
                    return
                }
                engine.selectSubtitleTrack(nil)
                updateReadiness()
                task = nil
            } catch is CancellationError {
                guard let self, generation == stamp else { return }
                stop()
            } catch {
                guard let self, generation == stamp else { return }
                fail((error as? AppError) ?? .serverUnreachable)
            }
        }
    }

    func togglePause() {
        guard let engine, state == .ready else { return }
        isPaused.toggle()
        if isPaused { engine.pause() }
        else { engine.play() }
    }

    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        timeout?.cancel()
        timeout = nil
        let engine = engine
        self.engine = nil
        engine?.onProgress = nil
        engine?.onFailure = nil
        engine?.onEnded = nil
        engine?.stop()
        let owned = activeSource
        activeSource = nil
        if engine != nil || owned != nil {
            let previous = releaseTask
            releaseTask = Task {
                await previous?.value
                await engine?.drainTransport()
                await owned?.release()
            }
        }
        state = .idle
    }

    private func updateReadiness() {
        guard let engine else { return }
        if case .failed(let error) = engine.status {
            fail(error)
        } else if engine.hasPresentedVideoFrame, state == .loading {
            state = .ready
            timeout?.cancel()
            timeout = nil
            HandoffDiagnostics.emit("player MARKER_PREVIEW_VIDEO ready")
        }
    }

    private func fail(_ error: AppError) {
        stop()
        state = .failed(error)
        PlozzLog.playback.error("Library video for the marker comparison could not be played.")
    }
}

struct PlayerSkipMarkerVideoBackdrop: View {
    let model: PlayerSkipMarkerVideo
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
            if let engine = model.engine {
                MarkerPreviewVideoSurface(engine: engine)
                    .id(ObjectIdentifier(engine))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if scenePhase == .active { model.start() } }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() }
            else { model.stop() }
        }
    }
}

private struct MarkerPreviewVideoSurface: UIViewRepresentable {
    let engine: any VideoEngine

    func makeUIView(context: Context) -> UIView {
        let view = engine.makeVideoOutputView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
