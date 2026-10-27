import CoreModels
@testable import CoreUI
import SwiftUI

struct PlexHomeOnboardingFixture: View {
    @State private var result: String?
    @State private var imported = false

    private var users: [PlexHomeUser] {
        let initial: [PlexHomeUser] = [
            .init(id: "parent", name: "alexander-morgan", requiresPIN: true, isAdmin: true),
            .init(id: "child", name: "Sam", requiresPIN: false, isRestricted: true),
            .init(id: "guest", name: "Taylor", requiresPIN: false)
        ]
        guard ProcessInfo.processInfo.arguments.contains("--plex-home-long-list") else { return initial }
        return initial + (1...13).map {
            .init(id: "viewer-\($0)", name: String(format: "Viewer %02d", $0), requiresPIN: false)
        }
    }

    var body: some View {
        Group {
            if let result {
                Text(verbatim: result)
                    .accessibilityIdentifier("plex-home-result")
            } else {
                PlexHomeOnboardingContent(users: users,
                    reduceMotion: ProcessInfo.processInfo.arguments.contains("--plex-home-reduce-motion"), onImportAll: {
                    imported = true
                    return .added
                }) { user, addAll in
                    result = addAll && !imported ? "incorrect-order" : "\(user.id):\(addAll ? "all" : "one")"
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground(palette: .dark) }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        .environment(\.plozzMetrics, .touch(density: .standard))
        #endif
    }
}
