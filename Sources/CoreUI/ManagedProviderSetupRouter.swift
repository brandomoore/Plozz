import CoreModels
import Observation
import SwiftUI

@MainActor
@Observable
public final class ManagedProviderSetupRouter {
    public struct Request: Identifiable {
        public let id = UUID()
        public let playlist: LiveTVPlaylistSource?
        public let account: Account?
        public let mode: IPTVCredential.Mode
    }

    public var request: Request?
    public init() {}
    public func connectIPTV(
        playlist: LiveTVPlaylistSource? = nil, account: Account? = nil, mode: IPTVCredential.Mode = .playlist
    ) {
        request = Request(playlist: playlist, account: account, mode: mode)
    }
}

extension EnvironmentValues {
    @Entry public var managedProviderSetupRouter: ManagedProviderSetupRouter?
}
