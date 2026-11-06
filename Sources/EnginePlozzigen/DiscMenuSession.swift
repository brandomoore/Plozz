#if canImport(DiscNavigation) && canImport(UIKit)
import Foundation
import FeaturePlayback
import CoreModels
import CoreNetworking
@preconcurrency import AetherEngine
@preconcurrency import DiscNavigation

struct DiscMenuClip: Equatable, Sendable {
    let index: Int
    let path: String
    let sourceRange: Range<Double>
    let playlistStart: Double
}

private final class DiscMenuSource: @unchecked Sendable {
    let reader: TransportDiscDirectoryReader
    init(_ reader: TransportDiscDirectoryReader) { self.reader = reader }

    func read(path: String, offset: Int64, length: Int64) -> Data? {
        guard length > 0, length <= 512 * 1024, let file = reader.openDiscFile(path) else { return nil }
        defer { file.close() }
        guard file.seek(offset: offset, whence: SEEK_SET) == offset else { return nil }
        var data = Data(count: Int(length))
        let complete = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
            var received = 0
            while received < bytes.count {
                let count = file.read(pointer.advanced(by: received), size: Int32(bytes.count - received))
                guard count > 0, count <= bytes.count - received else { return false }
                received += Int(count)
            }
            return true
        }
        return complete ? data : nil
    }
}

private final class DiscVideoInspection: @unchecked Sendable {
    let source: DiscMenuSource
    let native: HDMVSession

    init(reader: TransportDiscDirectoryReader) throws {
        guard let independent = reader.makeIndependentReader() as? TransportDiscDirectoryReader else {
            throw CancellationError()
        }
        source = DiscMenuSource(independent)
        let source = source
        guard let native = HDMVSession(
            files: Dictionary(uniqueKeysWithValues: reader.discFiles.map { ($0.path, NSNumber(value: $0.size)) }),
            region: 1, readRange: { source.read(path: $0, offset: $1, length: $2) }
        ) else {
            independent.close()
            throw CocoaError(.fileReadCorruptFile)
        }
        self.native = native
    }

    func stop() {
        source.reader.close()
        native.stop()
    }
}

@MainActor
final class DiscMenuSession {
    private struct Selection: Equatable {
        let playlist: Int
        let position: Double
        let clip: DiscMenuClip?
    }

    static func videos(reader: TransportDiscDirectoryReader) async throws -> [DiscVideo] {
        let inspection = try DiscVideoInspection(reader: reader)
        defer { inspection.stop() }
        let videos: [DiscVideo] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inspection.native.listVideos { values, failure in
                    if let failure {
                        PlozzLog.playback.error("Disc video inspection failed: \(failure)")
                        continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
                    } else if let values {
                        continuation.resume(returning: values.map {
                            DiscVideo(playlist: $0.playlist, duration: $0.duration, chapterCount: $0.chapterCount)
                        })
                    } else {
                        PlozzLog.playback.error("Disc video inspection returned no result")
                        continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
                    }
                }
            }
        } onCancel: {
            inspection.stop()
        }
        try Task.checkCancellation()
        return videos
    }

    let state: DiscMenuPlaybackState
    private let source: DiscMenuSource
    private var native: HDMVSession?
    private var retiredNative: HDMVSession?
    private var generation = 0
    private var loadedGeneration: Int?
    private var stopped = false
    private var selectionTask: Task<Void, Never>?
    private var loadingSelection: Selection?
    private var deadline: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var firstLoad: CheckedContinuation<Void, Error>?
    private var lastClockUpdate = Date.distantPast
    private let load: (TransportDiscDirectoryReader, TimeInterval, DiscMenuClip?) async throws -> Bool
    private var playbackReader: TransportDiscDirectoryReader?
    private var playbackClip: DiscMenuClip?
    private let pause: () -> Void
    private let resume: () -> Void
    private let isPaused: () -> Bool
    private let selectAudio: (Int) -> Bool
    private let selectSubtitle: (Int, Bool) -> Bool
    private var pendingAudioPID: Int?
    private var pendingSubtitle: (pid: Int, enabled: Bool)?

    init(
        reader: TransportDiscDirectoryReader, region: UInt32?,
        state: DiscMenuPlaybackState,
        load: @escaping (TransportDiscDirectoryReader, TimeInterval, DiscMenuClip?) async throws -> Bool,
        pause: @escaping () -> Void,
        resume: @escaping () -> Void,
        isPaused: @escaping () -> Bool,
        selectAudio: @escaping (Int) -> Bool,
        selectSubtitle: @escaping (Int, Bool) -> Bool
    ) throws {
        guard let independent = reader.makeIndependentReader() as? TransportDiscDirectoryReader else {
            throw CancellationError()
        }
        source = DiscMenuSource(independent)
        self.state = state
        self.load = load
        self.pause = pause
        self.resume = resume
        self.isPaused = isPaused
        self.selectAudio = selectAudio
        self.selectSubtitle = selectSubtitle
        let source = source
        guard let native = HDMVSession(
            files: Dictionary(uniqueKeysWithValues: reader.discFiles.map { ($0.path, NSNumber(value: $0.size)) }),
            region: region ?? Self.deviceRegion,
            readRange: { source.read(path: $0, offset: $1, length: $2) }
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.native = native
        native.automaticRegion = region == nil
        native.imageChanged = { [weak self] image in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.state.image = image
                if image != nil {
                    if self.selectionTask == nil || self.loadedGeneration == self.generation {
                        self.deadline?.cancel()
                        self.state.isOpening = false
                    }
                    self.firstLoad?.resume()
                    self.firstLoad = nil
                }
            }
        }
        native.menuVisibilityChanged = { [weak self] visible in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if self.state.isMenuVisible != visible {
                    HandoffDiagnostics.emit("disc MENU visible=\(visible) generation=\(self.generation)")
                }
                self.state.isMenuVisible = visible
            }
        }
        native.menuRequestPendingChanged = { [weak self] pending in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.state.isMenuRequestPending = pending
            }
        }
        native.stillChanged = { [weak self] active, resumePlayback in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                let wasStill = self.state.isStill
                self.state.isStill = active
                if active {
                    self.deadline?.cancel()
                    self.pause()
                } else if wasStill, resumePlayback, !self.isPaused() {
                    self.resume()
                }
            }
        }
        native.selectionChanged = { [weak self] playlist, position, generation in
            MainActor.assumeIsolated { self?.select(playlist, position: position, generation: generation) }
        }
        native.playItemChanged = { [weak self] playlist, index, path, start, end, playlistStart, position, generation in
            MainActor.assumeIsolated {
                self?.select(playlist, position: position, generation: generation,
                             clip: DiscMenuClip(index: index, path: path, sourceRange: start..<end,
                                                playlistStart: playlistStart))
            }
        }
        native.audioPIDChanged = { [weak self] pid, generation in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.generation == generation else { return }
                self.pendingAudioPID = pid
                self.tracksReady()
            }
        }
        native.subtitlePIDChanged = { [weak self] pid, enabled, generation in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.generation == generation else { return }
                self.pendingSubtitle = (pid, enabled)
                self.tracksReady()
            }
        }
        native.statusChanged = { [weak self] reason in
            MainActor.assumeIsolated { self?.fail(reason) }
        }
        native.diagnosticEvent = { event in
            HandoffDiagnostics.emit(event)
        }
        native.noticeChanged = { [weak self] notice in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.state.notice = notice
                self.noticeTask?.cancel()
                self.noticeTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.state.notice = nil
                }
            }
        }
        state.sendKey = { [weak self] key in
            guard let self else { return }
            HandoffDiagnostics.emit("disc INPUT key=\(key) generation=\(self.generation)")
            self.native?.key(key)
        }
        state.sendPointerClick = { [weak self] x, y in self?.native?.click(x: x, y: y) }
        state.openMenu = { [weak self] in self?.native?.menu() }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !stopped else { continuation.resume(throwing: CancellationError()); return }
            firstLoad = continuation
            armDeadline()
            native?.start()
        }
    }

    func select(_ playlist: Int, position: Double, generation: Int, clip: DiscMenuClip? = nil) {
        guard !stopped, generation > self.generation else { return }
        let selection = Selection(playlist: playlist, position: position, clip: clip)
        let reusesLoad = loadingSelection == selection && selectionTask?.isCancelled == false
        HandoffDiagnostics.emit(
            "disc SELECTION playlist=\(playlist) position=\(position) generation=\(generation) previous=\(self.generation)"
        )
        self.generation = generation
        loadedGeneration = nil
        pendingAudioPID = nil
        pendingSubtitle = nil
        state.audioSelectionUnavailable = false
        state.subtitleSelectionUnavailable = false
        state.hasSubtitleSelection = false
        state.region = native?.selectedRegion ?? state.region
        if reusesLoad {
            HandoffDiagnostics.emit("disc COALESCED playlist=\(playlist) generation=\(generation)")
            return
        }
        let previous = selectionTask
        previous?.cancel()
        loadingSelection = nil
        if playlist < 0 { pause(); return }
        loadingSelection = selection
        state.isOpening = true
        armDeadline()
        selectionTask = Task { [weak self] in
            await previous?.value
            guard let self, !self.stopped, !Task.isCancelled else { return }
            defer {
                if !Task.isCancelled {
                    self.loadingSelection = nil
                    self.selectionTask = nil
                }
            }
            let reader = self.source.reader.selectingPlaylist(playlist)
            let previousReader = self.playbackReader
            self.playbackReader = reader
            self.playbackClip = clip
            do {
                let reachedEnd = try await self.load(reader, position, clip)
                previousReader?.close()
                guard !self.stopped, !Task.isCancelled else { return }
                // Identical in-flight requests share the load, but the latest native
                // generation must own subsequent clocks, track selection and EOF.
                self.loadedGeneration = self.generation
                HandoffDiagnostics.emit("disc READY playlist=\(playlist) generation=\(self.generation) ended=\(reachedEnd)")
                self.state.playlist = playlist
                self.state.playItem = clip?.index
                self.state.isOpening = false
                if reachedEnd { self.ended() } else { self.tracksReady() }
                self.firstLoad?.resume()
                self.firstLoad = nil
            } catch is CancellationError {
                HandoffDiagnostics.emit("disc CANCELLED playlist=\(playlist) generation=\(generation)")
                reader.close()
                previousReader?.close()
            } catch {
                HandoffDiagnostics.emit(
                    "disc LOAD_FAILED playlist=\(playlist) generation=\(generation) current=\(self.generation)"
                        + " cancelled=\(Task.isCancelled) detail=\(HandoffDiagnostics.redactedDetail(String(describing: error)))"
                )
                reader.close()
                previousReader?.close()
                guard !Task.isCancelled, !self.stopped else { return }
                if let engineError = error as? AetherEngineError,
                   case .authoredPlaybackIntervalUnsupported = engineError {
                    self.failPlayback(unsupportedInterval: true)
                } else {
                    self.failPlayback(unsupportedInterval: false)
                }
            }
        }
    }

    func updateTime(_ seconds: Double, sourceSeconds: Double, hasPresentedFrame: Bool) {
        guard !stopped, let loadedGeneration, hasPresentedFrame,
              Date().timeIntervalSince(lastClockUpdate) >= 0.1 else { return }
        deadline?.cancel()
        lastClockUpdate = Date()
        let playlistTime: Double
        if let clip = playbackClip {
            let bounded = min(max(sourceSeconds, clip.sourceRange.lowerBound),
                              clip.sourceRange.upperBound - 1 / 90_000.0)
            playlistTime = clip.playlistStart + bounded - clip.sourceRange.lowerBound
        } else {
            playlistTime = seconds
        }
        native?.updateTime(playlistTime, generation: loadedGeneration)
    }

    func ended() {
        guard !stopped, let loadedGeneration else { return }
        self.loadedGeneration = nil
        armDeadline()
        native?.ended(loadedGeneration)
    }

    func setPaused(_ paused: Bool) { native?.playbackPaused = paused }

    func tracksReady() {
        guard !stopped, loadedGeneration == generation else { return }
        if let pid = pendingAudioPID {
            pendingAudioPID = nil
            let available = selectAudio(pid)
            state.audioSelectionUnavailable = !available
            if !available {
                pendingAudioPID = pid
            }
        }
        if let selection = pendingSubtitle {
            pendingSubtitle = nil
            let available = selectSubtitle(selection.pid, selection.enabled)
            state.subtitleSelectionUnavailable = !available
            if !available {
                pendingSubtitle = selection
            }
        }
    }

    func chooseTrack(pid: Int, subtitle: Bool, completion: @escaping () -> Void) {
        guard !stopped, let loadedGeneration, let native else {
            state.notice = String(localized: "Wait for the disc video before selecting a track.")
            return
        }
        native.selectTrackPID(pid, subtitle: subtitle, generation: loadedGeneration) { [weak self] accepted in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.loadedGeneration == loadedGeneration else { return }
                if accepted {
                    if subtitle {
                        self.pendingSubtitle = nil
                        self.state.subtitleSelectionUnavailable = false
                    } else {
                        self.pendingAudioPID = nil
                        self.state.audioSelectionUnavailable = false
                    }
                    completion()
                } else {
                    self.state.notice = String(localized: "The disc does not allow that track selection here.")
                }
            }
        }
    }

    private func armDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            var activeSeconds = 0
            while activeSeconds < 45 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopped, !self.state.isMenuVisible, !self.state.isStill else { return }
                if !self.isPaused() { activeSeconds += 1 }
            }
            self?.fail(String(localized: "Disc playback did not start in time."))
        }
    }

    func failPlayback(unsupportedInterval: Bool) {
        fail(unsupportedInterval
             ? String(localized: "This video format cannot play the pauses required by the disc.")
             : String(localized: "The disc's selected video could not be played."))
    }

    func fail(_ reason: String) {
        guard !stopped, state.failure == nil else { return }
        PlozzLog.playback.error("Disc navigation failed: \(reason)")
        HandoffDiagnostics.emit("disc FAILURE reason=\(HandoffDiagnostics.redactedDetail(reason))")
        state.failure = reason
        state.isOpening = false
        pause()
        stop()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        selectionTask?.cancel()
        loadingSelection = nil
        deadline?.cancel()
        noticeTask?.cancel()
        native?.stop()
        source.reader.close()
        playbackReader?.close()
        playbackReader = nil
        retiredNative = native
        native = nil
        firstLoad?.resume(throwing: CancellationError())
        firstLoad = nil
        state.sendKey = { _ in }
        state.sendPointerClick = { _, _ in }
        state.openMenu = {}
    }

    func drain() async {
        await selectionTask?.value
        if let retiredNative {
            let drained = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                retiredNative.drain { continuation.resume(returning: $0) }
            }
            if !drained {
                PlozzLog.playback.error("Disc navigation shutdown is still pending; native ownership is retained")
            }
            self.retiredNative = nil
        }
    }

    private static var deviceRegion: UInt32 {
        let region = Locale.current.region
        let code = region?.identifier ?? ""
        if region?.continent?.identifier == "019" ||
            ["JP", "KR", "KP", "TW", "HK", "MO", "BN", "KH", "ID", "LA", "MY", "MM", "PH", "SG", "TH", "TL", "VN"].contains(code) {
            return 1
        }
        if ["CN", "MN", "RU", "KZ", "KG", "TJ", "TM", "UZ", "IN", "PK", "BD", "NP", "BT", "LK", "MV", "AF"].contains(code) {
            return 4
        }
        return 2
    }
}
#endif
