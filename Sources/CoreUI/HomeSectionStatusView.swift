import SwiftUI
import CoreModels

public struct HomeSectionStatusView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzMetrics) private var metrics
    private let issue: HomeSectionIssue
    private let onRetry: () -> Void
    private let onSeeAll: (() -> Void)?
    private let onCustomizeHome: (() -> Void)?
    private let onDismissEmpty: (() -> Void)?
    private let showsTitle: Bool
    @State private var showsDetails = false

    public init(
        issue: HomeSectionIssue, showsTitle: Bool = true,
        onSeeAll: (() -> Void)? = nil, onCustomizeHome: (() -> Void)? = nil,
        onDismissEmpty: (() -> Void)? = nil,
        onRetry: @escaping () -> Void
    ) {
        self.issue = issue
        self.onSeeAll = onSeeAll
        self.onCustomizeHome = onCustomizeHome
        self.onDismissEmpty = onDismissEmpty
        self.showsTitle = showsTitle
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                (issue.choice.localizedTitle.map(Text.init) ?? Text(verbatim: issue.choice.title))
                    .font(.headline)
            }
            if issue.reason == .empty {
                VStack(spacing: 12) {
                    Text(issue.summary)
                        .font(.headline)
                    HomeSectionSourceLabel(issue: issue)
                        .font(.subheadline)
                        .plozzForeground(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { emptyActions }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(spacing: 12) { emptyActions }
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: emptyRowHeight)
                .accessibilityIdentifier("home-section-empty")
            } else {
                MediaRowStatusContent(message: issue.summary, symbol: symbol) {
                    HomeSectionSourceLabel(issue: issue)
                } actions: {
                    Button("Details", systemImage: "info.circle") { showsDetails = true }
                        .plozzActionButton(role: .secondary)
                        .accessibilityIdentifier("home-section-details")
                    Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                        .plozzActionButton()
                        .accessibilityIdentifier("home-section-retry")
                    if let onSeeAll { Button("See all", action: onSeeAll) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-section-status-\(issue.id.presentationID)")
        .alert(Text(issue.summary), isPresented: $showsDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            if case let .failed(error) = issue.reason {
                Text(issue.explanation) + Text(verbatim: "\n\n\(HandoffDiagnostics.errorCode(error))")
            } else {
                Text(issue.explanation)
            }
        }
    }

    private var emptyRowHeight: CGFloat {
        #if os(tvOS)
        metrics.posterHeight * 0.8
        #else
        metrics.usesDesktopSizing ? metrics.posterHeight * 0.8 : 180
        #endif
    }

    @ViewBuilder
    private var emptyActions: some View {
        if let onDismissEmpty {
            Button("Dismiss", action: onDismissEmpty)
                .plozzActionButton(role: .secondary)
                .tint(palette.primaryText)
                .accessibilityIdentifier("home-section-dismiss-empty")
        }
        if let onCustomizeHome {
            Button("Customize Home", action: onCustomizeHome)
                .plozzActionButton(role: .secondary)
                .tint(palette.primaryText)
                .accessibilityIdentifier("home-section-customize")
        }
        if let onSeeAll { Button("See all", action: onSeeAll) }
    }

    private var symbol: String {
        if case .failed = issue.reason { return "exclamationmark.triangle" }
        return "info.circle"
    }
}

private struct HomeSectionSourceLabel: View {
    let issue: HomeSectionIssue

    var body: some View {
        HStack(spacing: 8) {
            if let provider = issue.providerKind {
                ProviderBrandMark(provider: provider, size: 20, showsBackground: false)
            }
            if let server = issue.serverName {
                Text(verbatim: server)
            }
            if let library = issue.choice.library {
                Text(verbatim: library.library.title)
            }
        }
    }
}
