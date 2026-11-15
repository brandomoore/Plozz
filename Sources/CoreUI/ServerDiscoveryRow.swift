#if canImport(SwiftUI)
import Foundation
import SwiftUI

public struct ServerDiscoveryRow<Icon: View>: View {
    private let name: Text
    private let address: URL
    private let icon: Icon

    public init(name: Text, address: URL, @ViewBuilder icon: () -> Icon) {
        self.name = name
        self.address = address
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: 12) {
            icon.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                name.font(.headline)
                Text(verbatim: address.absoluteString)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
    }
}
#endif
