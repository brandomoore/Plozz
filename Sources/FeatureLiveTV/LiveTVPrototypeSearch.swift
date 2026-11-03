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
    var dismissed: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .background(PrototypeToolbarSearchPresentation(
                query: $query, isPresented: $isPresented, focusRequest: focusRequest,
                submit: submit, focusChanged: focusChanged, dismissed: dismissed
            ))
    }
}

private struct PrototypeToolbarSearchPresentation: UIViewControllerRepresentable {
    @Binding var query: String
    @Binding var isPresented: Bool
    let focusRequest: Int
    let submit: () -> Void
    let focusChanged: (Bool) -> Void
    let dismissed: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var placeholder: String {
        String(localized: LocalizedStringResource("Search", locale: locale)) // l10n:content — native UIKit field follows the app locale
    }

    func makeUIViewController(context: Context) -> Controller { Controller(configuration: self) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configuration = self
        controller.synchronize()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.search.delegate = nil
        controller.search.searchResultsUpdater = nil
        controller.search.searchBar.delegate = nil
        controller.search.isActive = false
        controller.restorePlacement()
    }

    final class Controller: UIViewController, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {
        var configuration: PrototypeToolbarSearchPresentation
        let search = UISearchController(searchResultsController: nil)
        private weak var owner: UIViewController?
        private var previousSearch: UISearchController?
        private var previousPinnedGroup: UIBarButtonItemGroup?
        private var previousLeadingGroups: [UIBarButtonItemGroup] = []
        private var previousTrailingGroups: [UIBarButtonItemGroup] = []
        private var previousPlacement: UINavigationItem.SearchBarPlacement = .automatic
        private var previouslyAllowedToolbar = true
        private var previouslyDefinedContext = false
        private var lastFocusRequest: Int?
        private var synchronizing = false
        private var hasPresentationRequest = false
        private var isDismissing = false
        private var dismissalGeneration = 0
        private lazy var closeItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeSearch)
        )
        private lazy var closeGroup = UIBarButtonItemGroup(barButtonItems: [closeItem], representativeItem: nil)
        private lazy var clearButton: UIButton = {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            button.tintColor = .tertiaryLabel
            button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            button.addTarget(self, action: #selector(clearQuery), for: .touchUpInside)
            return button
        }()

        init(configuration: PrototypeToolbarSearchPresentation) {
            self.configuration = configuration
            super.init(nibName: nil, bundle: nil)
            search.delegate = self
            search.searchResultsUpdater = self
            search.searchBar.delegate = self
            search.searchBar.autocorrectionType = .no
            search.searchBar.autocapitalizationType = .none
            search.searchBar.tintColor = .label
            search.obscuresBackgroundDuringPresentation = false
            search.hidesNavigationBarDuringPresentation = false
            search.automaticallyShowsCancelButton = false
            // Integrated iPad search treats its built-in Clear as Cancel. Keep clearing independent of dismissal.
            search.searchBar.searchTextField.clearButtonMode = .never
            search.searchBar.searchTextField.rightView = clearButton
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            synchronize()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize()
        }

        func synchronize() {
            guard !synchronizing else { return }
            synchronizing = true
            defer { synchronizing = false }
            if search.searchBar.text != configuration.query { search.searchBar.text = configuration.query }
            search.searchBar.placeholder = configuration.placeholder
            search.searchBar.searchTextField.tintColor = UIColor(configuration.palette.accent)
            closeItem.accessibilityLabel = String(localized: LocalizedStringResource(
                "Close", locale: configuration.locale
            )) // l10n:content — native close action
            clearButton.accessibilityLabel = String(localized: LocalizedStringResource(
                "Clear search", locale: configuration.locale
            )) // l10n:content — native clear action
            search.searchBar.searchTextField.rightViewMode = configuration.query.isEmpty ? .never : .always
            if configuration.isPresented { hasPresentationRequest = true }
            guard isViewLoaded, view.window != nil else { return }
            guard !isDismissing else { return }
            if configuration.isPresented {
                guard let owner = navigationController?.topViewController,
                      view.isDescendant(of: owner.view) else { return }
                if self.owner !== owner {
                    restorePlacement()
                    self.owner = owner
                    let item = owner.navigationItem
                    previousSearch = item.searchController
                    previousPinnedGroup = item.pinnedTrailingGroup
                    previousLeadingGroups = item.leadingItemGroups
                    previousTrailingGroups = item.trailingItemGroups
                    previousPlacement = item.preferredSearchBarPlacement
                    previouslyDefinedContext = owner.definesPresentationContext
                    owner.definesPresentationContext = true
                    if #available(iOS 26.0, *) {
                        previouslyAllowedToolbar = item.searchBarPlacementAllowsToolbarIntegration
                        item.searchBarPlacementAllowsToolbarIntegration = false
                        item.preferredSearchBarPlacement = .integratedButton
                    }
                    // Attach only while searching: the toolbar owns the collapsed Search button.
                    UIView.performWithoutAnimation {
                        item.leadingItemGroups = []
                        item.trailingItemGroups = []
                        item.searchController = search
                        item.pinnedTrailingGroup = closeGroup
                        owner.navigationController?.navigationBar.layoutIfNeeded()
                    }
                }
                if configuration.reduceMotion { UIView.performWithoutAnimation { activateSearch() } }
                else { activateSearch() }
            } else if owner != nil {
                beginDismissal()
            } else if hasPresentationRequest {
                hasPresentationRequest = false
                configuration.dismissed()
            }
        }

        func restorePlacement() {
            dismissalGeneration += 1
            isDismissing = false
            restoreNavigationItem()
        }

        private func restoreNavigationItem() {
            if let owner, owner.navigationItem.searchController === search {
                let item = owner.navigationItem
                item.searchController = previousSearch
                if item.pinnedTrailingGroup === closeGroup { item.pinnedTrailingGroup = previousPinnedGroup }
                item.leadingItemGroups = previousLeadingGroups
                item.trailingItemGroups = previousTrailingGroups
                item.preferredSearchBarPlacement = previousPlacement
                if #available(iOS 26.0, *) {
                    item.searchBarPlacementAllowsToolbarIntegration = previouslyAllowedToolbar
                }
                owner.definesPresentationContext = previouslyDefinedContext
            }
            owner = nil
            previousSearch = nil
            previousPinnedGroup = nil
            previousLeadingGroups = []
            previousTrailingGroups = []
            lastFocusRequest = nil
        }

        private func activateSearch() {
            if !search.isActive { search.isActive = true }
            if lastFocusRequest != configuration.focusRequest {
                lastFocusRequest = configuration.focusRequest
                search.searchBar.becomeFirstResponder()
            }
        }

        func updateSearchResults(for searchController: UISearchController) {
            guard !synchronizing, configuration.isPresented else { return }
            let query = searchController.searchBar.text ?? ""
            if configuration.query != query { configuration.query = query }
        }

        func didPresentSearchController(_ searchController: UISearchController) {
            if configuration.isPresented { search.searchBar.becomeFirstResponder() }
        }

        func willDismissSearchController(_ searchController: UISearchController) {
            if !isDismissing, configuration.isPresented { configuration.isPresented = false }
        }

        private func beginDismissal() {
            guard !isDismissing else { return }
            isDismissing = true
            let bar = owner?.navigationController?.navigationBar
            bar?.layoutIfNeeded()
            dismissalGeneration += 1
            let generation = dismissalGeneration
            // Wait for UIKit's actual bar animations, not just modal-search dismissal or a guessed delay.
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.dismissalGeneration == generation else { return }
                self.finishDismissal()
            }
            let contract = {
                self.search.isActive = false
                self.search.searchBar.resignFirstResponder()
                bar?.layoutIfNeeded()
            }
            if configuration.reduceMotion { UIView.performWithoutAnimation(contract) }
            else { contract() }
            CATransaction.commit()
        }

        private func finishDismissal() {
            if configuration.isPresented {
                restorePlacement()
                synchronize()
                return
            }
            let bar = owner?.navigationController?.navigationBar
            let restore = {
                self.restoreNavigationItem()
                self.hasPresentationRequest = false
                self.configuration.dismissed()
                bar?.layoutIfNeeded()
            }
            guard let bar, !configuration.reduceMotion else {
                UIView.performWithoutAnimation(restore)
                isDismissing = false
                return
            }
            let generation = dismissalGeneration
            // Regular-width UIKit can finish dismissing before it retires the expanded field.
            UIView.transition(with: bar, duration: 0.2, options: .transitionCrossDissolve, animations: restore) { [weak self] _ in
                guard let self, self.dismissalGeneration == generation else { return }
                self.isDismissing = false
                if self.configuration.isPresented { self.synchronize() }
            }
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            configuration.focusChanged(true)
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            configuration.focusChanged(false)
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
            configuration.submit()
        }

        @objc private func closeSearch() {
            configuration.isPresented = false
        }

        @objc private func clearQuery() {
            search.searchBar.text = ""
            if !configuration.query.isEmpty { configuration.query = "" }
            search.searchBar.becomeFirstResponder()
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
