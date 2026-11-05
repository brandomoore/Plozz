import SwiftUI
import CoreModels

public struct HomeSectionStatusView: View {
    @Environment(\.themePalette) private var palette
    private let issue: HomeSectionIssue
    private let onRetry: () -> Void
    private let onSeeAll: (() -> Void)?
    private let onCustomizeHome: (() -> Void)?
    private let showsTitle: Bool
    @State private var showsDetails = false

    public init(
        issue: HomeSectionIssue, showsTitle: Bool = true,
        onSeeAll: (() -> Void)? = nil, onCustomizeHome: (() -> Void)? = nil,
        onRetry: @escaping () -> Void
    ) {
        self.issue = issue
        self.onSeeAll = onSeeAll
        self.onCustomizeHome = onCustomizeHome
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
                ContentUnavailableView {
                    Label(issue.summary, systemImage: "rectangle.stack")
                } description: {
                    HomeSectionSourceLabel(issue: issue)
                } actions: {
                    if let onCustomizeHome {
                        Button(action: onCustomizeHome) {
                            Text("Customize Home")
                                .font(.subheadline)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .tint(palette.primaryText)
                        .accessibilityIdentifier("home-section-customize")
                    }
                    if let onSeeAll { Button("See all", action: onSeeAll) }
                }
                #if os(tvOS)
                .frame(maxWidth: .infinity, minHeight: 220)
                #else
                .frame(maxWidth: .infinity, minHeight: 180)
                #endif
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
