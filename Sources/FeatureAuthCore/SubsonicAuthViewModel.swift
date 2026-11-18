import CoreModels
import CoreNetworking
import Foundation
import Observation
import ProviderSubsonic

@MainActor @Observable
public final class SubsonicAuthViewModel {
    public var address: String
    public var username: String
    public var password = ""
    public var usesAPIKey = false
    public private(set) var isConnecting = false
    public private(set) var errorMessage: LocalizedStringResource?
    private let deviceID: String
    private let http: any HTTPClient
    private let onAuthenticated: (UserSession) throws -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init(
        deviceID: String, address: String = "", username: String = "",
        http: any HTTPClient = SubsonicProvider.defaultHTTP,
        onAuthenticated: @escaping (UserSession) throws -> Void
    ) {
        self.deviceID = deviceID
        self.address = address
        self.username = username
        self.http = http
        self.onAuthenticated = onAuthenticated
    }

    public var canSubmit: Bool {
        !isConnecting && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    public func signIn() {
        guard canSubmit else { return }
        errorMessage = nil
        isConnecting = true
        let generation = generation
        let address = address, username = username, password = password, usesAPIKey = usesAPIKey
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.isConnecting = false } }
            do {
                let session = try await SubsonicProvider.signIn(
                    address: address, username: username, password: password, usesAPIKey: usesAPIKey,
                    deviceID: self.deviceID, http: self.http
                )
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                try self.onAuthenticated(session)
                self.password = ""
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                PlozzLog.auth.error("Subsonic sign-in or account persistence failed")
                self.errorMessage = (error as? AppError ?? .invalidResponse).userMessage
            }
        }
    }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isConnecting = false
        password = ""
    }
}
