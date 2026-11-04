import CoreModels
import Foundation

public enum DetailPreviewLimits {
    public static let cast = 12
    static let listValues = 3
    static let valueLines = 3
    static let facts = 9
    static let serviceLogos = 6
}

#if canImport(SwiftUI)
import SwiftUI

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

    public init(title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        NavigationStack {
            content
                #if !os(tvOS)
                .scrollContentBackground(.hidden)
                #endif
                .background { SettingsPageBackground() }
                .navigationTitle(title)
                #if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
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
            List(people) { person in
                if let onSelect {
                    Button { onSelect(person) } label: {
                        personLabel(person)
                    }
                } else {
                    personLabel(person)
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
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
