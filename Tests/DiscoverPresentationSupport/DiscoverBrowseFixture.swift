import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
#if os(iOS)
import FeatureAuth
@testable import AppShelliOS
#endif

struct DiscoverBrowseFixture: View {
    @State private var model: DiscoverBrowseModel
    @State private var selection: MediaItem?
    #if os(iOS)
    private let appModel: PlozziOSAppModel
    #endif

    init() {
        let defaults = UserDefaults(suiteName: "DiscoverBrowseFixture.\(UUID().uuidString)")!
        let empty = ProcessInfo.processInfo.arguments.contains("--empty-discover")
        let failure = ProcessInfo.processInfo.arguments.contains("--failed-discover")
        _model = State(initialValue: DiscoverBrowseModel(
            store: .init(defaults: defaults), isCurrent: { true }
        ) { feed, page in
            if failure { throw AppError.serverUnreachable }
            if empty { return DiscoverPage(items: [], nextPage: nil) }
            return DiscoverPage(items: [
                MediaItem(
                    id: "\(feed.rawValue)-\(page)-owned", title: "Available title", kind: feed.kind ?? .movie,
                    locallyValidatedPlayableSource: true
                ),
                MediaItem(
                    id: "\(feed.rawValue)-\(page)-external", title: "Discover title", kind: feed.kind ?? .movie,
                    availability: .unknown, locallyValidatedPlayableSource: false
                ),
                MediaItem(
                    id: "\(feed.rawValue)-\(page)-watched", title: "Watched title", kind: feed.kind ?? .movie,
                    isPlayed: true, locallyValidatedPlayableSource: true
                )
            ], nextPage: page < 3 ? page + 1 : nil)
        })
        #if os(iOS)
        appModel = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        #endif
    }

    var body: some View {
        NavigationStack {
            DiscoverBrowseView(model: model) { feed, items, loading in
                #if os(iOS)
                PlozziOSHomeMediaRail(
                    title: Text(feed.title), items: items, style: .poster, appModel: appModel,
                    loadingPlaceholderCount: loading ? 6 : 0
                )
                #else
                MediaRowView(
                    title: Text(feed.title), items: items,
                    loadingPlaceholderCount: loading ? 6 : 0,
                    onSelect: { selection = $0 }
                )
                #endif
            }
            .background { AppBackground(palette: .dark) }
            .navigationDestination(item: $selection) { item in
                Text(verbatim: item.title)
            }
        }
        .environment(\.themePalette, .dark)
        #if os(iOS)
        .environment(appModel)
        .environment(\.plozzMetrics, .touch(density: .standard))
        #endif
        .preferredColorScheme(.dark)
    }
}
