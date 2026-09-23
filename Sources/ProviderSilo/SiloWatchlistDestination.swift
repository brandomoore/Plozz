import Foundation
import CoreModels

public struct SiloWatchlistDestination: WatchlistLibraryResolving {
    public let id: WatchlistDestinationID
    private let provider: SiloProvider
    public let capabilities = WatchlistDestinationCapabilities(
        readable: true, writable: true, removable: true, bindingRequirement: .validatedLibraryCopy)

    public init?(provider: SiloProvider) {
        guard let id = WatchlistDestinationID(rawValue: "silo.\(provider.accountID)") else { return nil }
        self.id = id
        self.provider = provider
    }

    public var routing: WatchlistDestinationRouting {
        .init(validatedBindingScopes: [.init(providerKind: .silo, accountDescriptorID: provider.accountID)])
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        try await provider.watchlist().map { item in
            guard item.kind == .movie || item.kind == .series,
                  let key = MediaAliasProviderBindingKey(
                    providerKind: .silo, accountDescriptorID: provider.accountID, providerItemID: item.id),
                  let binding = WatchlistDestinationBinding(destinationID: id, opaqueValue: item.id),
                  let entry = WatchlistDestinationEntry(
                    kind: item.kind,
                    externalIDs: [
                        (ProviderIDNamespace.imdb, WatchlistExternalID.Namespace.imdb),
                        (.tmdb, .tmdb), (.tvdb, .tvdb)
                    ].compactMap { namespace, destination in
                        item.providerID(namespace).flatMap { WatchlistExternalID(namespace: destination, value: $0) }
                    },
                    binding: binding, corroboratedProviderBinding: key,
                    presentation: .init(title: item.title, year: item.productionYear,
                                        artworkURL: item.posterURL?.absoluteString,
                                        backdropURL: item.backdropURL?.absoluteString),
                    presentationAccountID: provider.accountID) else { throw WatchlistDestinationError.transient }
            return entry
        }
    }

    public func resolve(_ target: WatchlistMutationTarget) async throws -> WatchlistDestinationBinding? {
        WatchlistDestinationBinding(destinationID: id, opaqueValues: target.validatedBindings.filter {
            $0.providerKind == .silo && $0.accountDescriptorID == provider.accountID
        }.map(\.providerItemID))
    }

    public func apply(_ desiredState: WatchlistDesiredState, to binding: WatchlistDestinationBinding) async throws {
        guard binding.destinationID == id else { throw WatchlistDestinationError.permanent }
        for itemID in binding.opaqueValues {
            try await provider.client.send("/watchlist/\(try SiloAPI.pathComponent(itemID))",
                                           method: desiredState == .present ? .put : .delete)
        }
    }

    public func resolveLibraryCopy(for entry: WatchlistDestinationEntry) async -> WatchlistLibraryCopy? {
        guard let binding = entry.corroboratedProviderBinding, binding.providerKind == .silo,
              binding.accountDescriptorID == provider.accountID else { return nil }
        return WatchlistLibraryCopy(
            source: .init(accountID: provider.accountID, itemID: binding.providerItemID,
                          kind: entry.kind, providerKind: .silo), presentation: entry.presentation)
    }
}
