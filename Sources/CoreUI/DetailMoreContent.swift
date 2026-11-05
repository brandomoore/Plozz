import CoreModels
import Foundation

public enum DetailPreviewLimits {
    public static let cast = 12
    static let valueLines = 3
    static let facts = 9
    static let serviceLogos = 6
}

#if canImport(SwiftUI)
import SwiftUI

extension PlozzSheetStyle {
    static var detailReader: Self {
        #if os(tvOS)
        .floatingCard
        #else
        .standard
        #endif
    }
}

#if os(tvOS)
private struct DetailReaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The existing About reader surface, shared by every detail expansion.
struct DetailReaderCard<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ZStack {
            PlozzDialogBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(48)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: DetailReaderHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 900, height: min(max(contentHeight, 220), 760))
            .onPreferenceChange(DetailReaderHeightKey.self) { contentHeight = $0 }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .plozzSurface(.overlay, cornerRadius: 32)
            .accessibilityIdentifier("detail-reader-card")
        }
    }
}
#endif

public struct DetailMoreLabel: View {
    public init() {}

    public var body: some View {
        Text("MORE")
            .font(labelFont)
            .plozzForeground(.secondary)
    }

    private var labelFont: Font {
        #if os(tvOS)
        .system(size: 20, weight: .semibold)
        #else
        .footnote.weight(.semibold)
        #endif
    }
}

struct DetailInlineMoreLabel<Content: View>: View {
    let isTruncated: Bool
    let fadeWidth: CGFloat
    let textFont: Font
    @ViewBuilder let content: Content
    @State private var lineHeight: CGFloat = 0
    @State private var moreWidth: CGFloat = 0

    private var maskWidth: CGFloat { max(fadeWidth, moreWidth + 48) }
    private var fadeEnd: CGFloat { (maskWidth - moreWidth - 8) / maskWidth }

    var body: some View {
        content.overlay(alignment: .bottomTrailing) {
            if isTruncated, lineHeight > 0 {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: fadeEnd),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: maskWidth, height: lineHeight)
                .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .overlay(alignment: Alignment(horizontal: .trailing, vertical: .lastTextBaseline)) {
            if isTruncated, lineHeight > 0 {
                DetailMoreLabel()
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { moreWidth = $0 }
            }
        }
        .background(alignment: .topLeading) {
            Text(verbatim: "Ag")
                .font(textFont)
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
        }
    }
}

public struct DetailMoreSheet<Content: View>: View {
    private let title: Text
    private let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    public init(title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        #if os(tvOS)
        DetailReaderCard {
            title
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail-more-title")
            content
                .font(.system(size: 29))
        }
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .background { SettingsPageBackground() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }
}

public struct DetailCastList: View {
    private let people: [MediaPerson]
    private let onSelect: ((MediaPerson) -> Void)?

    public init(people: [MediaPerson], onSelect: ((MediaPerson) -> Void)? = nil) {
        self.people = people
        self.onSelect = onSelect
    }

    public var body: some View {
        DetailMoreSheet(title: Text("Cast")) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(people) { person in
                    if let onSelect {
                        Button { onSelect(person) } label: {
                            personLabel(person)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        personLabel(person)
                            #if os(tvOS)
                            .focusable()
                            #endif
                    }
                }
            }
            .accessibilityIdentifier("detail-full-cast")
        }
    }

    private func personLabel(_ person: MediaPerson) -> some View {
        HStack(spacing: 16) {
            FallbackAsyncImage(
                urls: person.imageURL.map { [$0] } ?? [],
                variant: .personHeadshot
            ) {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(width: portraitSize, height: portraitSize)
            .clipShape(Circle())
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name)
                    #if os(tvOS)
                    .font(.system(size: 29, weight: .medium))
                    #else
                    .font(.body.weight(.medium))
                    #endif
                    .plozzForeground(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        #if os(tvOS)
                        .font(.system(size: 26))
                        #else
                        .font(.subheadline)
                        #endif
                        .plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var portraitSize: CGFloat {
        #if os(tvOS)
        88
        #else
        56
        #endif
    }
}
#endif
