#if canImport(SwiftUI)
import Foundation
import SwiftUI

public struct ServerDiscoveryRow<Icon: View>: View {
    private let name: Text
    private let address: URL
    private let icon: Icon
    private let showsDisclosure: Bool

    public init(name: Text, address: URL, showsDisclosure: Bool = true, @ViewBuilder icon: () -> Icon) {
        self.name = name
        self.address = address
        self.icon = icon()
        self.showsDisclosure = showsDisclosure
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
            if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
    }
}
#endif
