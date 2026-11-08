import Darwin
import Foundation
import XCTest

/// Test-only, process-wide measurements. Resident memory is a snapshot, not allocations or a leak verdict.
@MainActor
enum PerformanceProbe {
    static func requireEnabled() throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt-in simulator workload; use tools/performance.py.")
        }
        #if !targetEnvironment(simulator)
        throw XCTSkip("Performance lab workloads must not run on physical devices.")
        #endif
    }

    static func measure(
        _ test: XCTestCase,
        scenario: String,
        operation: () async throws -> [String: Int]
    ) async throws {
        try requireEnabled()
        _ = try await operation()
        var samples: [Sample] = []
        for index in 0..<5 {
            let before = try usage()
            let start = ContinuousClock.now
            let counters = try await operation()
            let elapsed = start.duration(to: .now).components
            let after = try usage()
            samples.append(Sample(
                iteration: index,
                wallMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                cpuMilliseconds: after.cpuMilliseconds - before.cpuMilliseconds,
                residentBytes: after.residentBytes,
                residentDeltaBytes: after.residentBytes - before.residentBytes,
                memory: try memoryUsage(),
                counters: counters
            ))
        }
        let data = try JSONEncoder().encode(Report(schema: 1, scenario: scenario, warmups: 1, samples: samples))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "plozz-performance-\(scenario).json"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    private struct Sample: Encodable {
        let iteration: Int
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let residentBytes: Int64
        let residentDeltaBytes: Int64
        let memory: [String: Int64]
        let counters: [String: Int]
    }

    private struct Report: Encodable {
        let schema: Int
        let scenario: String
        let warmups: Int
        let samples: [Sample]
    }

    // Let queued work and autoreleases drain outside timing; the caller still owns its fixture.
    static func attachMemoryAfterOneSecond(_ test: XCTestCase, scenario: String) async throws {
        try await Task.sleep(for: .seconds(1))
        let data = try JSONEncoder().encode(memoryUsage())
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "plozz-memory-after-one-second-\(scenario).json"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    static func memoryUsage() throws -> [String: Int64] {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(status))
        }
        return [
            "residentBytes": Int64(info.resident_size),
            "physicalFootprintBytes": Int64(info.phys_footprint),
            "internalBytes": Int64(info.internal),
            "externalBytes": Int64(info.external),
            "compressedBytes": Int64(info.compressed),
            "reusableBytes": Int64(info.reusable),
            "mallocInUseBytes": Int64(statistics.size_in_use),
            "mallocAllocatedBytes": Int64(statistics.size_allocated),
            "mallocBlocksInUse": Int64(statistics.blocks_in_use),
        ]
    }

    // Test-only attribution after teardown; never a production memory-management strategy.
    static func releaseUnusedHeapForDiagnosis() -> Int64 {
        Int64(malloc_zone_pressure_relief(nil, 0))
    }

    static func usage() throws -> (cpuMilliseconds: Double, residentBytes: Int64) {
        var resources = rusage()
        guard getrusage(RUSAGE_SELF, &resources) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(status))
        }
        let cpu = Double(resources.ru_utime.tv_sec + resources.ru_stime.tv_sec) * 1_000
            + Double(resources.ru_utime.tv_usec + resources.ru_stime.tv_usec) / 1_000
        return (cpu, Int64(info.resident_size))
    }
}
