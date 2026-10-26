import CoreModels
import CoreNetworking
import Foundation

enum WetrakrRequestOperation: String, Sendable, CaseIterable {
    case deviceCode, devicePoll, exchange, refreshToken, logout, status
    case start, pause, stop, activities, planningBaseline, planningJournal
    case planningWrite, historyWrite, historyRead, other

    init(path: String) {
        switch path {
        case "/oauth/device/code": self = .deviceCode
        case "/oauth/device/token": self = .devicePoll
        case "/oauth/token": self = .exchange
        case "/oauth/token/refresh": self = .refreshToken
        case "/oauth/logout": self = .logout
        case "/account/settings": self = .status
        case "/scrobble/start": self = .start
        case "/scrobble/pause": self = .pause
        case "/scrobble/stop": self = .stop
        case "/sync/last_activities": self = .activities
        case "/sync/tracking/planning/all": self = .planningBaseline
        case "/sync/journal": self = .planningJournal
        case "/sync/tracking/remove": self = .planningWrite
        default: self = .other
        }
    }
}

actor WetrakrRequestGate {
    static let shared = WetrakrRequestGate(defaults: .standard)
    private static let storageKey = "wetrakr.requestCooldowns"
    private let limiter = ConcurrencyLimiter(limit: 1)
    private let defaults: UserDefaults?
    private let now: @Sendable () -> Date
    private var cooldowns: [String: Date]
    private let diagnosticSession = UUID().uuidString
    private(set) var requestCounts: [WetrakrRequestOperation: Int] = [:]

    init(defaults: UserDefaults? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        let saved = defaults?.dictionary(forKey: Self.storageKey) ?? [:]
        cooldowns = saved.compactMapValues { value in
            guard let date = value as? Date, date.timeIntervalSince1970.isFinite else {
                PlozzLog.networking.error("WeTrakr stored cooldown was invalid")
                return nil
            }
            return date > now() ? date : nil
        }
    }

    func run<T: Sendable>(
        clientID: String, accessToken: String?, request: WetrakrRequestOperation,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await limiter.run {
            try Task.checkCancellation()
            try await self.admit(clientID: clientID, accessToken: accessToken, request: request)
            return try await operation()
        }
    }

    private func scope(clientID: String, accessToken: String?, application: Bool = false) -> String {
        // Opaque storage keys only; neither these fingerprints nor credentials are logged.
        WatchlistReconciliationIdentity.credential(
            (application ? "app" : "credential") + "\u{0}" + clientID + "\u{0}" + (accessToken ?? "")
        )
    }

    private func admit(clientID: String, accessToken: String?, request: WetrakrRequestOperation) throws {
        let deadlines = [
            cooldowns[scope(clientID: clientID, accessToken: nil, application: true)],
            cooldowns[scope(clientID: clientID, accessToken: accessToken)]
        ].compactMap { $0 }
        if let deadline = deadlines.max(), deadline > now() {
            throw AppError.rateLimited(retryAfter: deadline.timeIntervalSince(now()))
        }
        requestCounts[request, default: 0] += 1
        let counts = WetrakrRequestOperation.allCases.compactMap { operation in
            requestCounts[operation].map { "\(operation.rawValue)=\($0)" }
        }.joined(separator: ",")
        emit("request operation=\(request.rawValue) total=\(requestCounts.values.reduce(0, +)) counts=\(counts)")
    }

    func received(
        _ response: HTTPURLResponse, code: String?, clientID: String,
        accessToken: String?, request: WetrakrRequestOperation
    ) -> TimeInterval? {
        emit("response operation=\(request.rawValue) status=\(response.statusCode)")
        let applicationExhausted = seconds(response, "X-App-Quota-Remaining") == 0
            || code == "APP_QUOTA_EXCEEDED"
        let userExhausted = seconds(response, "X-Quota-Remaining") == 0
            || seconds(response, "X-App-User-Quota-Remaining") == 0
            || code == "QUOTA_EXCEEDED" || code == "APP_USER_QUOTA_EXCEEDED"
        let daily = applicationExhausted || userExhausted
        guard response.statusCode == 429 || daily else { return nil }
        let serverNow = response.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate) ?? now()
        let retry = seconds(response, "Retry-After") ?? response.value(forHTTPHeaderField: "Retry-After")
            .flatMap(Self.httpDate).map { max(0, $0.timeIntervalSince(serverNow)) }
        let delay: TimeInterval
        if daily {
            // X-Quota-Reset is a duration, not a Unix timestamp.
            let midnight = (floor(serverNow.timeIntervalSince1970 / 86_400) + 1) * 86_400
            let reset = seconds(response, "X-Quota-Reset") ?? (midnight - serverNow.timeIntervalSince1970)
            delay = min(86_400, max(1, reset, retry ?? 0))
        } else {
            delay = min(86_400, max(1, retry ?? seconds(response, "RateLimit-Reset") ?? 60))
        }
        let key = scope(
            clientID: clientID, accessToken: applicationExhausted ? nil : accessToken,
            application: applicationExhausted
        )
        cooldowns[key] = max(cooldowns[key] ?? .distantPast, now().addingTimeInterval(delay))
        cooldowns = cooldowns.filter { $0.value > now() }
        defaults?.set(cooldowns, forKey: Self.storageKey)
        emit("cooldown kind=\(daily ? "daily" : "window") scope=\(applicationExhausted ? "application" : "credential") seconds=\(Int(delay))")
        return delay
    }

    private func seconds(_ response: HTTPURLResponse, _ header: String) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: header), let value = Double(raw),
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }

    private func emit(_ detail: String) {
        let line = "WeTrakr session=\(diagnosticSession) \(detail)"
        PlozzLog.networking.debug(line)
        HandoffDiagnostics.emit(line)
    }

    func planningBatch(
        items: Int, unchanged: Int, outcomes: [Result<Void, WatchlistDestinationError>]
    ) {
        let succeeded = outcomes.filter { if case .success = $0 { return true }; return false }.count
        let unresolved = outcomes.filter { if case .failure(.unsupportedIdentity) = $0 { return true }; return false }.count
        emit("planning batch items=\(items) unchanged=\(unchanged) confirmed=\(succeeded) unresolved=\(unresolved) failed=\(items - succeeded - unresolved)")
    }
}

struct WetrakrClient: Sendable {
    let config: WetrakrConfig
    let http: any HTTPClient
    let gate: WetrakrRequestGate

    init(config: WetrakrConfig, http: any HTTPClient, gate: WetrakrRequestGate = .shared) {
        self.config = config
        self.http = http
        self.gate = gate
    }

    func send(
        _ endpoint: Endpoint, accessToken: String? = nil,
        operation: WetrakrRequestOperation? = nil,
        validateScope: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> (Data, HTTPURLResponse) {
        let (request, clientID) = try prepare(endpoint, accessToken: accessToken)
        let operation = operation ?? WetrakrRequestOperation(path: request.path)
        return try await gate.run(clientID: clientID, accessToken: accessToken, request: operation) {
            try await validateScope()
            let (data, response) = try await http.sendRaw(request, baseURL: config.apiBaseURL)
            let error = response.statusCode >= 400
                ? try? JSONDecoder().decode(ErrorResponse.self, from: data) : nil
            let delay = await gate.received(
                response, code: error?.error, clientID: clientID,
                accessToken: accessToken, request: operation
            )
            try await validateScope()
            if (200...299).contains(response.statusCode) { return (data, response) }
            if request.path == "/oauth/token" {
                PlozzLog.networking.error("WeTrakr authorization-code exchange rejected: HTTP \(response.statusCode)")
                if response.statusCode == 400 { throw WetrakrError.authorizationCodeRejected }
            }
            switch (response.statusCode, error?.error) {
            case (400, "authorization_pending"): throw WetrakrError.authorizationPending
            case (400, "JOURNAL_EXPIRED"): throw WetrakrError.journalExpired
            case (410, _): throw AppError.quickConnectExpired
            case (418, _): throw WetrakrError.accessDenied
            case (423, _), (401, "invalid_client"): throw WetrakrError.clientRejected
            case (401, _): throw AppError.unauthorized
            case (403, _): throw WetrakrError.requestBlocked
            case (404, _): throw AppError.notFound
            case (429, _):
                throw AppError.rateLimited(retryAfter: delay)
            default: throw AppError.invalidResponse
            }
        }
    }

    func prepare(_ endpoint: Endpoint, accessToken: String?) throws -> (Endpoint, String) {
        guard let clientID = config.clientID else { throw WetrakrError.clientRejected }
        var endpoint = endpoint
        endpoint.headers["wetrakr-api-key"] = clientID
        endpoint.headers["wetrakr-api-version"] = "1"
        endpoint.headers["Accept"] = "application/json"
        if let accessToken { endpoint.headers["Authorization"] = "Bearer \(accessToken)" }
        endpoint.redirectPolicy = .sameOrigin
        return (endpoint, clientID)
    }

    func decode<T: Decodable & Sendable>(
        _ type: T.Type, endpoint: Endpoint, accessToken: String? = nil,
        operation: WetrakrRequestOperation? = nil
    ) async throws -> T {
        let (data, _) = try await send(endpoint, accessToken: accessToken, operation: operation)
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            PlozzLog.networking.error("WeTrakr response could not be decoded")
            throw AppError.decoding
        }
    }

    func page<T: Decodable & Sendable>(
        _ type: T.Type, path: String, page: Int, query: [URLQueryItem] = [], accessToken: String
    ) async throws -> (T, hasNext: Bool) {
        let (data, response) = try await send(Endpoint(path: path, queryItems: query + [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: "100"),
        ]), accessToken: accessToken)
        guard let rawPages = response.value(forHTTPHeaderField: "X-Pagination-Page-Count"),
              let pages = Int(rawPages), pages >= 0, page <= max(1, pages)
        else { throw AppError.invalidResponse }
        do { return (try JSONDecoder().decode(type, from: data), page < pages) }
        catch { throw AppError.decoding }
    }

    struct ErrorResponse: Decodable { let error: String? }
}
