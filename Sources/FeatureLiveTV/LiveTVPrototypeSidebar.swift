import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

struct PrototypeBrowseSidebar: View {
    @Bindable var model: LiveTVPrototypeModel
    let configuration: LiveTVSourcesConfiguration
    @Binding var active: Bool
    @Binding var lastFocusedControl: Control?
    let focusRequest: Int
    var isSearching = false
    var categoryFocusRequest = 0
    var restoresCategoryFocus = false
    var isRevealing = false
    let search: () -> Void
    let enterGuide: () -> Void
    let selectSource: (String?) -> Void
    let addSource: () -> Void
    var selectCategory: ((String?) -> Void)?
    var multiviews: (() -> Void)?
    var manageChannels: (() -> Void)?
    @FocusState private var focused: Control?
    @State private var categoryFade = PrototypeScrollFade()
    @State private var completedCategoryFocusRequest = 0
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize
    @Environment(\.layoutDirection) private var layoutDirection

    enum Control: Hashable {
        case source
        case search
        case multiviews
        case manageChannels
        case category(String?)
    }

    private var isRestoringFocus: Bool {
        restoresCategoryFocus && (isRevealing || categoryFocusRequest > completedCategoryFocusRequest)
    }

    private var entryTarget: Control {
        switch lastFocusedControl {
        case .source:
            return .source
        case .search:
            return .search
        case .multiviews where multiviews != nil:
            return .multiviews
        case .manageChannels where manageChannels != nil:
            return .manageChannels
        case .category(let category) where category == nil || model.browsingCategories.contains(where: { $0.name == category }):
            return .category(category)
        default:
            return .category(model.category)
        }
    }

    private func isFocusDisabled(_ control: Control) -> Bool {
        isRestoringFocus && control != entryTarget
    }

    private var readyCategoryFocusRequest: Int? {
        restoresCategoryFocus && !isRevealing ? categoryFocusRequest : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.gap) {
            #if os(tvOS)
            PrototypeBrowseSourceMenu(
                configuration: configuration, selectedSourceID: model.configuredSourceID,
                includesLibraryChannels: model.channels.contains { $0.source == .plozz },
                selectSource: selectSource, addSource: addSource
            )
            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
            .padding(PrototypeLayout.controlInset)
            .background { PrototypeControlSurface() }
            .focused($focused, equals: .source)
            .disabled(isFocusDisabled(.source))

            Button(action: search) {
                Label(isSearching ? "Back to guide" : "Search", systemImage: isSearching ? "chevron.backward" : "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .padding(.horizontal, PrototypeLayout.gap)
            }
            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
            .padding(PrototypeLayout.controlInset)
            .background { PrototypeControlSurface() }
            .focused($focused, equals: .search)
            .disabled(isFocusDisabled(.search))
            .accessibilityValue(model.query)
            .accessibilityIdentifier("live-tv-search")
            #if DEBUG
            .modifier(PrototypeBrowseLayoutObservation(element: "sidebar-search"))
            #endif
            #endif
            if let multiviews {
                Button(action: multiviews) {
                    Label("Multiviews", systemImage: "rectangle.split.2x2")
                        #if os(iOS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                }
                    #if os(tvOS)
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .buttonStyle(PrototypeButtonStyle(surface: .control))
                    #else
                    .buttonStyle(.bordered)
                    #endif
                    .focused($focused, equals: .multiviews)
                    .disabled(isFocusDisabled(.multiviews))
                    .accessibilityIdentifier("live-tv-multiview-favorites")
            }
            if let manageChannels {
                Button(action: manageChannels) {
                    Label("Manage channels", systemImage: "slider.horizontal.3")
                        #if os(iOS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                }
                    #if os(tvOS)
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .buttonStyle(PrototypeButtonStyle(surface: .control))
                    #else
                    .buttonStyle(.bordered)
                    #endif
                    .focused($focused, equals: .manageChannels)
                    .disabled(isFocusDisabled(.manageChannels))
                    .accessibilityIdentifier("live-tv-manage-channels")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: PrototypeLayout.smallGap) {
                        ForEach([nil] + model.browsingCategories.map { Optional($0.name) }, id: \.self) { category in
                            Button {
                                if let selectCategory { selectCategory(category) }
                                else { model.category = category }
                            } label: {
                                HStack(spacing: PrototypeLayout.smallGap) {
                                    if let category { Text(category) } else { Text("All categories") }
                                    Spacer(minLength: 0)
                                    Text(model.categoryChannelCount(category), format: .number)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .opacity(model.category == category ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                                .lineLimit(2)
                                #if os(tvOS)
                                .frame(
                                    maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading
                                )
                                .padding(.horizontal, PrototypeLayout.gap)
                                #else
                                .frame(maxWidth: .infinity, alignment: .leading)
                                #endif
                                .contentShape(Rectangle())
                            }
                            #if os(tvOS)
                            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
                            #else
                            .buttonStyle(.bordered)
                            #endif
                            .focused($focused, equals: .category(category))
                            .disabled(isFocusDisabled(.category(category)))
                            .id(Control.category(category))
                            .accessibilityAddTraits(model.category == category ? .isSelected : [])
                            .accessibilityLabel(category.map { Text(verbatim: $0) } ?? Text("All categories"))
                            .accessibilityValue(Text("\(model.categoryChannelCount(category)) channels"))
                            .accessibilityIdentifier("live-tv-sidebar-category-\(category ?? "all")")
                        }
                    }
                    .padding(.vertical, PrototypeLayout.smallGap)
                }
                .scrollIndicators(.hidden)
                .verticalEdgeFadeMask(
                    fadeHeight: PrototypeLayout.verticalFade,
                    topStrength: categoryFade.leading,
                    bottomStrength: categoryFade.trailing
                )
                .onScrollGeometryChange(for: PrototypeScrollFade.self) { geometry in
                    PrototypeScrollFade(
                        before: geometry.contentOffset.y + geometry.contentInsets.top,
                        after: geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                    )
                } action: { _, fade in
                    categoryFade = fade
                }
                .accessibilityIdentifier("live-tv-category-list")
                .onChange(of: readyCategoryFocusRequest, initial: true) { _, request in
                    // The pane is still clipped during its reveal transition.
                    guard request != nil else { return }
                    let target = entryTarget
                    if case .category = target { proxy.scrollTo(target) }
                    focused = target
                }
            }
        }
        #if os(tvOS)
        .font(.system(size: fontSize, weight: .regular))
        #endif
        .lineLimit(1)
        .focusEffectDisabled()
        #if os(tvOS)
        .focusSection()
        .defaultFocus(
            $focused, restoresCategoryFocus ? entryTarget : .search,
            priority: .automatic
        )
        .background {
            NativeFocusRegionObserver(
                isEnabled: restoresCategoryFocus, ignoresPresentedFocus: true,
                onFocusExited: { completedCategoryFocusRequest = 0 },
                onFocusEntered: {}
            )
        }
        .onMoveCommand { direction in
            guard focused != nil else { return }
            if direction == (layoutDirection == .rightToLeft ? .left : .right) {
                enterGuide()
            }
        }
        #endif
        .onChange(of: focused) { _, target in
            guard let target else { return }
            if target == entryTarget {
                completedCategoryFocusRequest = categoryFocusRequest
            }
            lastFocusedControl = target
            active = true
        }
        .onChange(of: focusRequest, initial: true) { _, request in
            guard request > 0, active, !restoresCategoryFocus else { return }
            completedCategoryFocusRequest = categoryFocusRequest
            focused = .search
        }
    }
}
