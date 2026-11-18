import SwiftUI

public struct MediaSourceUnavailableView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "Source Unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("Connect or enable this source in Settings, then try again.")
        )
    }
}
