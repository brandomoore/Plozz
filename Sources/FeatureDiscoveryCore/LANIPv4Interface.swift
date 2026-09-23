import Foundation
#if canImport(Darwin)
import Darwin

struct LANIPv4Interface: Sendable {
    /// IPv4 addresses in network byte order, matching sockaddr_in.
    let address: UInt32
    let netmask: UInt32

    static func active() -> [Self] {
        var result: [Self] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard let socket = current.pointee.ifa_addr,
                  socket.pointee.sa_family == sa_family_t(AF_INET),
                  (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_POINTOPOINT) == 0, (flags & IFF_BROADCAST) != 0,
                  let mask = current.pointee.ifa_netmask else { continue }
            result.append(Self(
                address: socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr },
                netmask: mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }))
        }
        return result
    }

    /// HTTP discovery stays on private, directly connected LANs and never
    /// expands a large corporate/VPN range beyond the device's own /24.
    func siloCandidates() -> [URL] {
        Self.siloCandidates(host: UInt32(bigEndian: address), mask: UInt32(bigEndian: netmask))
    }

    static func siloCandidates(host: UInt32, mask: UInt32) -> [URL] {
        let isPrivate = host & 0xFF00_0000 == 0x0A00_0000
            || host & 0xFFF0_0000 == 0xAC10_0000
            || host & 0xFFFF_0000 == 0xC0A8_0000
            || host & 0xFFFF_0000 == 0xA9FE_0000
        guard isPrivate, mask != 0 else { return [] }
        let inverseMask = ~mask
        guard inverseMask & (inverseMask &+ 1) == 0 else { return [] }
        let effectiveMask = mask | 0xFFFF_FF00
        let network = host & effectiveMask
        let broadcast = network | ~effectiveMask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast).compactMap { address in
            guard address != host else { return nil }
            let text = "\(address >> 24).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
            return URL(string: "http://\(text):8090")
        }
    }
}
#endif
