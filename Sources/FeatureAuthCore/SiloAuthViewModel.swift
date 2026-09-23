import Foundation
import Observation
import CoreModels
import ProviderSilo

@MainActor
@Observable
public final class SiloAuthViewModel {
    public enum Phase: Equatable {
        case idle
        case loading
        case pairing(code: String, match: String, url: URL, expiresAt: Date)
        case profiles([SiloProfile])
        case pin(SiloProfile)
        case expired
        case error(LocalizedStringResource)
    }
    public enum Operation: Equatable {
        case preparing, loadingProfiles, signingIn(String)

        public var message: LocalizedStringResource {
            switch self {
            case .preparing: "Getting your sign-in code…"
            case .loadingProfiles: "Approved. Loading your profiles…"
            case .signingIn(let name): "Connecting as \(name)…"
            }
        }
    }
    public private(set) var phase: Phase = .idle
    public private(set) var operation: Operation = .preparing
    public private(set) var verificationURL: URL?
    public private(set) var codeLifetime: TimeInterval = 600
    public var pin = ""
    public private(set) var pinError: LocalizedStringResource?
    private let server: MediaServer
    private let deviceID: String
    private let service: SiloAuthentication
    private let onAuthenticated: (UserSession) -> Void
    private var flow: Task<Void, Never>?
    private var generation = UUID()
    private var tokens: SiloTokenPair?
    @ObservationIgnored private var availableProfiles: [SiloProfile] = []

    public init(server: MediaServer, deviceID: String, service: SiloAuthentication? = nil,
                onAuthenticated: @escaping (UserSession) -> Void) {
        self.server = server
        self.deviceID = deviceID
        self.service = service ?? SiloAuthentication(baseURL: server.baseURL)
        self.onAuthenticated = onAuthenticated
    }

    public func start() {
        cancel()
        let current = generation
        operation = .preparing
        phase = .loading
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.validateServer()
                #if os(tvOS)
                let platform = "tvos"
                #else
                let platform = "ios"
                #endif
                let challenge = try await service.beginPairing(platform: platform)
                guard let url = URL(string: challenge.verification_uri_complete, relativeTo: server.baseURL)?.absoluteURL,
                      let manualURL = URL(string: challenge.verification_uri, relativeTo: server.baseURL)?.absoluteURL,
                      Self.sameOrigin(url, server.baseURL),
                      Self.sameOrigin(manualURL, server.baseURL),
                      !challenge.user_code.isEmpty, !challenge.match_code.isEmpty,
                      challenge.expires_in > 0, challenge.interval > 0 else { throw AppError.invalidResponse }
                let deadline = Date().addingTimeInterval(TimeInterval(challenge.expires_in))
                try Task.checkCancellation()
                guard generation == current else { return }
                verificationURL = manualURL
                codeLifetime = TimeInterval(challenge.expires_in)
                phase = .pairing(code: challenge.user_code, match: challenge.match_code, url: url, expiresAt: deadline)
                var interval = challenge.interval
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(min(Double(interval), max(0, deadline.timeIntervalSinceNow))))
                    try Task.checkCancellation()
                    guard Date() < deadline else { break }
                    let result = try await service.poll(challenge)
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    switch result.status {
                    case "pending": interval = max(challenge.interval, result.poll_after)
                    case "approved":
                        guard !result.temporary, let received = result.tokens else { throw AppError.invalidResponse }
                        tokens = received
                        verificationURL = nil
                        try await loadProfiles(tokens: received, generation: current)
                        return
                    case "expired", "consumed": throw AppError.quickConnectExpired
                    case "denied": throw SiloAuthenticationError.pairingDenied
                    default: throw AppError.invalidResponse
                    }
                }
                throw AppError.quickConnectExpired
            } catch {
                show(error, generation: current)
            }
        }
    }

    public func select(_ profile: SiloProfile) {
        guard case let .profiles(profiles) = phase, profiles.contains(profile) else { return }
        pin = ""
        pinError = nil
        if profile.has_pin { phase = .pin(profile) }
        else { finish(profile, pin: nil) }
    }

    public func submitPIN(_ profile: SiloProfile) {
        guard case let .pin(selected) = phase, selected == profile,
              !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let value = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        pin = ""
        pinError = nil
        finish(profile, pin: value)
    }

    public func chooseAnotherProfile() {
        guard case .pin = phase, !availableProfiles.isEmpty else { return }
        generation = UUID()
        flow?.cancel()
        flow = nil
        pin = ""
        pinError = nil
        phase = .profiles(availableProfiles)
    }

    public func retry() {
        guard case .error = phase else {
            if phase == .expired { start() }
            return
        }
        guard let tokens, tokens.receivedAt.addingTimeInterval(TimeInterval(tokens.expires_in)) > Date() else {
            start()
            return
        }
        if !availableProfiles.isEmpty {
            pin = ""
            pinError = nil
            phase = .profiles(availableProfiles)
            return
        }
        let current = generation
        operation = .loadingProfiles
        phase = .loading
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                try await loadProfiles(tokens: tokens, generation: current)
            } catch {
                show(error, generation: current)
            }
        }
    }

    private func loadProfiles(tokens: SiloTokenPair, generation current: UUID) async throws {
        operation = .loadingProfiles
        phase = .loading
        let profiles = try await service.profiles(token: tokens.access_token)
        try Task.checkCancellation()
        guard generation == current else { return }
        guard !profiles.isEmpty else { throw AppError.notFound }
        availableProfiles = profiles
        phase = .profiles(profiles)
    }

    public func checkPairingExpiry() {
        guard case let .pairing(_, _, _, expiresAt) = phase, expiresAt <= Date() else { return }
        cancel()
        phase = .expired
    }

    private func finish(_ profile: SiloProfile, pin: String?) {
        guard let tokens else { return }
        flow?.cancel()
        let current = generation
        operation = .signingIn(profile.name)
        phase = .loading
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                let proof: String?
                if let pin { proof = try await service.verifyPIN(pin, profile: profile, token: tokens.access_token) }
                else { proof = nil }
                let session = try await service.makeSession(
                    tokens: tokens, profile: profile, profileToken: proof,
                    deviceID: deviceID, serverName: server.name
                )
                try Task.checkCancellation()
                guard generation == current else { return }
                self.tokens = nil
                availableProfiles = []
                onAuthenticated(session)
            } catch SiloAuthenticationError.incorrectPIN {
                guard generation == current, !Task.isCancelled else { return }
                pinError = "That profile PIN did not match. Try again."
                phase = .pin(profile)
            } catch {
                show(error, generation: current)
            }
        }
    }

    private func show(_ error: Error, generation current: UUID) {
        guard generation == current, !Task.isCancelled else { return }
        if let error = error as? SiloAuthenticationError {
            switch error {
            case .unsupportedServer:
                phase = .error("This connection requires a Silo server with the native v2 API. Check the server address and update Silo if needed.")
            case .pairingUnavailable:
                phase = .error("Device pairing is unavailable on this Silo server.")
            case .incorrectPIN:
                phase = .error("That profile PIN did not match. Try again.")
            case .pairingDenied:
                phase = .error("The Silo pairing request was denied.")
            }
        } else if let error = error as? AppError {
            if error == .cancelled { return }
            if error == .quickConnectExpired {
                verificationURL = nil
                phase = .expired
                return
            }
            if error == .unauthorized {
                tokens = nil
                availableProfiles = []
            }
            phase = .error(error.userMessage)
        } else if !(error is CancellationError) {
            phase = .error(AppError.invalidResponse.userMessage)
        }
    }

    public func cancel() {
        generation = UUID()
        flow?.cancel()
        flow = nil
        tokens = nil
        availableProfiles = []
        verificationURL = nil
        pin = ""
        pinError = nil
        phase = .idle
    }

    static func sameOrigin(_ url: URL, _ base: URL) -> Bool {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme, let host = url.host,
              let baseScheme = base.scheme, let baseHost = base.host,
              let origin = try? NetworkOrigin(scheme: scheme, host: host, port: url.port),
              let baseOrigin = try? NetworkOrigin(scheme: baseScheme, host: baseHost, port: base.port) else { return false }
        return origin == baseOrigin
    }
}
