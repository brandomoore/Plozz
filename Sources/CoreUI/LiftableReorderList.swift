#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The shared "reorder and hide" list control: one ordered list split by a
/// **Disabled** divider, where moving a row across the divider is what turns it
/// off. Backed by the app-wide ``OrderedVisibilityList`` model, so every surface
/// that lets the viewer reorder-and-hide a collection (metadata providers, the
/// navigation libraries, …) is the same control with the same muscle memory.
///
/// **tvOS interaction** — the whole row is the focus target (no per-row buttons):
/// click to *lift* it, then d-pad Up/Down moves it while keeping native focus
/// (crossing the divider enables/disables), and click again to drop it. Neighbours
/// dim while a row is lifted, which is the tvOS Home-screen rearrange idiom.
/// Hold a direction to repeat; press and hold Select for direct row actions.
///
/// **iOS/iPadOS interaction** — the native always-editing `List` drag handle over
/// the same flattened model, with the divider immovable.
public struct LiftableReorderList<Element: Hashable>: View {
    /// What one row shows. Kept as a small value (rather than a `@ViewBuilder`) so
    /// the row chrome — focus card, rank, handle, dim/lift treatment — is owned
    /// here and can never drift between the surfaces that use this control.
    public struct Row {
        public var title: Text
        /// Optional leading SF Symbol, e.g. a library's content-kind glyph.
        public var symbolName: String?
        /// Optional provider brand mark. Takes precedence over `symbolName`.
        public var providerKind: ProviderKind?
        /// Transport badge for a media-share provider mark.
        public var mediaShareTransport: MediaShareTransportKind?
        public var providerMarkInSubtitle: Bool
        /// Optional trailing detail line, e.g. the server a library came from.
        public var detail: Text?
        public var subtitle: Text?

        public init(
            title: Text,
            symbolName: String? = nil,
            providerKind: ProviderKind? = nil,
            mediaShareTransport: MediaShareTransportKind? = nil,
            detail: Text? = nil,
            subtitle: Text? = nil,
            providerMarkInSubtitle: Bool = false
        ) {
            self.title = title
            self.symbolName = symbolName
            self.providerKind = providerKind
            self.mediaShareTransport = mediaShareTransport
            self.providerMarkInSubtitle = providerMarkInSubtitle
            self.detail = detail
            self.subtitle = subtitle
        }
    }

    private let sections: OrderedVisibilityList.Sections<Element>
    private let row: (Element) -> Row
    private let disabledSectionTitle: LocalizedStringResource
    private let disabledPlaceholder: LocalizedStringResource
    private let requiredEnabled: Set<Element>
    private let allowsHiding: Bool
    private let removeTitle: LocalizedStringResource
    /// Mirrors "a row is currently lifted" outward so the host page can disable its
    /// other controls while a reorder is in progress.
    @Binding private var isLifting: Bool
    private let onChange: (OrderedVisibilityList.Sections<Element>) -> Void
    private let onRemove: ((Element) -> Void)?
    private let onMove: ((Element) -> Void)?
    private let initialElement: Element?
    @AccessibilityFocusState private var accessibilityFocusedElement: Element?

    /// The element currently "lifted" for reordering (nil = none lifted).
    @State private var liftedElement: Element?
    @State private var liftedSections: OrderedVisibilityList.Sections<Element>?
    @State private var pinnedFocusTarget: Element?
    @State private var focusRestoreTarget: Element?
    @State private var focusRestoreRevision = 0
    @FocusState private var focusedElement: Element?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        sections: OrderedVisibilityList.Sections<Element>,
        disabledSectionTitle: LocalizedStringResource,
        disabledPlaceholder: LocalizedStringResource,
        isLifting: Binding<Bool>,
        requiredEnabled: Set<Element> = [],
        allowsHiding: Bool = true,
        removeTitle: LocalizedStringResource = "Remove section",
        onRemove: ((Element) -> Void)? = nil,
        onMove: ((Element) -> Void)? = nil,
        initialElement: Element? = nil,
        row: @escaping (Element) -> Row,
        onChange: @escaping (OrderedVisibilityList.Sections<Element>) -> Void
    ) {
        self.sections = sections
        self.disabledSectionTitle = disabledSectionTitle
        self.disabledPlaceholder = disabledPlaceholder
        self._isLifting = isLifting
        self.requiredEnabled = allowsHiding ? requiredEnabled : requiredEnabled.union(sections.enabled)
        self.allowsHiding = allowsHiding
        self.removeTitle = removeTitle
        self.row = row
        self.onChange = onChange
        self.onRemove = onRemove
        self.onMove = onMove
        let target = initialElement.flatMap { sections.combined.contains($0) ? $0 : nil }
        self.initialElement = target
        #if os(tvOS)
        _liftedElement = State(initialValue: target)
        _liftedSections = State(initialValue: target == nil ? nil : sections)
        _pinnedFocusTarget = State(initialValue: target)
        _focusRestoreTarget = State(initialValue: target)
        #endif
    }

    #if os(tvOS)
    public var body: some View {
        SettingsAdjustmentFocusScope(
            content: rows,
            screen: liftedElement,
            adjustableRow: { liftedElement == nil ? nil : 0 },
            axis: .vertical
        ) { direction, _ in
            stepLiftedRow(up: direction == .up)
        }
        .onChange(of: liftedElement != nil || pinnedFocusTarget != nil, initial: true) { _, active in
            isLifting = active
        }
        .task(id: focusRestoreRevision) {
            guard let target = focusRestoreTarget else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedElement = target
        }
        .onChange(of: sections) { _, sections in
            let elements = sections.combined
            if liftedElement != nil { liftedSections = sections }
            if let liftedElement, !elements.contains(liftedElement) { self.liftedElement = nil }
            if let target = pinnedFocusTarget, !elements.contains(target) {
                pinnedFocusTarget = elements.first
                if let replacement = elements.first { restoreFocusAfterLayout(to: replacement) }
            }
        }
        .onDisappear {
            liftedElement = nil
            liftedSections = nil
            pinnedFocusTarget = nil
            focusRestoreTarget = nil
            isLifting = false
        }
    }

    private var rows: some View {
        let items = allowsHiding
            ? OrderedVisibilityList.listItems(for: sections)
            : sections.enabled.map(OrderedVisibilityList.ListItem.element)
        return VStack(spacing: SettingsRowMetrics.formRowSpacing) {
            ForEach(items, id: \.self) { item in
                switch item {
                case let .element(element):
                    rowView(
                        element, isEnabled: sections.enabled.contains(element),
                        rank: sections.enabled.firstIndex(of: element).map { $0 + 1 }
                    )
                case .divider:
                    ReorderDisabledDivider(title: disabledSectionTitle, isDropTarget: liftedElement != nil)
                case .disabledPlaceholder:
                    ReorderDisabledPlaceholder(
                        message: disabledPlaceholder,
                        isReordering: liftedElement != nil
                    )
                    .disabled(pinnedFocusTarget != nil)
                }
            }
        }
    }

    private func rowView(_ element: Element, isEnabled: Bool, rank: Int?) -> some View {
        let lifting = liftedElement != nil
        let content = row(element)
        return LiftableRow(
            title: content.title,
            subtitle: content.subtitle,
            detail: content.detail,
            symbolName: content.symbolName,
            providerKind: content.providerKind,
            mediaShareTransport: content.mediaShareTransport,
            providerMarkInSubtitle: content.providerMarkInSubtitle,
            isEnabled: isEnabled,
            isLifted: liftedElement == element,
            isDimmed: lifting && liftedElement != element,
            rank: rank,
            maximumRank: sections.enabled.count,
            onPrimary: { toggleLift(element) },
            onFocus: {
                if pinnedFocusTarget == element { pinnedFocusTarget = nil }
            }
        )
        .focused($focusedElement, equals: element)
        .disabled(pinnedFocusTarget != nil && pinnedFocusTarget != element)
        .contextMenu { rowMenu(element) }
    }

    /// Click handler: lift the focused row, or drop it if it's already lifted.
    private func toggleLift(_ element: Element) {
        guard allowsHiding || sections.enabled.count > 1 else { return }
        liftedSections = liftedElement == element ? nil : sections
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.16)) {
            liftedElement = (liftedElement == element) ? nil : element
        }
    }

    private func stepLiftedRow(up: Bool) {
        guard let lifted = liftedElement else { return }
        let current = liftedSections ?? sections
        let next = OrderedVisibilityList.stepped(
            lifted, up: up, in: current, keepingEnabled: requiredEnabled
        )
        guard next != current else { return }
        liftedSections = next
        onMove?(lifted)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) {
            onChange(next)
        }
    }

    /// Wait one run-loop turn for the reordered `ForEach` frames to settle before
    /// asking the focus engine to follow the lifted row to its new slot.
    private func restoreFocusAfterLayout(to element: Element) {
        focusRestoreTarget = element
        focusRestoreRevision &+= 1
    }
    #else
    @ScaledMetric(relativeTo: .body) private var mobileRowHeight: CGFloat = 54

    private func height(for item: OrderedVisibilityList.ListItem<Element>) -> CGFloat {
        if case let .element(element) = item, row(element).subtitle != nil {
            return mobileRowHeight * 1.5
        }
        return mobileRowHeight
    }

    public var body: some View {
        let items = allowsHiding
            ? OrderedVisibilityList.listItems(for: sections)
            : sections.enabled.map(OrderedVisibilityList.ListItem.element)
        return List {
            ForEach(items, id: \.self) { item in
                listRow(item)
                    .frame(height: max(0, height(for: item) - 16))
                    .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .moveDisabled(item == .divider || (!allowsHiding && sections.enabled.count < 2))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            .onMove { offsets, destination in
                let next = OrderedVisibilityList.moving(
                    fromOffsets: offsets,
                    toOffset: destination,
                    in: sections,
                    keepingEnabled: requiredEnabled
                )
                guard next != sections else { return }
                for offset in offsets {
                    if case let .element(element) = items[offset] { onMove?(element) }
                }
                onChange(next)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollDisabled(true)
        .environment(\.editMode, .constant(.active))
        .environment(\.defaultMinListRowHeight, 0)
        .frame(height: items.reduce(0) { $0 + height(for: $1) })
        .task {
            guard let initialElement else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            accessibilityFocusedElement = initialElement
        }
    }

    @ViewBuilder
    private func listRow(_ item: OrderedVisibilityList.ListItem<Element>) -> some View {
        switch item {
        case let .element(element):
            let content = row(element)
            let isEnabled = sections.enabled.contains(element)
            HStack {
                ReorderRank(
                    rank: sections.enabled.firstIndex(of: element).map { $0 + 1 },
                    maximumRank: sections.enabled.count,
                    minimumWidth: 0
                )
                .font(.caption)
                .plozzForeground(.secondary)
                if let providerKind = content.providerKind, !content.providerMarkInSubtitle {
                    ProviderBrandMark(
                        provider: providerKind,
                        size: 24,
                        showsBackground: false,
                        mediaShareTransport: content.mediaShareTransport
                    )
                    .frame(width: 30)
                    .accessibilityHidden(true)
                } else if let symbolName = content.symbolName {
                    Image(systemName: symbolName)
                        .font(.callout)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    content.title
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    if let subtitle = content.subtitle {
                        HStack(spacing: 6) {
                            if content.providerMarkInSubtitle, let providerKind = content.providerKind {
                                ReorderSubtitleProviderMark(
                                    provider: providerKind, transport: content.mediaShareTransport
                                )
                            }
                            subtitle.font(.caption).plozzForeground(.secondary)
                        }
                    }
                }
                .lineLimit(1)
                if let detail = content.detail {
                    Spacer(minLength: 8)
                    detail
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .id(element)
            .accessibilityFocused($accessibilityFocusedElement, equals: element)
            .contextMenu { rowMenu(element) }
        case .divider:
            Text(disabledSectionTitle)
                .font(.caption.weight(.semibold))
                .plozzForeground(.secondary)
                .textCase(.uppercase)
        case .disabledPlaceholder:
            Text(disabledPlaceholder)
                .font(.caption)
                .plozzForeground(.secondary)
        }
    }
    #endif

    @ViewBuilder
    private func rowMenu(_ element: Element) -> some View {
        if allowsHiding, sections.enabled.contains(element) {
            Button("Hide", systemImage: "eye.slash") { perform(.hide, on: element) }
                .disabled(requiredEnabled.contains(element))
        } else if allowsHiding {
            Button(
                LocalizedStringResource("Show", comment: "Action verb: unhide a navigation item. Not the noun meaning a TV series."),
                systemImage: "eye"
            ) { perform(.show, on: element) }
        }
        Button("Move Up", systemImage: "arrow.up") { perform(.moveUp, on: element) }
            .disabled(edit(.moveUp, for: element) == nil)
        Button("Move Down", systemImage: "arrow.down") { perform(.moveDown, on: element) }
            .disabled(edit(.moveDown, for: element) == nil)
        Button("Move to top", systemImage: "arrow.up.to.line") { perform(.moveToTop, on: element) }
            .disabled(edit(.moveToTop, for: element) == nil)
        Button("Move to bottom", systemImage: "arrow.down.to.line") { perform(.moveToBottom, on: element) }
            .disabled(edit(.moveToBottom, for: element) == nil)
        if let onRemove {
            Button(removeTitle, systemImage: "minus.circle", role: .destructive) {
                #if os(tvOS)
                liftedElement = nil
                let index = sections.enabled.firstIndex(of: element) ?? 0
                let remaining = sections.enabled.filter { $0 != element }
                pinnedFocusTarget = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { onRemove(element) }
                if let pinnedFocusTarget { restoreFocusAfterLayout(to: pinnedFocusTarget) }
                #else
                onRemove(element)
                #endif
            }
        }
    }

    private func edit(_ action: OrderedVisibilityList.Action, for element: Element) -> OrderedVisibilityList.Edit<Element>? {
        OrderedVisibilityList.applying(action, to: element, in: sections, keepingEnabled: requiredEnabled)
    }

    private func perform(_ action: OrderedVisibilityList.Action, on element: Element) {
        guard let edit = edit(action, for: element) else { return }
        if action == .moveUp || action == .moveDown || action == .moveToTop || action == .moveToBottom {
            onMove?(element)
        }
        #if os(tvOS)
        liftedElement = nil
        if action == .hide, edit.focusTarget != element {
            // Keep the dismissed menu's old row out of the focus order until
            // its replacement is focused, rather than chasing it at the bottom.
            pinnedFocusTarget = edit.focusTarget
        }
        var transaction = Transaction()
        transaction.disablesAnimations = action == .hide
        withTransaction(transaction) { onChange(edit.sections) }
        restoreFocusAfterLayout(to: edit.focusTarget)
        #else
        onChange(edit.sections)
        if action == .moveUp || action == .moveDown || action == .moveToTop || action == .moveToBottom {
            TouchFeedback.shared.emit(.selection)
        }
        #endif
    }
}

/// One focusable row in the ordered list. The **whole row** is the focus target.
/// An always-visible reorder handle sits on the trailing edge.
private struct LiftableRow: View {
    let title: Text
    let subtitle: Text?
    let detail: Text?
    let symbolName: String?
    let providerKind: ProviderKind?
    let mediaShareTransport: MediaShareTransportKind?
    let providerMarkInSubtitle: Bool
    let isEnabled: Bool
    let isLifted: Bool
    let isDimmed: Bool
    /// 1-based priority rank when enabled; `nil` when disabled.
    let rank: Int?
    /// Largest rank in the enabled section. Reserves one shared rank-column width
    /// so crossing 9 → 10 never pushes logos and labels sideways.
    let maximumRank: Int
    let onPrimary: () -> Void
    let onFocus: () -> Void

    var body: some View {
        Button(action: onPrimary) {
            HStack(spacing: SettingsRowMetrics.spacing(.primary)) {
                ReorderRank(rank: rank, maximumRank: maximumRank)
                    .font(SettingsRowMetrics.titleFont)
                if let providerKind, !providerMarkInSubtitle {
                    ProviderBrandMark(
                        provider: providerKind,
                        size: 24,
                        showsBackground: false,
                        mediaShareTransport: mediaShareTransport
                    )
                    .frame(width: 30)
                    .accessibilityHidden(true)
                } else if let symbolName {
                    Image(systemName: symbolName)
                        .font(SettingsRowMetrics.descriptionFont)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    title.font(SettingsRowMetrics.titleFont)
                    if let subtitle {
                        HStack(spacing: 6) {
                            if providerMarkInSubtitle, let providerKind {
                                ReorderSubtitleProviderMark(provider: providerKind, transport: mediaShareTransport)
                            }
                            subtitle.font(SettingsRowMetrics.descriptionFont).opacity(0.7)
                        }
                    }
                }
                .lineLimit(1)
                if let detail {
                    detail
                        .font(SettingsRowMetrics.descriptionFont)
                        .opacity(0.7)
                }

                Spacer(minLength: 12)
                Image(systemName: "line.3.horizontal")
                    .font(SettingsRowMetrics.descriptionFont)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            LiftableRowButtonStyle(
                isEnabled: isEnabled,
                isLifted: isLifted,
                suppressFocusAppearance: isDimmed,
                onFocus: onFocus
            )
        )
        .opacity(isDimmed ? 0.4 : 1)
        .scaleEffect(isLifted ? 1.04 : 1)
        .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: isLifted ? 18 : 0, y: isLifted ? 9 : 0)
        .zIndex(isLifted ? 1 : 0)
    }
}

private struct ReorderSubtitleProviderMark: View {
    let provider: ProviderKind
    let transport: MediaShareTransportKind?
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 20

    var body: some View {
        ProviderBrandMark(
            provider: provider, size: size, showsBackground: false, mediaShareTransport: transport
        )
        .accessibilityHidden(true)
    }
}

/// Fixed-width rank slot derived from the largest enabled rank.
///
/// Disabled rows still reserve the slot with no visible number, keeping every
/// provider mark and title on the same axis above and below the divider.
private struct ReorderRank: View {
    let rank: Int?
    let maximumRank: Int
    var minimumWidth: CGFloat = 26

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(max(1, maximumRank), format: .number)
                .hidden()
            if let rank {
                Text(rank, format: .number)
            }
        }
        .monospacedDigit()
        .frame(minWidth: minimumWidth, alignment: .trailing)
    }
}

/// Row chrome using ONLY the existing Settings design language — no new colors. A
/// lifted (grabbed) or focused row both render as the standard tvOS inverted card
/// (white fill / black text in dark mode); "grabbed" is distinguished by the row's
/// scale + shadow and its dimmed neighbors (the tvOS Home-screen rearrange idiom),
/// not a tint. Foreground is set here so it always matches the fill.
private struct LiftableRowButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isLifted: Bool
    /// Only the lifted row highlights while the list owns directional input.
    let suppressFocusAppearance: Bool
    let onFocus: () -> Void
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let inverted = isLifted || (isFocused && !suppressFocusAppearance)
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white

        let foreground: AnyShapeStyle = inverted
            ? AnyShapeStyle(invertedText)
            : (isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        let fill: AnyShapeStyle = inverted ? AnyShapeStyle(invertedFill) : AnyShapeStyle(Color.clear)

        return configuration.label
            .settingsFormRowLayout()
            .foregroundStyle(foreground)
            // ProviderBrandMark and other settings-row descendants use these
            // values to choose focus-safe contrast. `inverted` includes a lifted
            // row, which retains the same inverted card while its menu is open.
            .environment(\.settingsRowIsFocused, inverted)
            .environment(\.settingsRowFocusForeground, invertedText)
            .onChange(of: isFocused, initial: true) { _, focused in
                if focused { onFocus() }
            }
            .background(
                RoundedRectangle(cornerRadius: SettingsRowMetrics.formRowCornerRadius, style: .continuous).fill(fill)
            )
    }
}

/// The divider that separates enabled (above) from disabled (below).
private struct ReorderDisabledDivider: View {
    let title: LocalizedStringResource
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .plozzForeground(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.secondary.opacity(isDropTarget ? 0.6 : 0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

/// Shown in the disabled area when nothing is disabled, so the disable target stays
/// discoverable: a lifted row moved down here becomes disabled.
private struct ReorderDisabledPlaceholder: View {
    let message: LocalizedStringResource
    let isReordering: Bool

    var body: some View {
        Button(action: {}) {
            Text(message)
                .font(SettingsRowMetrics.descriptionFont)
                .settingsFormRowLayout()
        }
        .buttonStyle(
            ReorderPlaceholderButtonStyle(suppressFocusAppearance: isReordering)
        )
    }
}

private struct ReorderPlaceholderButtonStyle: ButtonStyle {
    let suppressFocusAppearance: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let inverted = isFocused && !suppressFocusAppearance
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white
        return configuration.label
            .foregroundStyle(inverted ? AnyShapeStyle(invertedText) : AnyShapeStyle(.secondary))
            .background(
                RoundedRectangle(cornerRadius: SettingsRowMetrics.formRowCornerRadius, style: .continuous)
                    .fill(inverted ? AnyShapeStyle(invertedFill) : AnyShapeStyle(Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsRowMetrics.formRowCornerRadius, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
                    .foregroundStyle(.secondary.opacity(inverted ? 0 : 0.5))
            )
    }
}
#endif
