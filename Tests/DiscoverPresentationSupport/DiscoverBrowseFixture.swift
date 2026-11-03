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
        let failedPage = ProcessInfo.processInfo.arguments.contains("--failed-page-discover")
        let shortPage = ProcessInfo.processInfo.arguments.contains("--short-discover")
        let slowPage = ProcessInfo.processInfo.arguments.contains("--slow-page-discover")
        _model = State(initialValue: DiscoverBrowseModel(
            store: .init(defaults: defaults), isCurrent: { true }
        ) { feed, page in
            if slowPage && page > 1 { try await Task.sleep(for: .seconds(3)) }
            if failure || (failedPage && page == 2) { throw AppError.serverUnreachable }
            if empty { return DiscoverPage(items: [], nextPage: nil) }
            let count = shortPage ? 3 : 20
            return DiscoverPage(items: (0..<count).map { index in
                MediaItem(
                    id: "\(feed.rawValue)-\(page)-\(index)",
                    title: "Title \((page - 1) * count + index + 1)",
                    kind: feed.kind ?? .movie,
                    isPlayed: index % 3 == 2,
                    availability: index % 3 == 1 ? .unknown : nil,
                    locallyValidatedPlayableSource: index % 3 != 1
                )
            }, nextPage: page < 3 ? page + 1 : nil)
        })
        #if os(iOS)
        SyncSetupFeatureFlag().isEnabled = false
        appModel = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        #endif
    }

    var body: some View {
        NavigationStack {
            DiscoverBrowseView(model: model) { feed, items, loading, loadMore in
                #if os(iOS)
                PlozziOSHomeMediaRail(
                    title: Text(feed.title), items: items, style: .poster, appModel: appModel,
                    loadingPlaceholderCount: loading ? 6 : 0,
                    onLoadMore: loadMore
                )
                #else
                MediaRowView(
                    title: Text(feed.title), items: items,
                    loadingPlaceholderCount: loading ? 6 : 0,
                    onSelect: { selection = $0 }
                )
                .loadingMore(loadMore)
                #endif
            }
            #if os(iOS)
            .toolbar {
                PlozziOSSettingsToolbarItem(horizontalPlacement: .primaryAction, action: {})
            }
            #endif
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
