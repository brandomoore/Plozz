import CoreModels
import SwiftUI

public struct MediaRowRefreshStatus {
    public let isRefreshing: Bool
    public let failure: AppError?
    public let report: PlaybackDiagnosticReport?
    public let onRetry: () -> Void

    public init(
        isRefreshing: Bool, failure: AppError?, report: PlaybackDiagnosticReport?,
        onRetry: @escaping () -> Void
    ) {
        self.isRefreshing = isRefreshing
        self.failure = failure
        self.report = report
        self.onRetry = onRetry
    }
}

private struct MediaRowRefreshStatusKey: EnvironmentKey {
    static let defaultValue: MediaRowRefreshStatus? = nil
}

public extension EnvironmentValues {
    var mediaRowRefreshStatus: MediaRowRefreshStatus? {
        get { self[MediaRowRefreshStatusKey.self] }
        set { self[MediaRowRefreshStatusKey.self] = newValue }
    }
}

struct MediaRowRefreshIndicator: View {
    static let size: CGFloat = 44
    @Environment(\.mediaRowRefreshStatus) private var status
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDetails = false

    var body: some View {
        if let status {
            ZStack {
                if status.isRefreshing {
                    Group {
                        if reduceMotion {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(palette.primaryText)
                        } else {
                            ProgressView()
                        }
                    }
                        .scaleEffect(0.85, anchor: .leading)
                        .accessibilityLabel("Refreshing")
                } else if status.failure != nil {
                    Button("Details", systemImage: "exclamationmark.circle") { showsDetails = true }
                        .labelStyle(.iconOnly)
                        .plozzPageActionButton(role: .secondary)
                        .help("Unable to refresh")
                        .accessibilityLabel("Refresh details")
                        .accessibilityHint("Unable to refresh")
                }
            }
            .font(.callout)
            .frame(width: Self.size, height: Self.size, alignment: status.isRefreshing ? .leading : .center)
            .tint(palette.primaryText)
            .accessibilityIdentifier("media-row-refresh-status")
            .plozzSheet(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: 16) {
                    if let failure = status.failure { Text(failure.userMessage) }
                    ContentFailureActions(report: status.report) {
                        showsDetails = false
                        status.onRetry()
                    }
                }
                .padding()
                .tint(palette.primaryText)
            }
        }
    }
}

public struct MediaRowScroll<Content: View>: View {
    private let metrics: PlozzMetrics
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat
    private let content: Content

    public init(
        metrics: PlozzMetrics, leadingInset: CGFloat, trailingInset: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.metrics = metrics
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.content = content()
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: metrics.cardSpacing) {
                content
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            // Callers cancel this clearance with the shared rail offsets in layout,
            // while focused artwork and shadows retain room to draw.
            .padding(.vertical, metrics.railShadowClearance)
        }
        .scrollClipDisabled()
    }
}

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
                .environment(\.mediaRowRefreshStatus, nil)
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
