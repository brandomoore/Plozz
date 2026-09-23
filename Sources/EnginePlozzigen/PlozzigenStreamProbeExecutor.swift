import Foundation
import AetherEngine
import CoreModels

enum PlozzigenStreamProbeExecutor {
    /// Playback-adjacent header probes remain independent from opt-in detail
    /// scans so enrichment cannot head-of-line block the existing header path.
    private static let headerQueue = DispatchQueue(
        label: "com.thatcube.Plozz.stream-probe.header",
        qos: .utility
    )
    private static let detailQueue = DispatchQueue(
        label: "com.thatcube.Plozz.stream-probe.detail",
        qos: .utility
    )

    typealias Operation = @Sendable (
        MediaSource, ProbeDetail, AtmosDetectionOptions, HDR10PlusDetectionOptions,
        ProbeLimits, ProbeCancellation
    ) throws -> SourceProbe

    static let probe: Operation = { source, detail, atmos, hdr, limits, cancellation in
        try AetherEngine.probe(
            source: source, detecting: detail, atmosDetection: atmos,
            hdr10PlusDetection: hdr, limits: limits, cancellation: cancellation
        )
    }

    static func runHeaderProbe(
        _ operation: @escaping @Sendable () -> SourceProbe?
    ) async -> SourceProbe? {
        await withCheckedContinuation { continuation in
            headerQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    static func details(for requirements: SupplementalStreamProbeRequirements) -> ProbeDetail {
        var result: ProbeDetail = []
        if requirements.contains(.atmos) { result.insert(.atmos) }
        if requirements.contains(.hdr10Plus) { result.insert(.hdr10Plus) }
        return result
    }

    static func packetBudgets(
        requirements: SupplementalStreamProbeRequirements, wholeProbePackets: Int
    ) -> (hdr: Int, atmos: Int) {
        guard requirements.contains(.hdr10Plus), requirements.contains(.atmos) else {
            return (wholeProbePackets, 64)
        }
        // Reserve HDR's eight-times foreign-packet fuse, but preserve up to 64
        // useful Atmos decode packets. With default limits HDR costs at most 32,
        // leaving 96 actual demux packets for Atmos (64 audio plus 32 foreign).
        // Pathological interleaving may still hit the authoritative whole-probe
        // cap; reserving Atmos's entire theoretical fuse would lose late JOC.
        let targetPackets = wholeProbePackets / 8
        let hdr = min(4, targetPackets / 2)
        return (hdr, min(64, wholeProbePackets - hdr * 8))
    }

    /// All detail work shares one serial native-call slot. Cancelling the
    /// awaiting task never releases that slot before FFmpeg and final transport
    /// shutdown have both ended.
    static func runDetailProbe(
        reader: any IOReader,
        formatHint: String? = nil,
        requirements: SupplementalStreamProbeRequirements,
        limits: HDR10PlusProbeLimits = .init(),
        budget suppliedBudget: HDR10PlusProbeBudget? = nil,
        queue: DispatchQueue = detailQueue,
        interrupt: (@Sendable () -> Void)? = nil,
        finalShutdown: @escaping @Sendable () async -> Void = {},
        operation: @escaping Operation = probe
    ) async -> SourceProbe? {
        guard limits.isValid else {
            reader.close()
            await finalShutdown()
            return nil
        }
        let budget = suppliedBudget ?? HDR10PlusProbeBudget(limits: limits)
        let completion = Completion(
            budget: budget, interrupt: interrupt ?? { reader.cancel() }
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.attach(continuation)
                queue.async {
                    var result: SourceProbe?
                    if completion.begin() {
                        do {
                            let remaining = budget.remainingTime
                            let packets = packetBudgets(
                                requirements: requirements, wholeProbePackets: limits.packets
                            )
                            result = try operation(
                                .custom(reader, formatHint: formatHint),
                                details(for: requirements),
                                AtmosDetectionOptions(
                                    maxPackets: packets.atmos, timeBudget: min(2, remaining)
                                ),
                                HDR10PlusDetectionOptions(
                                    maxPackets: packets.hdr,
                                    maxBytes: Int64(limits.networkBytes),
                                    timeBudget: remaining
                                ),
                                limits.engineLimits(remainingTime: remaining),
                                completion.cancellation
                            )
                        } catch {
                            // Never include a resolved URL or arbitrary native error text.
                            let reason = (error as? ProbeError)?.errorDescription
                                ?? (error is CancellationError ? "cancelled" : "engine")
                            HandoffDiagnostics.emit("sourceProbe FAILED stage=probe reason=\(reason)")
                        }
                    }
                    reader.close()
                    let probe = result
                    let shutdownFinished = DispatchSemaphore(value: 0)
                    Task {
                        await finalShutdown()
                        completion.finish(probe)
                        shutdownFinished.signal()
                    }
                    // This is the dedicated blocking queue, not a cooperative
                    // executor. Keep its admission slot while async transport
                    // reads/leases drain, including after waiter cancellation.
                    shutdownFinished.wait()
                }
            }
        } onCancel: {
            completion.stop()
        }
    }

    private final class Completion: @unchecked Sendable {
        let cancellation = ProbeCancellation()
        private let budget: HDR10PlusProbeBudget
        private let interrupt: @Sendable () -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<SourceProbe?, Never>?
        private var finished = false
        private var result: SourceProbe?
        private var timer: DispatchSourceTimer?

        init(budget: HDR10PlusProbeBudget, interrupt: @escaping @Sendable () -> Void) {
            self.budget = budget
            self.interrupt = interrupt
        }

        func attach(_ continuation: CheckedContinuation<SourceProbe?, Never>) {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.setEventHandler { [weak self] in self?.stop() }
            timer.schedule(deadline: .now() + budget.remainingTime)
            let immediate: (Bool, SourceProbe?) = lock.withLock {
                if finished { return (true, result) }
                self.continuation = continuation
                self.timer = timer
                return (false, nil)
            }
            // Dispatch sources must be activated even if cancellation won attach.
            timer.resume()
            if immediate.0 {
                timer.cancel()
                continuation.resume(returning: immediate.1)
            }
        }

        func begin() -> Bool {
            lock.withLock { !finished && budget.isActive && !cancellation.isCancelled }
        }

        func stop() {
            // Retain real-work ownership in the queue closure. Only interrupt I/O
            // here; final transport shutdown must join after the native call.
            cancellation.cancel()
            budget.cancel()
            interrupt()
            finish(nil)
        }

        func finish(_ candidate: SourceProbe?) {
            let publication: (CheckedContinuation<SourceProbe?, Never>?, SourceProbe?) = lock.withLock {
                guard !finished else { return (nil, nil) }
                finished = true
                result = budget.isActive && !cancellation.isCancelled ? candidate : nil
                timer?.cancel()
                timer = nil
                let continuation = self.continuation
                self.continuation = nil
                return (continuation, result)
            }
            publication.0?.resume(returning: publication.1)
        }
    }
}
