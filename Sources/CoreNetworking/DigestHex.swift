import Foundation

public enum DigestHex {
    public static func encode<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
