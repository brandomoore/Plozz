#if os(iOS)
import SwiftUI

/// Touch navigation within a page, shared by library modes and series seasons.
public struct PlozzContentTabs<Option, ID: Hashable>: View {
    private let options: [Option]
    private let id: KeyPath<Option, ID>
    private let selection: ID?
    private let horizontalInset: CGFloat
    private let title: (Option) -> Text
    private let tabIdentifier: (Option) -> String
    private let onSelect: (Option) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewportWidth: CGFloat = 0

    public init(
        options: [Option],
        id: KeyPath<Option, ID>,
        selection: ID?,
        horizontalInset: CGFloat,
        title: @escaping (Option) -> Text,
        tabIdentifier: @escaping (Option) -> String,
        onSelect: @escaping (Option) -> Void
    ) {
        self.options = options
        self.id = id
        self.selection = selection
        self.horizontalInset = horizontalInset
        self.title = title
        self.tabIdentifier = tabIdentifier
        self.onSelect = onSelect
    }

    private var labelWidthLimit: CGFloat? {
        guard viewportWidth > 0 else { return nil }
        return max(44, viewportWidth - horizontalInset * 2 - 40)
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(options, id: id) { option in
                        let isSelected = selection == option[keyPath: id]
                        Button {
                            onSelect(option)
                        } label: {
                            title(option)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(maxWidth: labelWidthLimit)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: 24)
                        }
                        .buttonStyle(PlozzSeasonTabStyle(isSelected: isSelected))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier(tabIdentifier(option))
                        .id(option[keyPath: id])
                    }
                }
            }
            .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
            .contentMargins(.vertical, 4, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .onChange(of: selection, initial: true) { old, new in
                guard let new else { return }
                if old != new, old != nil, !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(new) }
                } else {
                    proxy.scrollTo(new)
                }
            }
            .onChange(of: options.map { $0[keyPath: id] }) { _, _ in revealSelection(using: proxy) }
            .onChange(of: viewportWidth) { _, _ in revealSelection(using: proxy) }
            .onChange(of: horizontalInset) { _, _ in revealSelection(using: proxy) }
            .onChange(of: dynamicTypeSize) { _, _ in revealSelection(using: proxy) }
        }
        .accessibilityElement(children: .contain)
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        if let selection { proxy.scrollTo(selection) }
    }
}
#endif
