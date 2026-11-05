#if canImport(AetherEngine)
import AetherEngine
import CoreModels
import CoreNetworking
import Foundation
import MediaTransportCore
import os

/// Disc recognition opens files synchronously on the engine's I/O worker. Only
/// those requested files acquire transport cursors; Stop can interrupt an open.
final class TransportDiscDirectoryReader: DiscDirectoryReader, @unchecked Sendable {
    private let locator: NetworkDiscLocator
    private let scope: DiscTransportScope
    private let owner = UUID()
    private let closed = OSAllocatedUnfairLock(initialState: false)
    let preferredPlaylist: String?
    var discFiles: [(path: String, size: Int64)] {
        locator.files.map { ($0.path, $0.locator.representation.size) }
    }

    init(locator: NetworkDiscLocator, resolver: any MediaTransportNetworkFileResolving) {
        self.locator = locator
        self.scope = DiscTransportScope(resolver: resolver.withoutPlaybackAdmission())
        self.preferredPlaylist = nil
    }

    private init(locator: NetworkDiscLocator, scope: DiscTransportScope, preferredPlaylist: String?) {
        self.locator = locator
        self.scope = scope
        self.preferredPlaylist = preferredPlaylist
    }

    deinit { close() }

    func openDiscFile(_ path: String) -> IOReader? {
        guard !closed.withLock({ $0 }),
              let file = locator.files.first(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame })
        else { return nil }
        return scope.open(file.locator, owner: owner)
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { -1 }
    func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
    func cancel() { scope.cancel(owner: owner) }
    func close() {
        closed.withLock { $0 = true }
        scope.close(owner: owner)
    }
    func makeIndependentReader() -> IOReader? {
        guard !closed.withLock({ $0 }), !scope.isClosed else { return nil }
        return TransportDiscDirectoryReader(locator: locator, scope: scope, preferredPlaylist: preferredPlaylist)
    }
    func selectingPlaylist(_ playlist: Int) -> TransportDiscDirectoryReader {
        TransportDiscDirectoryReader(
            locator: locator, scope: scope, preferredPlaylist: String(format: "%05d.mpls", playlist)
        )
    }
    func closeAllReaders() { scope.closeAll() }
    func waitForFinalShutdown() async { await scope.drain() }
}

private final class DiscTransportOpen: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var result: DiscTransportFile?
        var task: Task<Void, Never>?
    }
    let owner: UUID
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let ready = DispatchSemaphore(value: 0)

    init(owner: UUID) { self.owner = owner }
    var task: Task<Void, Never>? { state.withLock { $0.task } }
    func attach(_ task: Task<Void, Never>) {
        let cancelled = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        if cancelled { task.cancel() }
    }
    func finish(_ file: DiscTransportFile?) {
        let accepted = state.withLock { state in
            guard !state.cancelled else { return false }
            state.result = file
            return true
        }
        if !accepted { file?.close() }
        ready.signal()
    }
    func wait() -> DiscTransportFile? {
        ready.wait()
        return state.withLock { $0.cancelled ? nil : $0.result }
    }
    func cancel() {
        let pending = state.withLock { state in
            state.cancelled = true
            return (state.task, state.result)
        }
        pending.0?.cancel()
        pending.1?.close()
        ready.signal()
    }
}

private final class DiscTransportScope: @unchecked Sendable {
    private struct State {
        var closed = false
        var closedOwners: Set<UUID> = []
        var opening: [UUID: DiscTransportOpen] = [:]
        var files: [UUID: DiscTransportFile] = [:]
        var draining: [UUID: Task<Void, Never>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let resolver: any MediaTransportNetworkFileResolving
    var isClosed: Bool { state.withLock { $0.closed } }

    init(resolver: any MediaTransportNetworkFileResolving) { self.resolver = resolver }

    func open(_ locator: NetworkFileLocator, owner: UUID) -> DiscTransportFile? {
        let id = UUID()
        let pending = DiscTransportOpen(owner: owner)
        let admitted = state.withLock { state in
            guard !state.closed, !state.closedOwners.contains(owner) else { return false }
            state.opening[id] = pending
            let task = Task.detached { [self] in
                do {
                    let source = try await resolver.resolve(locator)
                    let reader = TransportIOReader(resolvedSource: source, discImageProbeEnabled: false)
                    let file = DiscTransportFile(id: id, owner: owner, reader: reader, scope: self)
                    let accepted = self.state.withLock { state in
                        guard !state.closed, !state.closedOwners.contains(owner) else { return false }
                        state.files[id] = file
                        return true
                    }
                    if accepted {
                        pending.finish(file)
                    } else {
                        file.close()
                        pending.finish(nil)
                    }
                } catch {
                    if !(error is CancellationError), (error as? MediaTransportError) != .cancelled {
                        PlozzLog.playback.error("Disc file transport open failed")
                    }
                    pending.finish(nil)
                }
                _ = self.state.withLock { $0.opening.removeValue(forKey: id) }
            }
            pending.attach(task)
            return true
        }
        return admitted ? pending.wait() : nil
    }

    func retire(_ file: DiscTransportFile) {
        file.reader.closeAllReaders()
        state.withLock { state in
            state.files.removeValue(forKey: file.id)
            let reader = file.reader
            state.draining[file.id] = Task.detached { [self] in
                await reader.waitForFinalShutdown()
                _ = self.state.withLock { $0.draining.removeValue(forKey: file.id) }
            }
        }
    }

    func cancel(owner: UUID) {
        let active = state.withLock {
            ($0.opening.values.filter { $0.owner == owner }, $0.files.values.filter { $0.owner == owner })
        }
        active.0.forEach { $0.cancel() }
        active.1.forEach { $0.cancel() }
    }

    func close(owner: UUID) {
        let active = state.withLock { state in
            state.closedOwners.insert(owner)
            return (state.opening.values.filter { $0.owner == owner }, state.files.values.filter { $0.owner == owner })
        }
        active.0.forEach { $0.cancel() }
        active.1.forEach { $0.close() }
    }

    func closeAll() {
        let active = state.withLock { state in
            state.closed = true
            return (Array(state.opening.values), Array(state.files.values))
        }
        active.0.forEach { $0.cancel() }
        active.1.forEach { $0.close() }
    }

    func drain() async {
        closeAll()
        while true {
            let tasks = state.withLock { Array($0.draining.values) + $0.opening.values.compactMap(\.task) }
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }
}

private final class DiscTransportFile: IOReader, @unchecked Sendable {
    let id: UUID
    let owner: UUID
    let reader: TransportIOReader
    private weak var scope: DiscTransportScope?
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(id: UUID, owner: UUID, reader: TransportIOReader, scope: DiscTransportScope) {
        self.id = id
        self.owner = owner
        self.reader = reader
        self.scope = scope
    }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { reader.read(buffer, size: size) }
    func seek(offset: Int64, whence: Int32) -> Int64 { reader.seek(offset: offset, whence: whence) }
    func cancel() { reader.cancel() }
    func close() {
        let first = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        if first { scope?.retire(self) }
    }
}
#endif
