import CoreModels
import CoreNetworking
import Foundation
import Observation
import ProviderIPTV

@MainActor
@Observable
public final class IPTVAuthViewModel {
    public typealias SignIn = @Sendable (
        IPTVCredential, String, String, @escaping @Sendable (IPTVImportProgress) -> Void
    ) async throws -> UserSession
    public enum CompletionError: Error { case persistence }
    public enum Authentication: String, CaseIterable, Identifiable {
        case none, basic, bearer
        public var id: String { rawValue }
        public var title: LocalizedStringResource {
            switch self {
            case .none: "Included in URL"
            case .basic: "Username and password"
            case .bearer: "Bearer token"
            }
        }
    }
    public struct Header: Identifiable {
        public let id = UUID()
        public var name = ""
        public var value = ""
    }
    public struct Guide: Identifiable {
        public let id = UUID()
        public var address = ""
    }

    public var mode: IPTVCredential.Mode = .playlist
    public var playlistFileURL: URL?
    public var address: String
    public var name: String
    public var username = ""
    public var password = ""
    public var token = ""
    public var guideAddress: String
    public var additionalGuides: [Guide]
    public var guideHeaders: [Header] = []
    public var discoversPlaylistGuides: Bool
    public var authentication: Authentication = .none
    public var headers: [Header] = []
    public private(set) var isConnecting = false
    public private(set) var progress = IPTVImportProgress(stage: .connecting)
    public var progressMessage: LocalizedStringResource { progress.message }
    public private(set) var issue: LocalizedStringResource?
    private let deviceID: String
    private let onAuthenticated: (UserSession) throws -> Void
    private let signIn: SignIn
    private let reconnecting: UserSession?
    private let setupDiagnostics: IPTVSetupDiagnostics
    @ObservationIgnored private var diagnosticAttempt: IPTVSetupAttempt?
    private var flow: Task<Void, Never>?
    private var generation = UUID()

    public init(
        deviceID: String, address: String = "", name: String = "", guideAddress: String = "",
        guideURLs: [URL] = [], reconnecting: UserSession? = nil, initialMode: IPTVCredential.Mode = .playlist,
        discoversPlaylistGuides: Bool = true,
        setupDiagnostics: IPTVSetupDiagnostics = .shared,
        signIn: @escaping SignIn = { credential, name, deviceID, progress in
            try await IPTVProvider.signIn(credential: credential, name: name, deviceID: deviceID, progress: progress)
        },
        onAuthenticated: @escaping (UserSession) throws -> Void
    ) {
        self.deviceID = deviceID
        self.address = address
        self.name = name
        self.guideAddress = guideURLs.first?.absoluteString ?? guideAddress
        self.discoversPlaylistGuides = discoversPlaylistGuides
        additionalGuides = guideURLs.dropFirst().map { Guide(address: $0.absoluteString) }
        self.onAuthenticated = onAuthenticated
        self.signIn = signIn
        self.setupDiagnostics = setupDiagnostics
        mode = initialMode
        self.reconnecting = reconnecting
        if let reconnecting {
            self.name = reconnecting.server.name
            do {
                let credential = try IPTVCredential.decode(reconnecting.accessToken)
                mode = credential.mode
                self.address = credential.address.absoluteString
                username = credential.username
                password = credential.password
                headers = credential.headers.sorted { $0.key < $1.key }.map { Header(name: $0.key, value: $0.value) }
                self.guideAddress = credential.explicitGuideURLs.first?.absoluteString ?? ""
                additionalGuides = credential.explicitGuideURLs.dropFirst().map { Guide(address: $0.absoluteString) }
                guideHeaders = credential.explicitGuideHeaders.sorted { $0.key < $1.key }
                    .map { Header(name: $0.key, value: $0.value) }
                self.discoversPlaylistGuides = credential.automaticallyDiscoversGuides
            } catch {
                issue = "Enter your provider's connection details again to reconnect this account."
                PlozzLog.auth.error("Saved IPTV connection details are unavailable")
            }
        }
    }

    public var hasAdvancedConfiguration: Bool {
        (mode == .playlist && authentication != .none)
            || (mode != .file && !headers.isEmpty)
            || !guideAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !additionalGuides.isEmpty || !guideHeaders.isEmpty
            || (mode != .xtream && !discoversPlaylistGuides)
    }

    public var usesHTTP: Bool {
        let addresses = (mode == .file ? [] : [address])
            + [guideAddress] + additionalGuides.map(\.address)
        return addresses.contains { address in
            let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))
            return url?.scheme?.lowercased() == "http"
        }
    }

    public var canConnect: Bool {
        if mode == .file { return !isConnecting && playlistFileURL != nil }
        return !isConnecting && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode != .xtream && authentication != .basic || !username.isEmpty && !password.isEmpty)
            && (mode == .xtream || authentication != .bearer || !token.isEmpty)
    }

    public func addHeader() { headers.append(Header()) }
    public func addGuideHeader() { guideHeaders.append(Header()) }
    public func addGuide() { additionalGuides.append(Guide()) }

    public func connect() {
        guard canConnect else { return }
        cancel()
        issue = nil
        let current = generation
        let attempt = setupDiagnostics.begin(
            source: mode == .file ? .playlistFile : mode == .xtream ? .xtream : .playlistURL,
            authentication: diagnosticAuthentication,
            entry: reconnecting == nil ? .addAccount : .reconnectAccount
        )
        diagnosticAttempt = attempt
        do {
            let credential = try makeCredential()
            let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = enteredName.isEmpty && mode == .file
                ? playlistFileURL?.deletingPathExtension().lastPathComponent ?? "IPTV" : enteredName
            let fileURL = mode == .file ? playlistFileURL : nil
            isConnecting = true
            progress = IPTVImportProgress(stage: mode == .file ? .playlist : .connecting)
            flow = Task { [weak self, deviceID, signIn] in
                await IPTVSetupDiagnostics.$current.withValue(attempt) {
                    defer { attempt?.finish(.init(.cancelled)) }
                    do {
                        let progress: @Sendable (IPTVImportProgress) -> Void = { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == current, self.isConnecting else { return }
                                self.progress = progress
                            }
                        }
                        var session: UserSession
                        if let fileURL {
                            let accessed = fileURL.startAccessingSecurityScopedResource()
                            defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
                            session = try await IPTVProvider.importFile(
                                fileURL, credential: credential, name: displayName, deviceID: deviceID, progress: progress
                            )
                        } else {
                            session = try await signIn(credential, displayName, deviceID, progress)
                        }
                        try Task.checkCancellation()
                        guard let self, self.generation == current else { return }
                        if let previous = self.reconnecting {
                            session.server.id = previous.server.id
                            session.userID = previous.userID
                        }
                        self.isConnecting = false
                        attempt?.advance(to: .persistence)
                        // Account activation can spawn long-lived refresh/sync tasks.
                        try IPTVSetupDiagnostics.$current.withValue(nil) {
                            try self.onAuthenticated(session)
                        }
                        attempt?.finish()
                    } catch {
                        guard let self, self.generation == current, !Task.isCancelled else { return }
                        let failure: IPTVSetupDiagnostic.Failure = error is CompletionError
                            ? .init(.storage) : (error as? IPTVError)?.setupFailure ?? .sanitized(error)
                        attempt?.finish(failure)
                        self.isConnecting = false
                        self.show(error)
                    }
                }
            }
        } catch {
            attempt?.finish(.init(.invalidInput))
            show(error)
        }
    }

    public func cancel() {
        diagnosticAttempt?.finish(.init(.cancelled))
        diagnosticAttempt = nil
        generation = UUID()
        flow?.cancel()
        flow = nil
        isConnecting = false
    }

    private var diagnosticAuthentication: IPTVSetupDiagnostic.Authentication {
        if mode == .file { return .none }
        if mode == .xtream { return .xtream }
        switch authentication {
        case .basic: return .basic
        case .bearer: return .bearer
        case .none: return headers.isEmpty ? .url : .customHeaders
        }
    }

    public func makeCredential() throws -> IPTVCredential {
        let text = mode == .file ? "https://imported-playlist.invalid"
            : address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw IPTVError.invalidAddress
        }
        let guideText = guideAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let guide = guideText.isEmpty ? nil : URL(string: guideText)
        guard guideText.isEmpty || guide != nil else { throw IPTVError.invalidAddress }
        let extraGuides = try additionalGuides.compactMap { entry -> URL? in
            let text = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            guard let url = URL(string: text), LiveTVPlaylistSource.isSupportedURL(url) else {
                throw IPTVError.invalidAddress
            }
            return url
        }
        var values = try headerValues(headers)
        if mode == .playlist, authentication != .none {
            guard !values.keys.contains(where: { $0.lowercased() == "authorization" }) else { throw AppError.invalidResponse }
            values["Authorization"] = authentication == .basic
                ? "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
                : "Bearer " + token
        }
        return try IPTVCredential(
            mode: mode, address: url, username: username, password: password,
            headers: values, guideURL: guide, additionalGuideURLs: extraGuides,
            guideHeaders: try headerValues(guideHeaders), discoversPlaylistGuides: discoversPlaylistGuides
        )
    }

    private func headerValues(_ headers: [Header]) throws -> [String: String] {
        var values: [String: String] = [:]
        for header in headers {
            let key = header.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !header.value.isEmpty,
                  !values.keys.contains(where: { $0.lowercased() == key.lowercased() }) else {
                throw AppError.invalidResponse
            }
            values[key] = header.value
        }
        return values
    }

    private func show(_ error: any Error) {
        if error is CompletionError { issue = "Your IPTV account couldn't be saved. Please try again." }
        else if let error = error as? IPTVError { issue = error.userDescription }
        else if let error = error as? LiveTVSourceImportError { issue = error.userDescription }
        else if error as? AppError == .invalidResponse {
            issue = "Check the address, guide URL, and authentication fields. Header names must be unique."
        } else {
            issue = "Couldn't connect to this IPTV provider. Check the address and your connection, then try again."
        }
        PlozzLog.auth.error("IPTV connection could not be completed")
    }
}
