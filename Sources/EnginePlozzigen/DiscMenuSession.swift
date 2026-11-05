#if canImport(DiscNavigation) && canImport(UIKit)
import Foundation
import FeaturePlayback
import CoreModels
import CoreNetworking
@preconcurrency import AetherEngine
@preconcurrency import DiscNavigation

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

@MainActor
final class DiscMenuSession {
    let state: DiscMenuPlaybackState
    private let source: DiscMenuSource
    private var native: HDMVSession?
    private var retiredNative: HDMVSession?
    private var generation = 0
    private var loadedGeneration: Int?
    private var stopped = false
    private var selectionTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var firstLoad: CheckedContinuation<Void, Error>?
    private var lastClockUpdate = Date.distantPast
    private let load: (TransportDiscDirectoryReader, TimeInterval) async throws -> Void
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
        load: @escaping (TransportDiscDirectoryReader, TimeInterval) async throws -> Void,
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
            }
        }
        native.menuVisibilityChanged = { [weak self] visible in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.state.isMenuVisible = visible
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
        state.sendKey = { [weak self] in self?.native?.key($0) }
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

    private func select(_ playlist: Int, position: Double, generation: Int) {
        guard !stopped, generation > self.generation else { return }
        self.generation = generation
        loadedGeneration = nil
        pendingAudioPID = nil
        pendingSubtitle = nil
        state.hasSubtitleSelection = false
        state.region = native?.selectedRegion ?? state.region
        let previous = selectionTask
        previous?.cancel()
        if playlist < 0 { pause(); return }
        state.isOpening = true
        armDeadline()
        selectionTask = Task { [weak self] in
            await previous?.value
            guard let self, !self.stopped, !Task.isCancelled, self.generation == generation else { return }
            let reader = self.source.reader.selectingPlaylist(playlist)
            do {
                try await self.load(reader, position)
                guard !self.stopped, !Task.isCancelled, self.generation == generation else { return }
                self.loadedGeneration = generation
                self.state.playlist = playlist
                self.state.isOpening = false
                self.tracksReady()
                self.firstLoad?.resume()
                self.firstLoad = nil
            } catch is CancellationError {
                reader.close()
            } catch {
                reader.close()
                guard self.generation == generation, !self.stopped else { return }
                self.fail(String(localized: "The disc's selected video could not be played."))
            }
        }
    }

    func updateTime(_ seconds: Double, hasPresentedFrame: Bool) {
        guard !stopped, let loadedGeneration, Date().timeIntervalSince(lastClockUpdate) >= 0.1 else { return }
        if hasPresentedFrame { deadline?.cancel() }
        lastClockUpdate = Date()
        native?.updateTime(seconds, generation: loadedGeneration)
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
            if !selectAudio(pid) {
                pendingAudioPID = pid
                state.notice = String(localized: "The disc's selected audio track is unavailable.")
            }
        }
        if let selection = pendingSubtitle {
            pendingSubtitle = nil
            if !selectSubtitle(selection.pid, selection.enabled) {
                pendingSubtitle = selection
                state.notice = String(localized: "The disc's selected subtitle track is unavailable.")
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
                    if subtitle { self.pendingSubtitle = nil } else { self.pendingAudioPID = nil }
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

    func fail(_ reason: String) {
        guard !stopped, state.failure == nil else { return }
        PlozzLog.playback.error("Disc navigation failed: \(reason)")
        state.failure = reason
        state.isOpening = false
        pause()
        stop()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        selectionTask?.cancel()
        deadline?.cancel()
        noticeTask?.cancel()
        native?.stop()
        source.reader.close()
        retiredNative = native
        native = nil
        firstLoad?.resume(throwing: CancellationError())
        firstLoad = nil
        state.sendKey = { _ in }
        state.openMenu = {}
    }

    func drain() async {
        await selectionTask?.value
        if let retiredNative {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                retiredNative.drain { continuation.resume() }
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
