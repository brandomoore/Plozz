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
    @State private var hasFocusedControl = false
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize
    @Environment(\.layoutDirection) private var layoutDirection
    #if os(tvOS)
    @Environment(\.plozzNativeControlFocusRequest) private var requestNativeFocus
    #endif

    enum Control: Hashable {
        case source
        case search
        case multiviews
        case manageChannels
        case category(String?)
    }

    private var isRestoringFocus: Bool {
        restoresCategoryFocus && categoryFocusRequest > completedCategoryFocusRequest
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
        #if os(tvOS)
        // The shared owner can focus the laid-out control while its pane is moving.
        if requestNativeFocus != nil { return restoresCategoryFocus ? categoryFocusRequest : nil }
        #endif
        return restoresCategoryFocus && !isRevealing ? categoryFocusRequest : nil
    }

    @ViewBuilder private func nativeFocusRequest(for control: Control) -> some View {
        #if os(tvOS)
        NativeControlFocusRequest(request: isRestoringFocus && control == entryTarget ? readyCategoryFocusRequest : nil)
            // A moving virtual item may not yet be capturable as the rail's return target.
            .navigationEntryFocus(control == entryTarget ? .content : nil)
        #endif
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
            .background { nativeFocusRequest(for: .source) }
            .disabled(isFocusDisabled(.source))

            HStack(spacing: PrototypeLayout.smallGap) {
                Button(action: search) {
                    Label(isSearching ? "Back to guide" : "Search", systemImage: isSearching ? "chevron.backward" : "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                        .padding(.horizontal, PrototypeLayout.gap)
                }
                .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
                .padding(PrototypeLayout.controlInset)
                .background { PrototypeControlSurface() }
                .focused($focused, equals: .search)
                .background { nativeFocusRequest(for: .search) }
                .disabled(isFocusDisabled(.search))
                .accessibilityValue(model.query)
                .accessibilityIdentifier("live-tv-search")
                #if DEBUG
                .modifier(PrototypeBrowseLayoutObservation(element: "sidebar-search"))
                #endif

                sidebarActions
            }
            #else
            sidebarActions
            #endif

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
                            .background { nativeFocusRequest(for: .category(category)) }
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
                    guard request != nil else { return }
                    let target = entryTarget
                    if case .category = target, !hasFocusedControl || target != lastFocusedControl {
                        proxy.scrollTo(target)
                    }
                    #if os(tvOS)
                    if requestNativeFocus == nil { focused = target }
                    #else
                    focused = target
                    #endif
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
        .onMoveCommand { direction in
            guard focused != nil else { return }
            if direction == (layoutDirection == .rightToLeft ? .left : .right) {
                if focused == .search, multiviews != nil || manageChannels != nil { return }
                if focused == .multiviews, manageChannels != nil { return }
                enterGuide()
            }
        }
        #endif
        .onChange(of: focused) { _, target in
            guard let target else { return }
            hasFocusedControl = true
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

    @ViewBuilder private var sidebarActions: some View {
        if let multiviews {
            Button(action: multiviews) {
                Label("Multiviews", systemImage: "rectangle.split.2x2")
                    #if os(tvOS)
                    .labelStyle(.iconOnly)
                    .frame(width: PrototypeLayout.controlHeight, height: PrototypeLayout.controlHeight)
                    #else
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
            }
            #if os(tvOS)
            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
            .padding(PrototypeLayout.controlInset)
            .background { PrototypeControlSurface() }
            .help("Multiviews")
            #else
            .buttonStyle(.bordered)
            #endif
            .focused($focused, equals: .multiviews)
            .background { nativeFocusRequest(for: .multiviews) }
            .disabled(isFocusDisabled(.multiviews))
            .accessibilityIdentifier("live-tv-multiview-favorites")
        }
        if let manageChannels {
            Button(action: manageChannels) {
                Label("Manage channels", systemImage: "slider.horizontal.3")
                    #if os(tvOS)
                    .labelStyle(.iconOnly)
                    .frame(width: PrototypeLayout.controlHeight, height: PrototypeLayout.controlHeight)
                    #else
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
            }
            #if os(tvOS)
            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
            .padding(PrototypeLayout.controlInset)
            .background { PrototypeControlSurface() }
            .help("Manage channels")
            #else
            .buttonStyle(.bordered)
            #endif
            .focused($focused, equals: .manageChannels)
            .background { nativeFocusRequest(for: .manageChannels) }
            .disabled(isFocusDisabled(.manageChannels))
            .accessibilityIdentifier("live-tv-manage-channels")
        }
    }
}
