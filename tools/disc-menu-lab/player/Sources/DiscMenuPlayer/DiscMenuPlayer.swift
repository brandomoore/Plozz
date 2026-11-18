import AetherEngine
import AVFoundation
import Combine
import CoreVideo
import Foundation
import UIKit

@MainActor
@objc public protocol DiscMenuPlayerDelegate: AnyObject {
    func discPlayerPhase(_ phase: String, generation: Int)
    func discPlayerTime(_ seconds: Double, generation: Int)
    func discPlayerFrame(_ seconds: Double, checksum: UInt64, generation: Int)
}

/// Isolated lab adapter. Navigation owns selection; each engine load owns independent file cursors.
@MainActor
@objc(DiscMenuPlayer)
public final class DiscMenuPlayer: UIViewController {
    @objc public weak var delegate: DiscMenuPlayerDelegate?
    private let engine: AetherEngine
    private let surface = AetherPlayerView(frame: .zero)
    private var subscriptions = Set<AnyCancellable>()
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var activeGeneration = 0
    private var observedItem: AVPlayerItem?
    private let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    private var files: [HTTPDiscDirectoryReader.File] = []
    private var headers: [String: String] = [:]
    private var intendsPause = false
    private var stopped = false

    @objc public init(configuration: URL) throws {
        engine = try AetherEngine()
        super.init(nibName: nil, bundle: nil)
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configuration))
        guard let base = URL(string: configuration.baseURL),
              base.scheme == "http", base.host != nil, !configuration.authorization.isEmpty,
              !configuration.files.isEmpty, configuration.files.count <= 4096 else {
            throw LabError.invalidConfiguration
        }
        var paths = Set<String>()
        for file in configuration.files {
            guard file.size >= 0, file.path.hasPrefix("BDMV/"),
                  !file.path.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  paths.insert(file.path.lowercased()).inserted else {
                throw LabError.invalidConfiguration
            }
            files.append(.init(path: file.path, size: file.size,
                               url: base.appendingPathComponent(file.path)))
        }
        headers = ["Authorization": configuration.authorization]
        engine.bind(view: surface)
        engine.$playbackPhase.sink { [weak self] phase in
            guard let self, !self.stopped else { return }
            let label: String
            switch phase {
            case .idle: label = "idle"
            case .loading: label = "loading"
            case .playing:
                if self.intendsPause { self.engine.pause() }
                label = self.intendsPause ? "paused" : "playing"
            case .paused: label = "paused"
            case .seeking: label = "seeking"
            case .rebuffering: label = "buffering"
            case .stalled: label = "stalled"
            case .ended: label = "ended"
            case .error: label = "error"
            }
            self.delegate?.discPlayerPhase(label, generation: self.activeGeneration)
        }.store(in: &subscriptions)
        engine.$currentAVPlayerItem.sink { [weak self] item in
            guard let self else { return }
            self.observedItem?.remove(self.videoOutput)
            self.observedItem = item
            item?.add(self.videoOutput)
        }.store(in: &subscriptions)
        engine.clock.$currentTime
            .map { [weak self] seconds in (seconds, self?.activeGeneration ?? -1) }
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] sample in
                let (seconds, generation) = sample
                guard let self, !self.stopped, generation == self.activeGeneration,
                      seconds.isFinite, seconds >= 0 else { return }
                self.delegate?.discPlayerTime(seconds, generation: generation)
                self.recordFrame(generation: generation)
            }.store(in: &subscriptions)
    }

    public required init?(coder: NSCoder) { nil }

    public override func loadView() { view = surface }

    @objc public func loadPlaylist(_ playlist: Int, position: Double, generation: Int) {
        guard !stopped, (0...99999).contains(playlist), position.isFinite, position >= 0 else {
            delegate?.discPlayerPhase("invalid-selection", generation: generation)
            return
        }
        self.generation = generation
        intendsPause = false
        let previous = operation
        previous?.cancel()
        operation = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.generation == generation, !self.stopped else { return }
            self.engine.stop()
            self.activeGeneration = generation
            let reader = HTTPDiscDirectoryReader(
                files: self.files, preferredPlaylist: String(format: "%05d.mpls", playlist),
                httpHeaders: self.headers
            )
            do {
                _ = try await self.engine.load(source: .custom(reader), startPosition: position)
                guard !Task.isCancelled, self.generation == generation, !self.stopped else { return }
                if self.intendsPause { self.engine.pause() } else { self.engine.play() }
            } catch is CancellationError {
                // Superseded loads cannot report completion or change the new selection.
            } catch {
                guard !Task.isCancelled, self.generation == generation, !self.stopped else { return }
                NSLog("Disc Menu Lab: AetherEngine load failed (%@)", String(describing: type(of: error)))
                self.delegate?.discPlayerPhase("load-failed", generation: generation)
            }
        }
    }

    @objc public func togglePause() {
        guard !stopped else { return }
        intendsPause.toggle()
        if intendsPause { engine.pause() } else { engine.play() }
    }

    @objc public func stopPlayback() {
        generation += 1
        operation?.cancel()
        engine.stop()
    }

    @objc public func shutdown() {
        guard !stopped else { return }
        stopped = true
        operation?.cancel()
        subscriptions.removeAll()
        observedItem?.remove(videoOutput)
        observedItem = nil
        engine.stop(finalTeardown: true)
    }

    private func recordFrame(generation: Int) {
        guard let item = observedItem else { return }
        let time = item.currentTime()
        guard videoOutput.hasNewPixelBuffer(forItemTime: time),
              let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, stride >= width * 4 else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var checksum: UInt64 = 14695981039346656037
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = (y * (height - 1) / 7) * stride + (x * (width - 1) / 7) * 4
                for channel in 0..<3 {
                    checksum = (checksum ^ UInt64(bytes[offset + channel])) &* 1099511628211
                }
            }
        }
        delegate?.discPlayerFrame(time.seconds, checksum: checksum, generation: generation)
    }

    private struct Configuration: Decodable {
        struct File: Decodable { let path: String; let size: Int64 }
        let baseURL: String
        let authorization: String
        let files: [File]
    }

    private enum LabError: Error { case invalidConfiguration }
}
