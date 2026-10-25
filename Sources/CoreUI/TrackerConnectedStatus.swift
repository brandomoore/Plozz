#if canImport(SwiftUI)
import SwiftUI

public struct TrackerConnectedStatus: View {
    private let username: String?

    public init(username: String? = nil) {
        self.username = username
    }

    public var body: some View {
        Label {
            if let username {
                Text("Connected as \(username)")
            } else {
                Text("Connected")
            }
        } icon: {
            #if os(tvOS)
            Image(systemName: "checkmark.seal.fill")
            #else
            Image(systemName: "checkmark.circle.fill")
            #endif
        }
        #if os(tvOS)
        .font(.headline)
        #endif
        .foregroundStyle(.green)
    }
}
#endif
