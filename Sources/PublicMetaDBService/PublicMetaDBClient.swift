import CoreModels
import CoreNetworking
import Foundation

public struct PublicMetaDBClient: Sendable {
    public static let baseURL = URL(string: "https://publicmetadb.com")!
    private let key: String
    private let http: any HTTPClient
    private let gate: PublicMetaDBRequestGate
    private let scope: String
    private let isCurrent: @Sendable () -> Bool

    public init(
        key: String,
        http: (any HTTPClient)? = nil,
        isCurrent: @escaping @Sendable () -> Bool = { true }
    ) throws {
        try self.init(
            key: key, http: http ?? URLSessionHTTPClient(session: Self.transportSession),
            gate: .shared, isCurrent: isCurrent
        )
    }

    init(
        key: String, http: any HTTPClient, gate: PublicMetaDBRequestGate,
        isCurrent: @escaping @Sendable () -> Bool = { true }
    ) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == 63, trimmed.hasPrefix("pm-"),
              trimmed.dropFirst(3).utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              }) else { throw PublicMetaDB.Failure.invalidKey }
        self.key = trimmed
        self.http = http
        self.isCurrent = isCurrent
        self.gate = gate
        scope = WatchlistReconciliationIdentity.credential(trimmed)
    }

    private static let transportSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    func send<Value: Decodable & Sendable>(
        _ type: Value.Type,
        method: HTTPMethod = .get,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Value {
        if method != .get {
            return try await withMutationTransaction {
                try await sendAuthorized(type, method: method, path: path, query: query, body: body)
            }
        }
        return try await sendAuthorized(type, method: method, path: path, query: query, body: body)
    }

    func withMutationTransaction<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await gate.mutationTransaction(operation)
    }

    private func sendAuthorized<Value: Decodable & Sendable>(
        _ type: Value.Type, method: HTTPMethod, path: String,
        query: [URLQueryItem], body: Data?
    ) async throws -> Value {
        try await gate.run(scope: scope, batch: path.hasSuffix("/batch")) {
            try Task.checkCancellation()
            try await WatchMutationDeliveryAuthorization.check()
            try await PublicMetaDBOperationAuthorization.current?(method != .get)
            guard isCurrent() else { throw PublicMetaDB.Failure.connectionChanged }
            var endpoint = Endpoint(
                method: method, path: "/api/external" + path, queryItems: query,
                headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
                body: body, redirectPolicy: .sameOrigin
            )
            if body != nil { endpoint.headers["Content-Type"] = "application/json" }
            endpoint.reportsUndeliveredRequests = method != .get
            endpoint.maximumResponseBytes = 8 * 1_024 * 1_024
            endpoint.redactsURLForLogging = true
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await http.sendRaw(endpoint, baseURL: Self.baseURL)
            } catch let error as HTTPRequestNotSentError {
                throw error.underlying
            } catch {
                // No upstream idempotency contract: a missing reply cannot authorize a retry.
                if method != .get { throw PublicMetaDB.Failure.uncertainWrite }
                throw error
            }
            do {
                try await WatchMutationDeliveryAuthorization.check()
                try await PublicMetaDBOperationAuthorization.current?(false)
                guard isCurrent() else { throw PublicMetaDB.Failure.connectionChanged }
            } catch {
                if method != .get { throw PublicMetaDB.Failure.uncertainWrite }
                throw error
            }
            if response.statusCode == 429 {
                let delay = await gate.cooldown(response, scope: scope)
                throw AppError.rateLimited(retryAfter: delay)
            }
            switch response.statusCode {
            case 200...299: break
            case 401: throw PublicMetaDB.Failure.invalidKey
            case 403: throw PublicMetaDB.Failure.blocked
            case 404: throw AppError.notFound
            case 409: throw AppError.conflict
            case 500...599 where method != .get: throw PublicMetaDB.Failure.uncertainWrite
            default: throw PublicMetaDB.Failure.rejected
            }
            guard data.count <= 8 * 1_024 * 1_024 else {
                throw method == .get ? PublicMetaDB.Failure.responseTooLarge : .uncertainWrite
            }
            do {
                return try Self.decoder().decode(Value.self, from: data)
            } catch {
                PlozzLog.networking.error("PublicMetaDB invalid response status=\(response.statusCode) bytes=\(data.count)")
                if method != .get { throw PublicMetaDB.Failure.uncertainWrite }
                throw AppError.decoding
            }
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw PublicMetaDB.Failure.incompleteResponse
        }
        return decoder
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func component(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 512,
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PublicMetaDB.Failure.invalidInput
        }
        // Endpoint's URLComponents encodes the path exactly once.
        return value
    }

    func page<Item: Decodable & Sendable>(
        _ type: Item.Type, path: String, query: [URLQueryItem] = [],
        page: Int, perPage: Int = 100, maximumPageSize: Int = 500
    ) async throws -> PublicMetaDB.Page<Item> {
        guard page > 0, (1...maximumPageSize).contains(perPage) else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await send(
            PublicMetaDB.Page<Item>.self, path: path,
            query: query + [.init(name: "page", value: String(page)), .init(name: "perPage", value: String(perPage))]
        )
        try result.validate(requestedPage: page, maximumPageSize: maximumPageSize)
        return result
    }

    func acknowledge(method: HTTPMethod = .delete, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws {
        let result = try await send(PublicMetaDB.Acknowledgement.self, method: method, path: path, query: query, body: body)
        guard result.success else { throw PublicMetaDB.Failure.rejected }
    }

    func create<Item: Decodable & Sendable, Body: Encodable>(
        _ type: Item.Type, method: HTTPMethod = .post, path: String, query: [URLQueryItem] = [], body: Body
    ) async throws -> Item {
        let result = try await send(
            PublicMetaDB.Created<Item>.self, method: method, path: path, query: query,
            body: Self.encode(body)
        )
        guard result.success else { throw PublicMetaDB.Failure.rejected }
        return result.item
    }
}

actor PublicMetaDBRequestGate {
    static let shared = PublicMetaDBRequestGate(defaults: .standard)
    private let limiter = ConcurrencyLimiter(limit: 1)
    private let mutationLimiter = ConcurrencyLimiter(limit: 1)
    @TaskLocal private static var transactionID: UUID?
    private var activeTransactionID: UUID?
    private var nextRequest = Date.distantPast
    private var nextBatch = Date.distantPast
    private var notBefore: [String: Date]
    private let defaults: UserDefaults?
    private static let storageKey = "publicmetadb.requestCooldowns"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        notBefore = (defaults?.dictionary(forKey: Self.storageKey) ?? [:]).compactMapValues { value in
            guard let date = value as? Date, date.timeIntervalSince1970.isFinite else {
                PlozzLog.networking.error("PublicMetaDB stored request cooldown was invalid")
                return nil
            }
            return date > Date() ? date : nil
        }
    }

    func mutationTransaction<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let id = Self.transactionID, activeTransactionID == id {
            try Task.checkCancellation()
            return try await operation()
        }
        return try await mutationLimiter.runUnlessCancelled {
            try await self.runMutationTransaction(operation)
        }
    }

    private func runMutationTransaction<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        activeTransactionID = id
        defer { activeTransactionID = nil }
        return try await Self.$transactionID.withValue(id, operation: operation)
    }

    func run<Value: Sendable>(
        scope: String, batch: Bool, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await limiter.run {
            try await self.admit(scope: scope, batch: batch)
            return try await operation()
        }
    }

    private func admit(scope: String, batch: Bool) async throws {
        let now = Date()
        if let deadline = notBefore[scope], now < deadline {
            throw AppError.rateLimited(retryAfter: deadline.timeIntervalSince(now))
        }
        let delay = max(nextRequest, batch ? nextBatch : .distantPast).timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        nextRequest = Date().addingTimeInterval(0.04)
        if batch { nextBatch = Date().addingTimeInterval(0.35) }
    }

    func cooldown(_ response: HTTPURLResponse, scope: String) -> TimeInterval {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
        let serverNow = response.value(forHTTPHeaderField: "Date").flatMap(formatter.date(from:)) ?? Date()
        let raw = Double(header) ?? formatter.date(from: header)?.timeIntervalSince(serverNow) ?? 60
        let seconds = raw.isFinite ? max(1, raw) : 60
        notBefore = notBefore.filter { $0.value > Date() }
        notBefore[scope] = Date().addingTimeInterval(seconds)
        defaults?.set(notBefore, forKey: Self.storageKey)
        return seconds
    }
}

/// A visible operation's revocable scope checks, not a persisted grant.
enum PublicMetaDBOperationAuthorization {
    @TaskLocal static var current: (@Sendable (_ beforeWrite: Bool) async throws -> Void)?
}
