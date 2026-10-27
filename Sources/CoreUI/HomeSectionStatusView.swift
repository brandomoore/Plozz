import SwiftUI
import CoreModels

public struct HomeSectionStatusView: View {
    private let issue: HomeSectionIssue
    private let onRetry: () -> Void
    private let onSeeAll: (() -> Void)?
    private let showsTitle: Bool
    @State private var showsDetails = false

    public init(
        issue: HomeSectionIssue, showsTitle: Bool = true,
        onSeeAll: (() -> Void)? = nil, onRetry: @escaping () -> Void
    ) {
        self.issue = issue
        self.onSeeAll = onSeeAll
        self.showsTitle = showsTitle
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                (issue.choice.localizedTitle.map(Text.init) ?? Text(verbatim: issue.choice.title))
                    .font(.headline)
            }
            MediaRowStatusContent(message: issue.summary, symbol: symbol) {
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

    private var symbol: String {
        if case .failed = issue.reason { return "exclamationmark.triangle" }
        return "info.circle"
    }
}
