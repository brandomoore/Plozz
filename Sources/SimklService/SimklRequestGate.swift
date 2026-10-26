import CoreModels
import CoreNetworking
import Foundation

actor SimklRequestGate {
    static let shared = SimklRequestGate(defaults: .standard)
    private let limiter = ConcurrencyLimiter(limit: 1)
    private let defaults: UserDefaults?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var nextRequest: [String: Date] = [:]
    private var cooldowns: [String: Date]
    private static let storageKey = "simkl.requestCooldowns"

    init(
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        cooldowns = (defaults?.dictionary(forKey: Self.storageKey) ?? [:]).compactMapValues {
            guard let date = $0 as? Date, date.timeIntervalSince1970.isFinite else {
                PlozzLog.networking.error("Simkl stored cooldown was invalid")
                return nil
            }
            return date > now() ? date : nil
        }
    }

    func run(
        clientID: String, method: HTTPMethod,
        validate: @escaping @Sendable () async throws -> Void,
        operation: @escaping @Sendable () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        let key = WatchlistReconciliationIdentity.credential(clientID)
        return try await limiter.run {
            try await self.admit(key: key, method: method)
            try Task.checkCancellation()
            try await validate()
            try Task.checkCancellation()
            await self.dispatched(key: key, method: method)
            do {
                let result = try await operation()
                await self.received(result.1, key: key)
                return result
            } catch let error as AppError {
                if case .rateLimited(let retry) = error { await self.cooldown(key: key, delay: retry ?? 60) }
                throw error
            }
        }
    }

    private func admit(key: String, method: HTTPMethod) async throws {
        try requireQuota(key)
        let lane = key + (method == .get ? "/read" : "/write")
        if let next = nextRequest[lane] {
            let delay = next.timeIntervalSince(now())
            if delay > 0 { try await sleep(delay) }
        }
        try Task.checkCancellation()
        try requireQuota(key)
    }

    private func dispatched(key: String, method: HTTPMethod) {
        let lane = key + (method == .get ? "/read" : "/write")
        nextRequest = nextRequest.filter { $0.value > now() }
        // The current PIN integration uses the app-wide V1 bucket, including across profiles.
        nextRequest[lane] = now().addingTimeInterval(method == .get ? 0.11 : 1.01)
    }

    private func requireQuota(_ key: String) throws {
        if let until = cooldowns[key], until > now() {
            throw AppError.rateLimited(retryAfter: until.timeIntervalSince(now()))
        }
    }

    private func received(_ response: HTTPURLResponse, key: String) {
        let retry = Self.retryAfter(response)
        if response.statusCode == 429 {
            cooldown(key: key, delay: retry ?? 60)
        } else if response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) == 0 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let current = now()
            guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current)) else {
                PlozzLog.networking.error("Simkl quota reset could not be calculated")
                cooldown(key: key, delay: 90_000)
                return
            }
            cooldown(key: key, delay: max(retry ?? 0, midnight.timeIntervalSince(current)))
        }
    }

    private func cooldown(key: String, delay: TimeInterval) {
        let bounded = delay.isFinite && delay >= 0 ? min(90_000, max(1, delay)) : 60
        cooldowns[key] = max(cooldowns[key] ?? .distantPast, now().addingTimeInterval(bounded))
        cooldowns = cooldowns.filter { $0.value > now() }
        defaults?.set(cooldowns, forKey: Self.storageKey)
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        guard let delay = Double(raw), delay.isFinite, delay >= 0 else {
            PlozzLog.networking.error("Simkl retry delay was invalid")
            return nil
        }
        return min(90_000, delay)
    }
}
