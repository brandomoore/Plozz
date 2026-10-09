#if canImport(SwiftUI)
import SwiftUI
import CoreModels

public struct ServerIdentityChip: View {
    @Environment(\.themePalette) private var palette
    private let server: MediaServer

    public init(server: MediaServer) {
        self.server = server
    }

    public var body: some View {
        HStack(spacing: 8) {
            ProviderBrandMark(provider: server.provider, size: logoSize, showsBackground: false)
                .accessibilityHidden(true)
            Text(verbatim: server.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .plozzForeground(.primary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(server.provider.displayName), \(server.name)"))
    }

    private var logoSize: CGFloat {
        #if os(iOS)
        28
        #else
        44
        #endif
    }
}
#endif
