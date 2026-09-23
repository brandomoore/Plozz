#if os(iOS)
import CoreModels
import SwiftUI

public struct ManagedProviderPicker: View {
    @Binding private var provider: ProviderKind

    public init(provider: Binding<ProviderKind>) {
        _provider = provider
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Native pickers extract option images without their SwiftUI sizing.
            ProviderBrandMark(provider: provider, size: 24, showsBackground: false)
                .accessibilityHidden(true)
            Picker("Provider", selection: $provider) {
                ForEach([ProviderKind.jellyfin, .emby, .plex, .silo], id: \.self) { kind in
                    Text(verbatim: kind.displayName).tag(kind)
                }
            }
        }
    }
}
#endif
