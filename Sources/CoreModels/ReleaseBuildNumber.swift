import Foundation

public struct ReleaseBuildNumber: Codable, Hashable, Comparable, Sendable,
    ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let description: String
    private let components: [Int]

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(parts[0]), (1...9999).contains(major) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ (0...99).contains($0) }),
              numbers.map(String.init).joined(separator: ".") == value else { return nil }
        description = value
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    public init(integerLiteral value: Int) {
        precondition((1...9999).contains(value), "A release build must be between 1 and 9999.")
        description = String(value)
        components = [value, 0, 0]
    }

    public var releaseID: String {
        let suffix = description.split(separator: ".").dropFirst()
        return ([String(format: "release/%03d", components[0])] + suffix.map(String.init)).joined(separator: ".")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }

    public func hash(into hasher: inout Hasher) { hasher.combine(components) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value: String
        if let integer = try? container.decode(Int.self) {
            value = String(integer)
        } else {
            value = try container.decode(String.self)
        }
        guard let build = Self(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid release build \(value).")
        }
        self = build
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let integer = Int(description) {
            try container.encode(integer)
        } else {
            try container.encode(description)
        }
    }
}
