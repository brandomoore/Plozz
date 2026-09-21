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
        case error(LocalizedStringResource)
    }
    public private(set) var phase: Phase = .idle
    public var pin = ""
    public private(set) var pinError: LocalizedStringResource?
    private let server: MediaServer
    private let deviceID: String
    private let service: SiloAuthentication
    private let onAuthenticated: (UserSession) -> Void
    private var flow: Task<Void, Never>?
    private var generation = UUID()
    private var tokens: SiloTokenPair?

    public init(server: MediaServer, deviceID: String, onAuthenticated: @escaping (UserSession) -> Void) {
        self.server = server
        self.deviceID = deviceID
        service = SiloAuthentication(baseURL: server.baseURL)
        self.onAuthenticated = onAuthenticated
    }

    public func start() {
        cancel()
        let current = generation
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
                      Self.sameOrigin(url, server.baseURL),
                      challenge.expires_in > 0, challenge.interval > 0 else { throw AppError.invalidResponse }
                let deadline = Date().addingTimeInterval(TimeInterval(challenge.expires_in))
                try Task.checkCancellation()
                guard generation == current else { return }
                phase = .pairing(code: challenge.user_code, match: challenge.match_code, url: url, expiresAt: deadline)
                var interval = challenge.interval
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
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
                        phase = .loading
                        let profiles = try await service.profiles(token: received.access_token)
                        try Task.checkCancellation()
                        guard generation == current else { return }
                        guard !profiles.isEmpty else { throw AppError.notFound }
                        phase = .profiles(profiles)
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
        pin = ""
        pinError = nil
        if profile.has_pin { phase = .pin(profile) }
        else { finish(profile, pin: nil) }
    }

    public func submitPIN(_ profile: SiloProfile) {
        let value = pin
        pin = ""
        pinError = nil
        finish(profile, pin: value)
    }

    private func finish(_ profile: SiloProfile, pin: String?) {
        guard let tokens else { return }
        flow?.cancel()
        let current = generation
        phase = .loading
        flow = Task { [weak self] in
            guard let self else { return }
            do {
                let proof: String?
                if let pin { proof = try await service.verifyPIN(pin, profile: profile, token: tokens.access_token) }
                else { proof = nil }
                let session = try await service.makeSession(tokens: tokens, profile: profile, profileToken: proof, deviceID: deviceID)
                try Task.checkCancellation()
                guard generation == current else { return }
                self.tokens = nil
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
        pin = ""
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
