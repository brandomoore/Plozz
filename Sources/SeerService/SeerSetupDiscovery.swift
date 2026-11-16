import CoreModels
import CoreNetworking
import Foundation
import Observation

/// Public discovery data only. Authentication always resolves the live profile identity.
@MainActor
@Observable
public final class SeerSetupDiscovery {
    public struct Source: Hashable, Sendable {
        public let scopeID: String
        public let urls: [URL]
        public let mediaServerType: Int

        public init(scopeID: String, urls: [URL], mediaServerType: Int) {
            self.scopeID = scopeID
            self.urls = Set(urls).sorted { $0.absoluteString < $1.absoluteString }
            self.mediaServerType = mediaServerType
        }
    }

    public struct Scope: Hashable, Sendable {
        public let profileID: String?
        public let sources: [Source]
        public let preferredURL: URL?
        public let mediaServerTypes: Set<Int>

        public init(profileID: String?, sources: [Source], preferredURL: URL?, mediaServerTypes: Set<Int>) {
            self.profileID = profileID
            self.sources = sources.sorted { $0.scopeID < $1.scopeID }
            self.preferredURL = preferredURL
            self.mediaServerTypes = mediaServerTypes
        }
    }

    public private(set) var scope: Scope?
    public private(set) var servers: [DiscoveredSeerServer] = []
    public private(set) var selected: DiscoveredSeerServer?
    public private(set) var isSearching = false
    public private(set) var error: LocalizedStringResource?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var completedAt: ContinuousClock.Instant?

    public init() {}

    public func cancel() {
        work?.cancel()
        work = nil
        generation = UUID()
        isSearching = false
    }

    public func reset() {
        cancel()
        scope = nil
        selected = nil
        servers = []
        error = nil
        completedAt = nil
    }

    public func prepare(
        scope: Scope, force: Bool = false, stopAfterMatch: Bool = true,
        discover: @escaping @MainActor (SeerDiscovery.Request) -> AsyncStream<DiscoveredSeerServer>,
        suggested: @escaping @MainActor () async throws -> [URL],
        methods: @escaping @MainActor (URL) async throws -> SeerLoginMethods,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        if !force, self.scope == scope,
           work != nil || (selected != nil && completedAt.map({ $0.duration(to: .now) < .seconds(300) }) == true) { return }
        reset()
        self.scope = scope
        isSearching = true
        let revision = generation
        work = Task { [weak self] in
            guard let self else { return }
            @MainActor @Sendable func current() -> Bool {
                !Task.isCancelled && self.generation == revision && isCurrent()
            }
            @MainActor @Sendable func accept(_ server: DiscoveredSeerServer, preferred: Bool) {
                guard current() else { return }
                if !self.servers.contains(where: { $0.id == server.id }) { self.servers.append(server) }
                guard self.selected == nil else { return }
                let compatible = server.loginMethods?.mediaServerLogin == true
                    && server.loginMethods?.mediaServerType.map(scope.mediaServerTypes.contains) == true
                if preferred || compatible || scope.mediaServerTypes.isEmpty {
                    self.selected = server
                    if stopAfterMatch {
                        self.isSearching = false
                        self.completedAt = .now
                        // A prepared result must not wait for unrelated hosts or the plugin timeout.
                        self.work?.cancel()
                    }
                }
            }
            @MainActor @Sendable func check(_ url: URL, preferred: Bool) async {
                guard current(), SeerServerIdentity(baseURL: url) != nil else { return }
                do {
                    let value = try await methods(url)
                    accept(.init(baseURL: url, version: nil, loginMethods: value), preferred: preferred)
                } catch is CancellationError {
                    return
                } catch {
                    guard current() else { return }
                    PlozzLog.networking.debug("Seerr setup could not check a suggested server")
                    if preferred { self.error = "Couldn’t check this server. Set up manually to try another address." }
                }
            }
            @MainActor @Sendable func scan(_ request: SeerDiscovery.Request) async {
                for await server in discover(request) {
                    guard current() else { return }
                    if server.loginMethods != nil { accept(server, preferred: false) }
                    else { await check(server.baseURL, preferred: false) }
                    if stopAfterMatch, self.selected != nil { return }
                }
            }

            if let url = scope.preferredURL {
                await check(url, preferred: true)
            } else {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        do {
                            let urls = try await suggested()
                            guard current() else { return }
                            for url in urls { await check(url, preferred: urls.count == 1) }
                        } catch is CancellationError {
                            return
                        } catch {
                            guard current() else { return }
                            PlozzLog.networking.debug("Seerr plugin address lookup failed; continuing discovery")
                        }
                    }
                    let urls = SeerDiscovery.setupCandidates(mediaURLs: scope.sources.flatMap(\.urls))
                    if !urls.isEmpty {
                        group.addTask { @MainActor in
                            await scan(.init(urls: urls, includesSubnet: false))
                        }
                    }
                }
                if current(), self.selected == nil { await scan(.init()) }
            }
            guard self.generation == revision else { return }
            self.work = nil
            self.isSearching = false
            if isCurrent() {
                if !Task.isCancelled, self.selected == nil, self.servers.count == 1 {
                    self.selected = self.servers.first
                }
                self.completedAt = .now
                if self.selected != nil { self.error = nil }
            } else {
                self.reset()
            }
        }
    }
}
