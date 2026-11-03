import CoreUI
import FeatureLiveTVCore
import SwiftUI

#if os(tvOS)
enum PrototypeSearchScope {
    case channels, programs
}
#endif

#if os(iOS)
import UIKit

struct PrototypeToolbarSearch: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool
    let focusRequest: Int
    let submit: () -> Void
    let focusChanged: (Bool) -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            searchable(content).searchToolbarBehavior(.minimize)
        } else {
            searchable(content)
        }
    }

    private func searchable(_ content: Content) -> some View {
        content
            .searchable(text: $query, isPresented: $isPresented, prompt: Text("Search"))
            .background(PrototypeToolbarSearchPlacement())
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .toolbar {
                if sizeClass == .regular && isPresented {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .cancel) {
                            isFocused = false
                            isPresented = false
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            .searchFocused($isFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) {
                isFocused = false
                submit()
            }
            .onChange(of: focusRequest) { _, _ in isFocused = true }
            .onChange(of: isFocused) { _, focused in focusChanged(focused) }
    }
}

private struct PrototypeToolbarSearchPlacement: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.placeSearch()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restorePlacement()
    }

    final class Controller: UIViewController {
        private weak var item: UINavigationItem?
        private weak var search: UISearchController?
        private var previousPlacement: UINavigationItem.SearchBarPlacement = .automatic
        private var previouslyAllowedToolbar = true

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            placeSearch()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            placeSearch()
        }

        func placeSearch() {
            guard #available(iOS 26.0, *),
                  let owner = navigationController?.topViewController,
                  view.isDescendant(of: owner.view),
                  let search = owner.navigationItem.searchController else { return }
            let item = owner.navigationItem
            if self.item !== item || self.search !== search {
                restorePlacement()
                self.item = item
                self.search = search
                previousPlacement = item.preferredSearchBarPlacement
                previouslyAllowedToolbar = item.searchBarPlacementAllowsToolbarIntegration
            }
            // Keep the native expanding search in the header rather than the bottom toolbar.
            if item.searchBarPlacementAllowsToolbarIntegration {
                item.searchBarPlacementAllowsToolbarIntegration = false
            }
            if item.preferredSearchBarPlacement != .integratedButton {
                item.preferredSearchBarPlacement = .integratedButton
            }
        }

        func restorePlacement() {
            if #available(iOS 26.0, *), let item, let search, item.searchController === search {
                item.preferredSearchBarPlacement = previousPlacement
                item.searchBarPlacementAllowsToolbarIntegration = previouslyAllowedToolbar
            }
            item = nil
            search = nil
        }
    }
}

struct PrototypeMobileSearchResults: View {
    let model: LiveTVPrototypeModel
    let imports: LiveTVPrototypeImportModel
    let selectCategory: (String) -> Void
    let watch: (LiveTVPrototypeChannel) -> Void
    let details: (LiveTVPrototypeProgram) -> Void
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                if !model.query.isEmpty, !model.matchingCategories.isEmpty {
                    PrototypeCategorySearchResults(
                        categories: model.matchingCategoryResults, select: selectCategory
                    )
                }
                Section {
                    if model.visibleChannels.isEmpty {
                        Text("No matching channels").foregroundStyle(.secondary)
                    }
                    ForEach(model.visibleChannels) { channel in
                        Button { watch(channel) } label: {
                            HStack(spacing: PrototypeLayout.gap) {
                                PrototypeStationMark(channel: channel, size: 28)
                                    .accessibilityHidden(true)
                                Text(channel.name).font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("live-tv-channel-channels-\(channel.id)")
                    }
                } header: {
                    Text("Channels")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LiveTVProgramSearchView(
                        imports: imports, model: model, query: model.query,
                        watch: watch, showDetails: details
                    )
                }
            }
            .padding(.vertical, PrototypeLayout.smallGap)
        }
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        .modifier(PrototypeScrollUnderlap())
        .accessibilityIdentifier("live-tv-search-results")
        .onChange(of: model.query) { _, _ in position.scrollTo(edge: .top) }
        .onChange(of: model.category) { _, _ in position.scrollTo(edge: .top) }
    }
}
#endif

struct PrototypeCategorySearchResults: View {
    let categories: [LiveTVBrowseCategory]
    let select: (String) -> Void
    @Environment(\.themePalette) private var palette
    #if os(tvOS)
    @ScaledMetric(relativeTo: .headline) private var tileHeight: CGFloat = 128
    #else
    @ScaledMetric(relativeTo: .headline) private var tileHeight: CGFloat = 68
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
            Text("Categories")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
            ScrollView(.horizontal) {
                LazyHStack(spacing: PrototypeLayout.gap) {
                    ForEach(categories) { category in
                        PrototypeCategoryTile(name: category.name, count: category.channelCount) {
                            select(category.name)
                        }
                        .frame(width: PrototypeCategoryTile.searchWidth)
                        .accessibilityIdentifier("live-tv-search-category-\(category.name)")
                    }
                }
                .padding(PrototypeLayout.gap)
            }
            .scrollIndicators(.hidden)
            .frame(height: tileHeight + PrototypeLayout.gap * 4)
            .padding(.horizontal, -PrototypeLayout.gap)
        }
        .accessibilityIdentifier("live-tv-search-categories")
    }
}

private struct PrototypeSearchResultsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var prototypeSearchResults: Bool {
        get { self[PrototypeSearchResultsKey.self] }
        set { self[PrototypeSearchResultsKey.self] = newValue }
    }
}

struct PrototypeSearchResults<Content: View>: View {
    let content: Content
    var body: some View { content.environment(\.prototypeSearchResults, true) }
}

struct PrototypeSearchFocusBoundary<Content: View>: View {
    @Environment(\.prototypeSearchResults) private var isSearchResult
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(tvOS)
        if isSearchResult {
            PrototypeSearchRowHost(content: content())
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

#if os(tvOS)
import UIKit

/// Give native Search a row-sized focused UIView, not the entire lazy stack.
/// Its keyboard-collapse scrolling still runs unchanged using this real boundary.
struct PrototypeSearchRowHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    struct HostedContent: View {
        let content: Content
        let environment: EnvironmentValues
        var body: some View { content.environment(\.self, environment) }
    }

    func makeUIViewController(context: Context) -> UIHostingController<HostedContent> {
        let controller = UIHostingController(rootView: HostedContent(content: content, environment: context.environment))
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<HostedContent>, context: Context) {
        controller.rootView = HostedContent(content: content, environment: context.environment)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiViewController: UIHostingController<HostedContent>, context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiViewController.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
    }
}
#endif
