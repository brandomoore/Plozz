import Foundation
import Observation
import CoreModels
import CoreNetworking
import ProviderJellyfin
import ProviderPlex
import ProviderSilo

@MainActor
@Observable
public final class ServerAddressesModel {
    public private(set) var account: Account
    public var address = ""
    public private(set) var isWorking = false
    public private(set) var errorMessage: LocalizedStringResource?
    public private(set) var pairingServer: MediaServer?
    private let store: any AccountPersisting
    private let http: any HTTPClient
    private let isAuthorized: @MainActor () -> Bool
    private let onChanged: @MainActor () -> Void
    private var generation = UUID()

    public init(
        account: Account, store: any AccountPersisting,
        http: any HTTPClient = URLSessionHTTPClient(session: .plozzDiscovery),
        isAuthorized: @escaping @MainActor () -> Bool,
        onChanged: @escaping @MainActor () -> Void
    ) {
        self.account = account
        self.store = store
        self.http = http
        self.isAuthorized = isAuthorized
        self.onChanged = onChanged
    }

    public var alternatives: [URL] { account.server.alternateConnectionURLs ?? [] }

    public func add() async {
        guard !isWorking else { return }
        errorMessage = nil
        let current = generation
        isWorking = true
        defer { if generation == current { isWorking = false } }
        do {
            try requireCurrent(current)
            let url = try Self.normalizedAddress(address, provider: account.server.provider)
            guard url != account.server.baseURL, !alternatives.contains(url) else {
                errorMessage = "This address is already saved."
                return
            }
            switch account.server.provider {
            case .jellyfin, .emby:
                try await JellyfinClient.verifyAddress(url, serverID: account.server.id, http: http)
            case .plex:
                try await PlexProvider.verifyAddress(url, serverID: account.server.id, http: http)
            case .silo:
                var candidate = account.server
                candidate.baseURL = url
                candidate.connectionURLs = nil
                candidate.alternateConnectionURLs = nil
                pairingServer = candidate
                return
            case .iptv, .mediaShare, .subsonic:
                throw AppError.invalidResponse
            }
            try requireCurrent(current)
            try save(alternatives + [url])
            address = ""
        } catch {
            show(error, generation: current)
        }
    }

    public func completePairing(_ session: UserSession) async {
        let candidate = pairingServer
        let current = generation
        isWorking = true
        pairingServer = nil
        defer { if generation == current { isWorking = false } }
        do {
            // Cleanup owns its own task so dismissing Settings cannot cancel the
            // only revocation of this temporary verification login.
            let cleanup = Task { [http] in
                do {
                    try await SiloAuthentication(baseURL: session.server.baseURL, http: http)
                        .endVerificationSession(session)
                } catch {
                    PlozzLog.auth.error("Could not revoke Silo address verification login")
                    throw error
                }
            }
            try await cleanup.value
            try requireCurrent(current)
            guard let candidate, session.server.provider == .silo,
                  session.server.baseURL == candidate.baseURL,
                  session.server.id == account.server.id,
                  session.userID == account.userID,
                  session.deviceID == account.deviceID else {
                errorMessage = "Use the same Silo server, account, and profile as this sign-in."
                return
            }
            try save(alternatives + [candidate.baseURL])
            address = ""
        } catch {
            show(error, generation: current)
        }
    }

    public func remove(_ url: URL) {
        guard !isWorking else { return }
        do {
            try requireCurrent(generation)
            try save(alternatives.filter { $0 != url })
            errorMessage = nil
        } catch { show(error, generation: generation) }
    }

    public func cancelPairing() { pairingServer = nil }

    public func cancel() {
        generation = UUID()
        pairingServer = nil
        isWorking = false
    }

    private func save(_ alternatives: [URL]) throws {
        try store.updateServerAddresses(expected: account, alternatives: alternatives)
        account.server.alternateConnectionURLs = alternatives.isEmpty ? nil : alternatives
        onChanged()
    }

    private func requireCurrent(_ current: UUID) throws {
        try Task.checkCancellation()
        guard current == generation, isAuthorized() else { throw AppError.cancelled }
    }

    private func show(_ error: Error, generation current: UUID) {
        guard generation == current, !Task.isCancelled,
              !(error is CancellationError), error as? AppError != .cancelled else { return }
        PlozzLog.auth.error("Could not update server connection addresses")
        if error as? AppError == .conflict {
            errorMessage = "This address belongs to a different server, or the saved sign-in changed. Check the address and try again."
        } else if let error = error as? AppError {
            errorMessage = error.userMessage
        } else {
            errorMessage = "The address could not be saved. Try again."
        }
    }

    public static func normalizedAddress(_ raw: String, provider: ProviderKind) throws -> URL {
        let port = provider == .silo ? 8090 : provider == .plex ? 32400 : 8096
        guard let url = ServerURLNormalizer.normalize(raw, defaultPort: port),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw AppError.invalidResponse }
        return url
    }
}
