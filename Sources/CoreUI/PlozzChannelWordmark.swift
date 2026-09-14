#if canImport(SwiftUI)
import SwiftUI

struct PlozzChannelIdentity: Equatable {
    let paletteIndex: Int

    init(channelID: String) {
        // FNV-1a is stable across launches and platforms; Swift's Hasher is not.
        let hash = channelID.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        paletteIndex = Int(hash % UInt64(Self.fields.count))
    }

    var field: Color { Self.fields[paletteIndex] }
    static let ink = Color(red: 255 / 255, green: 247 / 255, blue: 232 / 255)
    private static let fields: [Color] = [
        Color(red: 23 / 255, green: 54 / 255, blue: 82 / 255),
        Color(red: 21 / 255, green: 76 / 255, blue: 73 / 255),
        Color(red: 71 / 255, green: 48 / 255, blue: 77 / 255),
        Color(red: 100 / 255, green: 59 / 255, blue: 53 / 255),
        Color(red: 61 / 255, green: 73 / 255, blue: 49 / 255)
    ]
}

struct PlozzChannelWordmark: View {
    let name: String
    let identity: PlozzChannelIdentity
    let size: CGSize
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: size.height * 0.055) {
            HStack(spacing: size.height * 0.07) {
                Text(verbatim: "PLOZZ")
                    .font(.system(size: size.height * 0.105, weight: .black, design: .rounded))
                    .tracking(size.height * 0.014)
                    .padding(.horizontal, size.height * 0.045)
                    .padding(.vertical, size.height * 0.02)
                    .foregroundStyle(identity.field)
                    .background(PlozzChannelIdentity.ink)
                Rectangle().frame(height: max(1, size.height * 0.025))
                Rectangle()
                    .frame(width: size.height * 0.04, height: max(1, size.height * 0.025))
            }
            Text(name)
                .textCase(.uppercase)
                .font(.system(size: size.height * 0.42, weight: .black).width(.compressed))
                .tracking(-size.height * 0.007)
                .lineLimit(2)
                .minimumScaleFactor(0.28)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .foregroundStyle(PlozzChannelIdentity.ink)
        .padding(.horizontal, size.width * 0.10)
        .padding(.vertical, size.height * 0.12)
        .frame(width: size.width, height: size.height)
        .background(identity.field)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    PlozzChannelIdentity.ink.opacity(contrast == .increased ? 0.4 : 0.14),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
        .accessibilityHidden(true)
    }
}
#endif
