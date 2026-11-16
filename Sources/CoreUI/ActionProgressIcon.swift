#if canImport(SwiftUI)
import SwiftUI

/// Keeps the symbol's layout footprint while an action is waiting to run.
public struct ActionProgressIcon: View {
    public let systemName: String
    public let isLoading: Bool
    public let onLight: Bool?

    public init(systemName: String, isLoading: Bool, onLight: Bool? = nil) {
        self.systemName = systemName
        self.isLoading = isLoading
        self.onLight = onLight
    }

    public var body: some View {
        Image(systemName: systemName)
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    Group {
                        if let onLight {
                            ProgressView().tint(onLight ? Color.black : Color.white)
                        } else {
                            ProgressView()
                        }
                    }
                    .controlSize(.small)
                    .accessibilityHidden(true)
                }
            }
    }
}
#endif
