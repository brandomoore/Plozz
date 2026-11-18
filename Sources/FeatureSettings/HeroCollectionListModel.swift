import CoreModels
import CoreNetworking
import Foundation
import Observation

enum HeroCollectionPickerSelection {
    static func contains(_ choice: HeroCollectionSelection, in selections: [HeroCollectionSelection]) -> Bool {
        selections.contains { matches($0, choice) }
    }

    static func toggle(_ choice: HeroCollectionSelection, in selections: inout [HeroCollectionSelection]) {
        if contains(choice, in: selections) {
            selections.removeAll { matches($0, choice) }
        } else {
            selections.append(choice)
        }
    }

    private static func matches(_ stored: HeroCollectionSelection, _ choice: HeroCollectionSelection) -> Bool {
        stored.accountID == choice.accountID && stored.libraryID == choice.libraryID
            && stored.collectionID == choice.collectionID
            && (stored.serverUserID == nil || stored.serverUserID == choice.serverUserID)
    }
}

extension HeroCollectionSelection {
    func pickerFocusID(isSummary: Bool) -> String {
        let parts = [accountID, libraryID, serverUserID, collectionID]
            .map { $0.map { Data($0.utf8).base64EncodedString() } ?? "-" }
        return "hero-collection-\(isSummary ? "selected" : "choice"):\(parts.joined(separator: ":"))"
    }
}

struct HeroCollectionPickerSource: Identifiable, Hashable {
    struct ID: Hashable {
        let accountID: String
        let libraryID: String?

        var focusID: String {
            let account = Data(accountID.utf8).base64EncodedString()
            let library = libraryID.map { Data($0.utf8).base64EncodedString() } ?? "personal"
            return "hero-collection-source:\(account):\(library)"
        }
    }

    let id: ID
    let accountName: String // l10n:content — server-provided account name
    let serverName: String // l10n:content — server name
    let libraryTitle: String? // l10n:content — server-provided library name
    var providerKind: ProviderKind? = nil

    static func available(libraries: [AggregatedLibrary], accounts: [ResolvedAccount], playlists: Bool = false) -> [Self] {
        accounts.flatMap { account in
            let capabilities = (account.provider as? any CapabilityReporting)?.capabilities ?? .videoOnly
            var sources: [Self] = []
            if !playlists && capabilities.contains(.personalCollections) {
                sources.append(Self(
                    id: ID(accountID: account.account.id, libraryID: nil),
                    accountName: account.provider.session.userName,
                    serverName: account.provider.session.server.name, libraryTitle: nil,
                    providerKind: account.account.server.provider
                ))
            }
            if capabilities.contains(playlists ? .videoPlaylists : .libraryCollections) {
                sources += libraries.filter {
                    $0.accountID == account.account.id && ($0.library.kind == .movie || $0.library.kind == .series)
                }.map {
                    Self(id: ID(accountID: $0.accountID, libraryID: $0.library.id),
                         accountName: $0.accountName, serverName: $0.serverName, libraryTitle: $0.library.title,
                         providerKind: account.account.server.provider)
                }
            }
            return sources
        }
    }
}

@MainActor
@Observable
final class HeroCollectionListModel {
    public private(set) var items: [MediaItem] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = true
    public private(set) var error: AppError?
    private let provider: any MediaProvider
    private let libraryID: String?
    private let playlists: Bool
    private var nextIndex = 0

    public init(provider: any MediaProvider, libraryID: String?, playlists: Bool = false) {
        self.provider = provider
        self.libraryID = libraryID
        self.playlists = playlists
    }

    public func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let request = PageRequest(startIndex: nextIndex, limit: 50)
            let page: MediaPage
            if let libraryID {
                page = playlists
                    ? try await provider.videoPlaylists(in: libraryID, page: request)
                    : try await provider.collections(in: libraryID, page: request)
            } else if playlists {
                throw AppError.invalidResponse
            } else {
                page = try await provider.personalCollections(page: request)
            }
            try Task.checkCancellation()
            var seen = Set(items.map(\.id))
            guard page.startIndex == nextIndex, page.totalCount >= 0,
                  page.items.count <= request.limit, page.endIndex <= page.totalCount,
                  page.items.allSatisfy({
                      $0.kind == (playlists ? .playlist : .collection)
                          && !$0.id.isEmpty && seen.insert($0.id).inserted
                  }),
                  !page.items.isEmpty || nextIndex >= page.totalCount else {
                throw AppError.invalidResponse
            }
            items += page.items
            nextIndex = page.endIndex
            hasMore = page.hasMore
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, (error as? AppError) != .cancelled else { return }
            self.error = (error as? AppError) ?? .unknown("")
            PlozzLog.app.error("Hero collection picker could not load a page")
        }
    }
}
