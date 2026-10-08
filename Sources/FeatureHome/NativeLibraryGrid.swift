#if os(tvOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit

@MainActor
final class NativeLibraryScrollTarget {
    weak var controller: NativeLibraryGridController?
    weak var focusOwner: NativeLibraryFocusHostController?
    weak var header: NativeLibraryHeaderController?
    private(set) var headerOffset: CGFloat = 0

    func scroll(to index: Int, focusesItem: Bool = false) {
        controller?.scroll(to: index, focusesItem: focusesItem)
    }

    func moveHeader(with offset: CGFloat) {
        headerOffset = max(0, offset)
        header?.scrollOffset = headerOffset
    }
}

// The controls stay mounted through query replacements, but move with the native scroll viewport.
struct NativeLibraryScrollingHeader<Content: View>: UIViewControllerRepresentable {
    let scrollTarget: NativeLibraryScrollTarget
    let content: Content

    func makeUIViewController(context: Context) -> NativeLibraryHeaderController {
        let controller = NativeLibraryHeaderController()
        scrollTarget.header = controller
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: NativeLibraryHeaderController, context: Context) {
        let source = context.environment
        // Another hosting tree's private accessibility state can keep restored controls hidden.
        controller.host.rootView = AnyView(content.transformEnvironment(\.self) { target in
            target.colorScheme = source.colorScheme
            target.locale = source.locale
            target.layoutDirection = source.layoutDirection
            target.dynamicTypeSize = source.dynamicTypeSize
            target.displayScale = source.displayScale
            target.isEnabled = source.isEnabled
            target.redactionReasons = source.redactionReasons
            target.themePalette = source.themePalette
            target.plozzMetrics = source.plozzMetrics
            target.plozzReduceTransparency = source.plozzReduceTransparency
        })
        controller.scrollOffset = scrollTarget.headerOffset
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiViewController: NativeLibraryHeaderController, context: Context
    ) -> CGSize? {
        uiViewController.host.sizeThatFits(in: CGSize(
            width: proposal.width ?? HomeHeroLayout.screenWidth,
            height: proposal.height ?? .greatestFiniteMagnitude
        ))
    }
}

final class NativeLibraryHeaderController: UIViewController {
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    var scrollOffset: CGFloat = 0 {
        didSet { if isViewLoaded { positionHeader() } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        host.view.bounds = view.bounds
        positionHeader()
    }

    private func positionHeader() {
        host.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - scrollOffset)
    }
}

struct NativeLibraryFocusHost<Content: View>: UIViewControllerRepresentable {
    let scrollTarget: NativeLibraryScrollTarget
    let content: Content

    func makeUIViewController(context: Context) -> NativeLibraryFocusHostController {
        let controller = NativeLibraryFocusHostController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: NativeLibraryFocusHostController, context: Context) {
        scrollTarget.focusOwner = controller
        controller.host.rootView = AnyView(content.environment(\.self, context.environment))
    }

    static func dismantleUIViewController(_ controller: NativeLibraryFocusHostController, coordinator: ()) {
        controller.host.rootView = AnyView(EmptyView())
    }
}

final class NativeLibraryFocusHostController: UIViewController {
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    private weak var requestedFocusEnvironment: (any UIFocusEnvironment)?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        requestedFocusEnvironment.map { [$0] } ?? super.preferredFocusEnvironments
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }

    func requestFocus(to environment: any UIFocusEnvironment, using system: UIFocusSystem) {
        // Header and grid are siblings; their common owner must request the handoff.
        requestedFocusEnvironment = environment
        defer { requestedFocusEnvironment = nil }
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
    }
}

struct NativeLibraryGrid<Header: View>: UIViewControllerRepresentable {
    let viewModel: LibraryBrowseViewModel
    let total: Int
    let generation: Int
    let spoilerSettings: SpoilerSettings
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let scrollTarget: NativeLibraryScrollTarget
    let hidesScrollIndicator: Bool
    let header: Header
    let onSelect: (MediaItem, Int) -> Void
    let onLoaded: (Int) -> Void

    func makeUIViewController(context: Context) -> NativeLibraryGridController {
        let controller = NativeLibraryGridController()
        scrollTarget.controller = controller
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: NativeLibraryGridController, context: Context) {
        controller.focusOwner = scrollTarget.focusOwner
        controller.scrollTarget = scrollTarget
        controller.update(
            model: viewModel, total: total, generation: generation, spoilerSettings: spoilerSettings,
            environment: context.environment, leadingInset: leadingInset, trailingInset: trailingInset,
            header: AnyView(header.environment(\.self, context.environment)),
            hidesScrollIndicator: hidesScrollIndicator,
            onSelect: onSelect, onLoaded: onLoaded
        )
    }

    static func dismantleUIViewController(_ controller: NativeLibraryGridController, coordinator: ()) {
        controller.stopObserving()
    }
}

final class NativeLibraryGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    weak var focusOwner: NativeLibraryFocusHostController?
    weak var scrollTarget: NativeLibraryScrollTarget?
    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let headerHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let indicatorHider = ScrollIndicatorHiderController()
    private var model: LibraryBrowseViewModel?
    private var generation = -1
    private var total = 0
    private var environment = EnvironmentValues()
    private var spoilerSettings = SpoilerSettings.default
    private var leadingInset: CGFloat = 0
    private var trailingInset: CGFloat = 0
    private var onSelect: ((MediaItem, Int) -> Void)?
    private var onLoaded: ((Int) -> Void)?
    private var bindings: [ObjectIdentifier: CellBinding] = [:]
    private var pendingNavigation: MediaItem?
    private var lastFocusedIndex: IndexPath?
    private var requestedFocusIndex: IndexPath?
    private var measuredHeaderHeight: CGFloat = 0
    private var hidesScrollIndicator = false
    private var viewportReport: Task<Void, Never>?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        requestedFocusIndex == nil ? super.preferredFocusEnvironments : [collection]
    }

    private struct CellBinding {
        let index: Int
        let generation: Int
        let token: UUID
        var load: Task<Void, Never>?
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collection.backgroundColor = .clear
        collection.clipsToBounds = false
        collection.dataSource = self
        collection.delegate = self
        collection.contentInsetAdjustmentBehavior = .never
        collection.register(NativeTVLibraryCell.self, forCellWithReuseIdentifier: "poster")
        collection.register(
            UICollectionReusableView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "header")
        layout.sectionHeadersPinToVisibleBounds = false
        view.addSubview(collection)
        addChild(headerHost)
        headerHost.view.backgroundColor = .clear
        headerHost.didMove(toParent: self)
        addChild(indicatorHider)
        collection.addSubview(indicatorHider.view)
        indicatorHider.didMove(toParent: self)
    }

    func update(
        model: LibraryBrowseViewModel, total: Int, generation: Int, spoilerSettings: SpoilerSettings,
        environment: EnvironmentValues, leadingInset: CGFloat, trailingInset: CGFloat,
        header: AnyView, hidesScrollIndicator: Bool,
        onSelect: @escaping (MediaItem, Int) -> Void, onLoaded: @escaping (Int) -> Void
    ) {
        let reset = self.model !== model || self.generation != generation
        let previousCount = self.total
        if !reset, previousCount != total {
            collection.layoutIfNeeded()
        }
        if reset { stopObserving() }
        self.model = model
        self.total = total
        self.generation = generation
        self.environment = environment
        self.spoilerSettings = spoilerSettings
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.onSelect = onSelect
        self.onLoaded = onLoaded
        self.hidesScrollIndicator = hidesScrollIndicator
        headerHost.rootView = AnyView(
            header.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { [weak self] height in
                    guard let self, height.isFinite, height >= 0,
                          abs(self.measuredHeaderHeight - height) > 0.5 else { return }
                    self.measuredHeaderHeight = height
                    self.view.setNeedsLayout()
                }
        )
        loadViewIfNeeded()
        indicatorHider.hidden = hidesScrollIndicator
        collection.semanticContentAttribute =
            environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        if reset {
            lastFocusedIndex = nil
            requestedFocusIndex = nil
            collection.reloadData()
            collection.setContentOffset(CGPoint(x: 0, y: -collection.contentInset.top), animated: false)
        } else {
            if previousCount != total {
                if let lastFocusedIndex, lastFocusedIndex.item >= total {
                    self.lastFocusedIndex = total > 0 ? IndexPath(item: total - 1, section: 0) : nil
                }
                UIView.performWithoutAnimation {
                    collection.performBatchUpdates {
                        if total > previousCount {
                            collection.insertItems(at: (previousCount..<total).map { IndexPath(item: $0, section: 0) })
                        } else {
                            collection.deleteItems(at: (total..<previousCount).map { IndexPath(item: $0, section: 0) })
                        }
                    }
                }
            }
            for cell in collection.visibleCells {
                guard let cell = cell as? NativeTVLibraryCell else { continue }
                cell.configure(item: cell.item, spoilerSettings: spoilerSettings, environment: environment)
            }
        }
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutViewport()
        guard view.bounds.width > 0 else { return }
        let metrics = environment.plozzMetrics
        let columns = max(1, metrics.libraryPosterColumns.count)
        let usable = view.bounds.width - leadingInset - trailingInset - CGFloat(columns - 1) * metrics.gridSpacing
        let width = max(1, floor(usable / CGFloat(columns)))
        let size = CGSize(width: width, height: NativeTVLibraryCell.height(for: width, environment: environment))
        let headerHeight: CGFloat
        if headerHost.view.bounds.width != view.bounds.width || measuredHeaderHeight <= 0 {
            headerHeight = headerHost.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        } else {
            headerHeight = measuredHeaderHeight
        }
        let headerSize = CGSize(width: view.bounds.width, height: ceil(headerHeight))
        let insets = UIEdgeInsets(
            top: metrics.sectionTitleSpacing, left: leadingInset,
            bottom: PlozzTheme.Metrics.screenVerticalPadding, right: trailingInset)
        if layout.itemSize != size || layout.headerReferenceSize != headerSize
            || layout.sectionInset != insets || layout.minimumLineSpacing != metrics.gridSpacing
        {
            layout.itemSize = size
            layout.minimumInteritemSpacing = metrics.gridSpacing
            layout.minimumLineSpacing = metrics.gridSpacing
            layout.sectionInset = insets
            layout.headerReferenceSize = headerSize
            layout.invalidateLayout()
        }
        headerHost.view.frame = CGRect(origin: .zero, size: headerSize)
        scheduleViewportReport()
    }

    private func layoutViewport() {
        var frame = view.bounds
        if let focusOwner, view.window != nil, focusOwner.view.window === view.window {
            let visible = view.convert(focusOwner.view.bounds, from: focusOwner.view)
            let top = min(frame.minY, visible.minY)
            let bottom = max(frame.maxY, visible.maxY)
            frame = CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top)
        }
        let insets = UIEdgeInsets(
            top: view.bounds.minY - frame.minY, left: 0,
            bottom: frame.maxY - view.bounds.maxY, right: 0)
        guard collection.frame != frame || collection.contentInset != insets else { return }
        let offset = collection.contentOffset.y + collection.contentInset.top
        // UIKit culls artwork at the viewport edge even with clipping disabled.
        // Use the full presentation bounds; insets retain the header's initial space.
        collection.frame = frame
        collection.contentInset = insets
        collection.contentOffset = CGPoint(x: collection.contentOffset.x, y: offset - insets.top)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrollTarget?.moveHeader(with: scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        scheduleViewportReport()
    }

    private func scheduleViewportReport() {
        guard viewportReport == nil, viewIfLoaded?.window != nil else { return }
        let generation = generation
        viewportReport = Task { @MainActor [weak self] in
            // Publish outside UIKit/SwiftUI's layout update, coalescing a scroll frame.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.viewportReport = nil
            guard self.generation == generation, self.viewIfLoaded?.window != nil,
                  let first = self.layout.layoutAttributesForElements(in: self.collection.bounds)?
                    .filter({ $0.representedElementCategory == .cell && $0.frame.intersects(self.collection.bounds) })
                    .map(\.indexPath.item).min() else { return }
            self.model?.reportViewport(firstIndex: first, generation: generation)
        }
    }

    func scroll(to index: Int, focusesItem: Bool = false) {
        guard index >= 0, index < total else { return }
        let path = IndexPath(item: index, section: 0)
        collection.scrollToItem(at: path, at: .top, animated: !focusesItem)
        guard focusesItem else { return }
        collection.layoutIfNeeded()
        guard let cell = collection.cellForItem(at: path) as? NativeTVLibraryCell,
              cell.onRequestFocus?() == true else {
            PlozzLog.app.error("Library alphabet destination did not accept focus at index \(index)")
            return
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { total }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let reusable = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
        guard let cell = reusable as? NativeTVLibraryCell else {
            preconditionFailure("Library poster registration must produce NativeTVLibraryCell")
        }
        cell.configure(item: model?.item(at: indexPath.item), spoilerSettings: spoilerSettings, environment: environment)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath)
        if headerHost.view.superview !== header { header.addSubview(headerHost.view) }
        headerHost.view.frame = header.bounds
        headerHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return header
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? NativeTVLibraryCell, let model else { return }
        let id = ObjectIdentifier(cell)
        if bindings[id]?.index == indexPath.item, bindings[id]?.generation == generation { return }
        cell.onRequestFocus = { [weak self, weak cell] in
            guard let self, let cell, cell.canBecomeFocused, cell.window != nil,
                let path = self.collection.indexPath(for: cell),
                let system = UIFocusSystem.focusSystem(for: self.collection)
            else { return false }
            self.requestedFocusIndex = path
            if let owner = self.focusOwner {
                owner.requestFocus(to: self.collection, using: system)
            } else {
                system.requestFocusUpdate(to: self)
                system.updateFocusIfNeeded()
            }
            self.requestedFocusIndex = nil
            return cell.isFocused
        }
        let token = UUID()
        let generation = generation
        bindings[id] = CellBinding(index: indexPath.item, generation: generation, token: token)
        observe(cell, index: indexPath.item, token: token)
        bindings[id]?.load = Task { [weak self, weak cell] in
            guard let self, let cell, self.bindings[id]?.token == token else { return }
            await model.itemAppeared(at: indexPath.item, generation: generation)
            guard !Task.isCancelled, self.bindings[id]?.token == token, cell.window != nil else { return }
            self.onLoaded?(indexPath.item)
        }
    }

    private func observe(_ cell: NativeTVLibraryCell, index: Int, token: UUID) {
        guard let slot = model?.slot(at: index), bindings[ObjectIdentifier(cell)]?.token == token else { return }
        withObservationTracking {
            cell.configure(item: slot.item, spoilerSettings: spoilerSettings, environment: environment)
        } onChange: { [weak self, weak cell] in
            Task { @MainActor in
                guard let self, let cell else { return }
                self.observe(cell, index: index, token: token)
            }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        let id = ObjectIdentifier(cell)
        guard let binding = bindings[id], binding.index == indexPath.item else { return }
        bindings.removeValue(forKey: id)
        binding.load?.cancel()
        model?.itemDisappeared(at: binding.index, generation: binding.generation)
        (cell as? NativeTVLibraryCell)?.cancelArtwork()
    }

    func stopObserving() {
        viewportReport?.cancel()
        viewportReport = nil
        for binding in bindings.values {
            binding.load?.cancel()
            model?.itemDisappeared(at: binding.index, generation: binding.generation)
        }

        bindings.removeAll()
        model?.clearReportedViewport()
        if isViewLoaded {
            for cell in collection.visibleCells { (cell as? NativeTVLibraryCell)?.cancelArtwork() }
        }
        indicatorHider.teardown()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObserving()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        indicatorHider.hidden = hidesScrollIndicator
        for cell in collection.visibleCells {
            guard let indexPath = collection.indexPath(for: cell) else { continue }
            collectionView(collection, willDisplay: cell, forItemAt: indexPath)
        }
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let requestedFocusIndex { return requestedFocusIndex }
        let visible = collectionView.indexPathsForVisibleItems.filter {
            collectionView.cellForItem(at: $0)?.canBecomeFocused == true
                && collectionView.layoutAttributesForItem(at: $0)?.frame.intersects(collectionView.bounds) == true
        }
        if let lastFocusedIndex, visible.contains(lastFocusedIndex) { return lastFocusedIndex }
        // Loaded and loading slots share the same native focus identity.
        return visible.sorted().first ?? lastFocusedIndex
    }

    func collectionView(
        _ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        if let path = context.nextFocusedIndexPath { lastFocusedIndex = path }
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        environment.isEnabled
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        environment.isEnabled && model?.item(at: indexPath.item) != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = model?.item(at: indexPath.item), environment.isEnabled else { return }
        (collectionView.cellForItem(at: indexPath) as? NativeTVLibraryCell)?.prepareForSelection()
        onSelect?(item, indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard environment.isEnabled,
            let indexPath = indexPaths.first, let item = model?.item(at: indexPath.item),
            let handler = environment.mediaItemActionHandler
        else { return nil }
        let context = environment.mediaItemActionContext
        let navigator = environment.mediaItemNavigator
        let actions = handler.actions(for: item, context: context).filter { !$0.isNavigation || navigator != nil }
        guard !actions.isEmpty else { return nil }
        let locale = environment.locale
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let makeAction: (MediaItemAction) -> UIAction = { action in
                var title = action.title
                title.locale = locale
                let menuAction = UIAction(
                    title: String(localized: title), image: UIImage(systemName: action.systemImage), // l10n:content — UIKit menu boundary; resolved with the current menu locale
                    attributes: action.isDestructive ? .destructive : []
                ) { [weak self] _ in
                    if action.isNavigation {
                        self?.pendingNavigation = item.navigationTarget(for: action)
                    } else {
                        handler.perform(action, on: item, context: context)
                    }
                }
                if var value = action.accessibilityState {
                    value.locale = locale
                    menuAction.accessibilityValue = String(localized: value) // l10n:content — UIKit accessibility boundary; resolved with the current menu locale
                }
                return menuAction
            }
            let main = actions.filter { !$0.isSetApartInMenu }.map(makeAction)
            let separate = actions.filter(\.isSetApartInMenu).map(makeAction)
            return UIMenu(children: main + (separate.isEmpty ? [] : [UIMenu(options: .displayInline, children: separate)]))
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        guard let target = pendingNavigation else { return }
        pendingNavigation = nil
        let navigator = environment.mediaItemNavigator
        if let animator {
            animator.addCompletion { navigator?(target) }
        } else {
            navigator?(target)
        }
    }
}
#endif
