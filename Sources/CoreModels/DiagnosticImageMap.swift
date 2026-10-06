#if DEBUG && canImport(MachO)
import Foundation
import MachO
import OSLog

public enum DiagnosticImageMap {
    public enum Phase: String, Sendable {
        case preparing, finished, failed
    }

    struct Segment: Codable, Sendable {
        let address: UInt64
        let size: UInt64
        let fileAddress: UInt64
    }

    struct Image: Codable, Sendable {
        let name: String?
        let uuid: UUID
        let headerAddress: UInt64
        let segments: [Segment]
    }

    struct Snapshot: Codable, Sendable {
        let processIdentifier: Int32
        let bundleIdentifier: String?
        let build: String?
        let capturedAt: Date
        let phase: String
        let unsupportedImages: Int
        let images: [Image]
    }

    private static let queue = DispatchQueue(label: "com.thatcube.Plozz.DiagnosticImageMap", qos: .utility)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "diagnostic-images")
    private static let registration: Void = {
        _ = Registry.shared
        // dyld holds its image lock during callbacks, so headers cannot unload
        // while being copied. No file I/O or logging runs under that lock.
        _dyld_register_func_for_add_image { header, slide in
            guard let header else { return }
            Registry.shared.add(header, slide: slide)
        }
        _dyld_register_func_for_remove_image { header, _ in
            guard let header else { return }
            Registry.shared.remove(header)
        }
    }()

    public static func record(_ phase: Phase) {
        queue.async {
            do {
                let directory = try FileManager.default.url(
                    for: .cachesDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false
                ).appendingPathComponent("Plozz", isDirectory: true)
                let snapshot = collect(phase)
                try write(snapshot, to: directory.appendingPathComponent("diagnostic-images-\(phase.rawValue).json"))
                logger.notice("Image map phase=\(phase.rawValue, privacy: .public) images=\(snapshot.images.count) unsupported=\(snapshot.unsupportedImages)")
            } catch {
                let error = error as NSError
                logger.error("Image map export failed domain=\(error.domain, privacy: .public) code=\(error.code)")
            }
        }
    }

    static func collect(_ phase: Phase) -> Snapshot {
        _ = registration
        let (images, unsupported) = Registry.shared.snapshot()
        return Snapshot(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            capturedAt: Date(), phase: phase.rawValue, unsupportedImages: unsupported,
            images: images.sorted { $0.headerAddress < $1.headerAddress }
        )
    }

    static func write(_ snapshot: Snapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func image(_ header: UnsafePointer<mach_header>, slide: Int) -> Image? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let raw = UnsafeRawPointer(header)
        let metadata = raw.load(as: mach_header_64.self)
        var offset = MemoryLayout<mach_header_64>.size
        let end = offset + Int(metadata.sizeofcmds)
        var uuid: UUID?
        var name: String? = metadata.filetype == MH_EXECUTE ? "executable" : nil
        var segments: [Segment] = []
        for _ in 0..<metadata.ncmds {
            guard end - offset >= MemoryLayout<load_command>.size else { return nil }
            let pointer = raw.advanced(by: offset)
            let command = pointer.load(as: load_command.self)
            let size = Int(command.cmdsize)
            guard size >= MemoryLayout<load_command>.size, size <= end - offset, size.isMultiple(of: 8) else {
                return nil
            }
            if command.cmd == LC_UUID {
                guard size >= MemoryLayout<uuid_command>.size else { return nil }
                uuid = UUID(uuid: pointer.load(as: uuid_command.self).uuid)
            } else if command.cmd == LC_SEGMENT_64 {
                guard size >= MemoryLayout<segment_command_64>.size else { return nil }
                let segment = pointer.load(as: segment_command_64.self)
                if segment.initprot & VM_PROT_EXECUTE != 0, segment.vmsize > 0 {
                    segments.append(Segment(
                        address: segment.vmaddr &+ UInt64(truncatingIfNeeded: slide),
                        size: segment.vmsize, fileAddress: segment.vmaddr
                    ))
                }
            } else if command.cmd == LC_ID_DYLIB {
                guard size >= MemoryLayout<dylib_command>.size else { return nil }
                let start = Int(pointer.load(as: dylib_command.self).dylib.name.offset)
                guard start >= MemoryLayout<dylib_command>.size, start < size else { return nil }
                let bytes = UnsafeRawBufferPointer(start: pointer.advanced(by: start), count: size - start)
                let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                name = path.split(separator: "/").last.map(String.init)
            }
            offset += size
        }
        guard let uuid, !segments.isEmpty else { return nil }
        return Image(name: name, uuid: uuid, headerAddress: UInt64(UInt(bitPattern: header)), segments: segments)
    }

    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var images: [UInt: Image] = [:]
        private var unsupported: Set<UInt> = []

        func add(_ header: UnsafePointer<mach_header>, slide: Int) {
            let address = UInt(bitPattern: header)
            let image = DiagnosticImageMap.image(header, slide: slide)
            lock.withLock {
                if let image {
                    images[address] = image
                    unsupported.remove(address)
                } else {
                    unsupported.insert(address)
                }
            }
        }

        func remove(_ header: UnsafePointer<mach_header>) {
            let address = UInt(bitPattern: header)
            lock.withLock {
                images.removeValue(forKey: address)
                unsupported.remove(address)
            }
        }

        func snapshot() -> ([Image], Int) {
            lock.withLock { (Array(images.values), unsupported.count) }
        }
    }
}
#endif
