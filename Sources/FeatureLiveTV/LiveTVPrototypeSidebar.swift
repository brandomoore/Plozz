import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypeBrowseSidebar: View {
    @Bindable var model: LiveTVPrototypeModel
    @Binding var active: Bool
    let focusRequest: Int
    var isSearching = false
    var categoryFocusRequest = 0
    var restoresCategoryFocus = false
    let search: () -> Void
    let enterGuide: () -> Void
    var selectCategory: ((String?) -> Void)?
    var multiviews: (() -> Void)?
    var manageChannels: (() -> Void)?
    @FocusState private var focused: Control?
    @State private var categoryFade = PrototypeScrollFade()
    @State private var completedCategoryFocusRequest = 0
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize
    @Environment(\.layoutDirection) private var layoutDirection

    private enum Control: Hashable {
        case search
        case multiviews
        case manageChannels
        case category(String?)
    }

    private var isEnteringCategory: Bool {
        restoresCategoryFocus && categoryFocusRequest > completedCategoryFocusRequest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.gap) {
            #if os(tvOS)
            Button(action: search) {
                Label(isSearching ? "Back to guide" : "Search", systemImage: isSearching ? "chevron.backward" : "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .padding(.horizontal, PrototypeLayout.gap)
            }
            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
            .padding(PrototypeLayout.controlInset)
            .background { PrototypeControlSurface() }
            .focused($focused, equals: .search)
            .disabled(isEnteringCategory)
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
                    .disabled(isEnteringCategory)
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
                    .disabled(isEnteringCategory)
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
                            .disabled(isEnteringCategory && category != model.category)
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
                .onChange(of: categoryFocusRequest) { _, request in
                    guard request > 0 else { return }
                    proxy.scrollTo(Control.category(model.category), anchor: .center)
                    focused = .category(model.category)
                }
                .onAppear {
                    if restoresCategoryFocus {
                        proxy.scrollTo(Control.category(model.category), anchor: .center)
                        focused = .category(model.category)
                    }
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
            $focused, restoresCategoryFocus ? .category(model.category) : .search,
            priority: .automatic
        )
        .background {
            NativeFocusRegionObserver(
                isEnabled: restoresCategoryFocus,
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
            if target != nil { active = true }
            if target == .category(model.category) {
                completedCategoryFocusRequest = categoryFocusRequest
            }
        }
        .onChange(of: focusRequest, initial: true) { _, request in
            guard request > 0, active, !restoresCategoryFocus else { return }
            completedCategoryFocusRequest = categoryFocusRequest
            focused = .search
        }
    }
}
