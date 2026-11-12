#if canImport(SwiftUI)
import SwiftUI

public struct VideoLoadingPlaceholder: View {
    private let isLoading: Bool
    @Environment(\.themePalette) private var palette

    public init(isLoading: Bool = true) {
        self.isLoading = isLoading
    }

    public var body: some View {
        Rectangle()
            .fill(palette.fill)
            .shimmering(active: isLoading)
            .background(.black)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
