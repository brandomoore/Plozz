import Foundation

/// An original short instrumental phrase. No bundled or downloaded recording.
enum ThemeMusicPreviewSample {
    static func data() -> Data {
        let sampleRate = 22_050
        let duration = 8
        let count = sampleRate * duration
        let melody = [261.63, 329.63, 392.0, 523.25, 440.0, 392.0, 329.63, 293.66]
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let beat = time.truncatingRemainder(dividingBy: 1)
            let envelope = min(1, beat / 0.04) * max(0, 1 - beat) * min(1, (8 - time) / 0.2)
            let note = melody[min(melody.count - 1, Int(time))]
            let lead = sin(2 * .pi * note * time) + 0.2 * sin(4 * .pi * note * time)
            let chord = [130.815, 164.815, 196.0].reduce(0.0) {
                $0 + sin(2 * .pi * $1 * time) * 0.12
            }
            append(Int16((lead + chord) * envelope * 18_000))
        }
        return data
    }
}
