import Foundation
import Observation

public struct HomeSectionIssue: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case failed(AppError)
        case empty
        case notReturned
        case sourceUnavailable
    }

    public let choice: HomeRowChoice
    public let reason: Reason
    public let serverName: String?
    public let providerKind: ProviderKind?
    public var id: HomeRowID { choice.id }

    public init(
        choice: HomeRowChoice, reason: Reason,
        serverName: String? = nil, providerKind: ProviderKind? = nil
    ) {
        self.choice = choice
        self.reason = reason
        self.serverName = serverName
        self.providerKind = providerKind
    }

    public var summary: LocalizedStringResource {
        switch reason {
        case .failed: return "Couldn't load this section"
        case .empty: return "No titles to show"
        case .notReturned: return "Section unavailable in the latest refresh"
        case .sourceUnavailable: return "Section source unavailable"
        }
    }

    public var explanation: LocalizedStringResource {
        switch reason {
        case let .failed(error): return error.userMessage
        case .empty:
            return "The latest request completed, but there are no titles to show with your current Home settings. This isn't a connection error."
        case .notReturned:
            return "The latest Home refresh didn't return this saved section. It may be empty or have changed on the server. Your Home selection is still saved."
        case .sourceUnavailable:
            return "This section's library wasn't available during the latest Home refresh. Check that the source is connected and this server user can access it."
        }
    }
}

/// Transient results shared by Home and its editor, never synced or cached on disk.
@MainActor @Observable
public final class HomeSectionDiagnosticsModel {
    public private(set) var isLoading = false
    private var issues: [HomeSectionIssue] = []
    private var scope: [String] = []
    private var visibility: HomeLibraryVisibility?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reload: (@MainActor () async -> Void)?

    public init() {}

    public func issues(
        accounts: [ResolvedAccount], visibility: HomeLibraryVisibility
    ) -> [HomeSectionIssue] {
        guard scope == Self.scope(accounts), self.visibility == visibility else { return [] }
        return issues
    }

    public func begin(
        accounts: [ResolvedAccount], visibility: HomeLibraryVisibility
    ) -> UUID {
        let scope = Self.scope(accounts)
        if self.scope != scope || self.visibility != visibility { issues = [] }
        self.scope = scope
        self.visibility = visibility
        generation = UUID()
        isLoading = true
        reload = nil
        return generation
    }

    public func finish(
        _ generation: UUID, issues: [HomeSectionIssue],
        reload: @escaping @MainActor () async -> Void
    ) {
        guard generation == self.generation else { return }
        self.issues = issues
        self.reload = reload
        isLoading = false
    }

    public func cancel(_ generation: UUID) {
        guard generation == self.generation, isLoading else { return }
        isLoading = false
        issues = []
    }

    public func update(
        issues: [HomeSectionIssue], accounts: [ResolvedAccount], visibility: HomeLibraryVisibility
    ) {
        guard !isLoading, scope == Self.scope(accounts), self.visibility == visibility else { return }
        self.issues = issues
    }

    public func retry(accounts: [ResolvedAccount], visibility: HomeLibraryVisibility) async {
        guard !isLoading, scope == Self.scope(accounts), self.visibility == visibility else { return }
        await reload?()
    }

    private static func scope(_ accounts: [ResolvedAccount]) -> [String] {
        accounts.sorted { $0.account.id < $1.account.id }.flatMap {
            [$0.account.id, $0.account.server.identityKey, $0.provider.kind.rawValue,
             $0.provider.session.userID, $0.plexHomeUserID ?? "",
             $0.credentialRevision.rawValue.uuidString]
        }
    }
}
