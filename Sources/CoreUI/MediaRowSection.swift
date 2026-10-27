import CoreModels
import SwiftUI

/// Shared rail chrome; scrolling cards and compact recovery content own their bodies.
public struct MediaRowSection<Content: View>: View {
    private let title: Text?
    private let leadingInset: CGFloat
    private let spacing: CGFloat?
    private let insetsContent: Bool
    private let onSeeAll: (() -> Void)?
    private let onFocusEntered: (() -> Void)?
    private let content: Content
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzRowTitleTightening) private var titleTightening
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    @Environment(\.mediaRowHeaderTrailingInset) private var trailingInset

    public init(
        title: Text?, leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding,
        spacing: CGFloat? = nil, insetsContent: Bool = false,
        onSeeAll: (() -> Void)? = nil, onFocusEntered: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leadingInset = leadingInset
        self.spacing = spacing
        self.insetsContent = insetsContent
        self.onSeeAll = onSeeAll
        self.onFocusEntered = onFocusEntered
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: (spacing ?? metrics.sectionTitleSpacing) - titleTightening) {
            if let title {
                MediaRowHeader(
                    title: title, leadingInset: leadingInset,
                    onSeeAll: onSeeAll, onFocusEntered: onFocusEntered
                )
            }
            content
                .padding(.leading, insetsContent ? leadingInset + navigationInset : 0)
                .padding(.trailing, insetsContent ? leadingInset + trailingInset : 0)
        }
    }
}

public struct MediaRowStatusContent<Metadata: View, Actions: View>: View {
    private let message: LocalizedStringResource
    private let symbol: String
    private let metadata: Metadata
    private let actions: Actions

    public init(
        message: LocalizedStringResource, symbol: String,
        @ViewBuilder metadata: () -> Metadata, @ViewBuilder actions: () -> Actions
    ) {
        self.message = message
        self.symbol = symbol
        self.metadata = metadata()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) { status }
                VStack(alignment: .leading, spacing: 4) { status }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { actions }
                VStack(alignment: .leading, spacing: 12) { actions }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        Label(message, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        metadata
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
