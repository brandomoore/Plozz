import CoreModels
import Observation
import ProviderShare

extension MediaShareWorkScope {
    public static func resolve(
        profileID: String,
        isProfileAuthorized: Bool,
        activeAccountIDs: Set<String>,
        accounts: [Account],
        visibility: HomeLibraryVisibility
    ) -> Self {
        let eligible = accounts.filter {
            isProfileAuthorized
                && $0.server.provider == .mediaShare
                && activeAccountIDs.contains($0.id)
                && ShareProvider.hasEnabledCatalogLibrary(
                    accountID: $0.id,
                    configuration: $0.server.mediaShareLibraryConfiguration,
                    visibility: visibility
                )
        }
        return Self(profileID: profileID, accountKeys: Set(eligible.map(\.id)))
    }
}

@MainActor
public final class MediaShareWorkScopeController {
    private let snapshot: @MainActor () -> MediaShareWorkScope
    private let apply: @Sendable (MediaShareWorkScope, UInt64) async -> Void
    private var previous: MediaShareWorkScope?
    private var revision: UInt64 = 0
    private var isStarted = false

    public init(
        snapshot: @escaping @MainActor () -> MediaShareWorkScope,
        apply: @escaping @Sendable (MediaShareWorkScope, UInt64) async -> Void
    ) {
        self.snapshot = snapshot
        self.apply = apply
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        observe()
    }

    public func synchronize() async {
        let scope = snapshot()
        previous = scope
        revision &+= 1
        await apply(scope, revision)
    }

    private func observe() {
        let scope = withObservationTracking {
            snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard scope != previous else { return }
        previous = scope
        revision &+= 1
        let revision = revision
        let apply = apply
        Task { await apply(scope, revision) }
    }
}
