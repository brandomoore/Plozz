import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypeCategoryDirectory: View {
    let categories: [LiveTVBrowseCategory]
    let totalCount: Int
    let returnCategory: String?
    let select: (String?) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PrototypeLayout.gap) {
                    Text("Categories").font(.headline).foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 160),
                            spacing: PrototypeLayout.gap
                        )],
                        spacing: PrototypeLayout.gap
                    ) {
                        PrototypeCategoryTile(name: nil, count: totalCount) { select(nil) }
                            .accessibilityIdentifier("live-tv-category-all")
                        ForEach(categories) { category in
                            PrototypeCategoryTile(name: category.name, count: category.channelCount) {
                                select(category.name)
                            }
                            .id(category.name)
                            .accessibilityIdentifier("live-tv-browse-category-\(category.name)")
                        }
                    }
                }
                .padding(.vertical, PrototypeLayout.smallGap)
            }
            .accessibilityIdentifier("live-tv-category-grid")
            .onAppear {
                if let returnCategory { proxy.scrollTo(returnCategory, anchor: .center) }
            }
        }
    }
}

struct PrototypeCategoryTile: View {
    let name: String?
    let count: Int
    let action: () -> Void
    #if os(tvOS)
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 96
    private let contentAlignment: VerticalAlignment = .top
    #else
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 40
    private let contentAlignment: VerticalAlignment = .center
    #endif

    static var searchWidth: CGFloat {
        #if os(tvOS)
        320
        #else
        210
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: contentAlignment, spacing: 8) {
                Group {
                    if let name { Text(verbatim: name) }
                    else { Text("All channels") }
                }
                .font(.headline)
                #if os(tvOS)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                #else
                .lineLimit(3)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityHidden(true)
            }
            #if os(tvOS)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            #else
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            #endif
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        #if os(tvOS)
        .tint(nil)
        #endif
        .accessibilityValue(Text("\(count) channels"))
    }
}
