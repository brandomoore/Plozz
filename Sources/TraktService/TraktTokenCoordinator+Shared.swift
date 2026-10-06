import Foundation
import CoreModels
import CoreNetworking

extension TraktTokenCoordinator {
    /// There is deliberately no lease timeout. Once an exchange might have
    /// reached Trakt, neither its owner nor another device may replay that token.
    func sharedAccess(
        store: any TraktTokenStoring,
        configuration: TraktSharedRefreshConfiguration,
        revision: UInt64,
        exchange: (@Sendable (String) async throws -> TraktTokens)?
    ) async throws -> String? {
        let key = store.coordinationID
        let state = try loadSharedState(key, configuration: configuration)
        let account: String
        do {
            account = try await configuration.transport.accountID()
        } catch {
            try checkSharedRevision(key, revision)
            if permitsOfflineAccess(after: error),
               state?.pending == nil, state?.accepted?.phase != .disconnected,
               let tokens = store.load(), !tokens.isExpired {
                return tokens.accessToken
            }
            throw error
        }
        try checkSharedRevision(key, revision)
        var journal = try bindSharedAccount(account, state: state, store: store, configuration: configuration)
        // Reattempt a failed Keychain write before making any irreversible call.
        try persistSharedState(journal, key: key, configuration: configuration)
        for _ in 0..<8 {
            let remote: TraktSharedRecord?
            do {
                remote = try await configuration.transport.read(scope: key, accountID: account)
            } catch {
                try checkSharedRevision(key, revision)
                if permitsOfflineAccess(after: error),
                   journal.pending == nil, journal.accepted?.phase != .disconnected,
                   let tokens = journal.accepted?.tokens, !tokens.isExpired {
                    return tokens.accessToken
                }
                throw error
            }
            try checkSharedRevision(key, revision)
            let current = try remote.map { try TraktSharedGrant.decode($0.value) }

            if let pending = journal.pending {
                switch pending.kind {
                case .connect, .disconnect, .successor:
                    if pending.needsBaseline {
                        // Old journals may contain an authorization whose intent
                        // was never frozen. It cannot adopt a later sign-out.
                        guard pending.kind != .connect else {
                            journal.pending = nil
                            try persistSharedState(journal, key: key, configuration: configuration)
                            if let current {
                                _ = try acceptShared(current, journal: &journal, store: store, configuration: configuration)
                            }
                            throw TraktSharedRefreshError.superseded
                        }
                        journal.pending?.expectedEpoch = current?.epoch
                        journal.pending?.needsBaseline = false
                        try persistSharedState(journal, key: key, configuration: configuration)
                        continue
                    }
                    if current == pending.grant {
                        let access = try acceptShared(
                            pending.grant, journal: &journal, store: store, configuration: configuration
                        )
                        if pending.grant.tokens?.isExpired == true, exchange != nil { continue }
                        return access
                    }
                    if pending.kind == .disconnect, let current, current.phase == .disconnected {
                        return try acceptShared(current, journal: &journal, store: store, configuration: configuration)
                    }
                    let matches: Bool
                    if pending.kind == .successor {
                        matches = current?.epoch == pending.expectedEpoch
                            && current?.phase == .refreshing && current?.claim == pending.expectedClaim
                    } else if pending.kind == .connect {
                        matches = current?.epoch == pending.expectedEpoch
                    } else {
                        matches = current?.epoch == pending.expectedEpoch && current?.phase != .disconnected
                    }
                    guard matches else {
                        if let current {
                            _ = try acceptShared(current, journal: &journal, store: store, configuration: configuration)
                        }
                        throw TraktSharedRefreshError.superseded
                    }
                    do {
                        var proposed = pending.grant
                        if pending.kind == .disconnect, let current {
                            proposed.generation = current.generation &+ 1
                            journal.pending?.grant = proposed
                            try persistSharedState(journal, key: key, configuration: configuration)
                        }
                        _ = try await configuration.transport.compareAndSwap(
                            scope: key, accountID: account, expected: remote, value: proposed.encoded()
                        )
                        try checkSharedRevision(key, revision)
                        let access = try acceptShared(proposed, journal: &journal, store: store, configuration: configuration)
                        if proposed.tokens?.isExpired == true, exchange != nil { continue }
                        return access
                    } catch TraktSharedRefreshError.conflict {
                        continue
                    }
                case .claimPrepared:
                    if current == pending.grant {
                        if let deadline = pending.retryNotBefore, now() < deadline {
                            throw TraktSharedRefreshError.retryable(retryNotBefore: deadline)
                        }
                        guard let exchange else { throw TraktSharedRefreshError.refreshInProgress }
                        guard let previous = pending.grant.tokens else {
                            throw TraktSharedRefreshError.invalidRecord
                        }
                        journal.pending?.kind = .exchangeStarted
                        do {
                            try persistSharedState(journal, key: key, configuration: configuration)
                        } catch {
                            // No HTTP call has occurred. Do not retain the
                            // proposed exchangeStarted state as an uncertain send.
                            throw retainUnspentClaim(
                                journal: &journal, key: key, configuration: configuration,
                                retryNotBefore: pending.retryNotBefore
                            )
                        }
                        // Persisting exchangeStarted is the irrevocable boundary.
                        // A timeout is not proof that Trakt did not consume it.
                        let refreshed: TraktTokens
                        do {
                            refreshed = try await exchange(previous.refreshToken)
                                .inheritingAccountIdentity(from: previous)
                        } catch is HTTPRequestNotSentError {
                            try checkSharedRevision(key, revision)
                            // Only positive transport evidence can reopen this
                            // boundary; a generic timeout/unreachable error cannot.
                            throw retainUnspentClaim(
                                journal: &journal, key: key, configuration: configuration,
                                retryNotBefore: nil
                            )
                        } catch let error as AppError {
                            try checkSharedRevision(key, revision)
                            if case .rateLimited(let retryAfter) = error {
                                let delay = retryAfter.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 60
                                throw retainUnspentClaim(
                                    journal: &journal, key: key, configuration: configuration,
                                    retryNotBefore: now().addingTimeInterval(delay)
                                )
                            }
                            throw TraktSharedRefreshError.outcomeUnknown
                        } catch {
                            try checkSharedRevision(key, revision)
                            throw TraktSharedRefreshError.outcomeUnknown
                        }
                        try checkSharedRevision(key, revision)
                        var successor = pending.grant
                        successor.phase = .ready
                        successor.claim = nil
                        successor.generation &+= 1
                        successor.tokens = refreshed
                        journal.pending = .init(
                            kind: .successor, grant: successor,
                            expectedEpoch: successor.epoch, expectedClaim: pending.grant.claim
                        )
                        try persistSharedState(journal, key: key, configuration: configuration)
                        continue
                    }
                    if let current, current.epoch == pending.grant.epoch,
                       current.generation == pending.grant.generation, current.phase == .ready {
                        do {
                            _ = try await configuration.transport.compareAndSwap(
                                scope: key, accountID: account, expected: remote, value: pending.grant.encoded()
                            )
                            try checkSharedRevision(key, revision)
                            continue
                        } catch TraktSharedRefreshError.conflict {
                            continue
                        }
                    }
                    // A competing claim won. Forget our unspent proposal, never
                    // take over the winning claim, even after a process restart.
                    journal.pending = nil
                    try persistSharedState(journal, key: key, configuration: configuration)
                case .exchangeStarted:
                    if current == pending.grant { throw TraktSharedRefreshError.outcomeUnknown }
                    journal.pending = nil
                    try persistSharedState(journal, key: key, configuration: configuration)
                }
            }

            guard let current else {
                // A previously observed record cannot disappear legitimately:
                // sign-out is a durable value, never a CKRecord deletion.
                guard journal.accepted == nil else { throw TraktSharedRefreshError.missingRecord }
                if configuration.isLocallySignedOut(key) {
                    journal.pending = .init(
                        kind: .disconnect,
                        grant: .init(epoch: UUID(), generation: 0, phase: .disconnected)
                    )
                    try persistSharedState(journal, key: key, configuration: configuration)
                    continue
                }
                let legacy = try await configuration.transport.readLegacyTokens(scope: key, accountID: account)
                try checkSharedRevision(key, revision)
                guard let tokens = legacy ?? store.load() else { return nil }
                let initial = TraktSharedGrant.ready(tokens)
                journal.pending = .init(kind: .connect, grant: initial)
                try persistSharedState(journal, key: key, configuration: configuration)
                continue
            }
            let access = try acceptShared(current, journal: &journal, store: store, configuration: configuration)
            guard let tokens = current.tokens else { return nil }
            guard tokens.isExpired else { return access }
            guard current.phase == .ready else { throw TraktSharedRefreshError.refreshInProgress }
            guard exchange != nil else { return access }
            var claim = current
            claim.phase = .refreshing
            claim.claim = UUID()
            journal.pending = .init(
                kind: .claimPrepared, grant: claim, expectedEpoch: current.epoch
            )
            try persistSharedState(journal, key: key, configuration: configuration)
        }
        throw TraktSharedRefreshError.conflict
    }

    func prepareSharedConnection(
        store: any TraktTokenStoring, configuration: TraktSharedRefreshConfiguration,
        revision: UInt64, id: UUID
    ) async throws {
        let key = store.coordinationID
        let state = try loadSharedState(key, configuration: configuration)
        let account = try await configuration.transport.accountID()
        try checkSharedRevision(key, revision)
        let remote = try await configuration.transport.read(scope: key, accountID: account)
        try checkSharedRevision(key, revision)
        let current = try remote.map { try TraktSharedGrant.decode($0.value) }
        _ = try bindSharedAccount(account, state: state, store: store, configuration: configuration)
        preparedConnections[key] = ConnectionContext(
            id: id, scope: key, revision: revision, accountID: account, expectedEpoch: current?.epoch
        )
    }

    func changeSharedConnection(
        _ tokens: TraktTokens?, store: any TraktTokenStoring,
        configuration: TraktSharedRefreshConfiguration,
        context: ConnectionContext? = nil
    ) async throws {
        let key = store.coordinationID
        let revision = revisions[key, default: 0]
        let state = try loadSharedState(key, configuration: configuration)
        // An offline disconnect is remembered against the already-bound account;
        // it must never turn into a disconnect of a future iCloud account.
        let account: String
        if tokens != nil {
            guard let preparedAccount = context?.accountID else {
                throw TraktSharedRefreshError.superseded
            }
            guard state?.accountID == preparedAccount else {
                throw TraktSharedRefreshError.accountChanged
            }
            account = preparedAccount
        } else {
            do { account = try await configuration.transport.accountID() }
            catch {
                guard let previous = state?.accountID else { throw error }
                account = previous
            }
        }
        try checkSharedRevision(key, revision)
        var journal = try bindSharedAccount(account, state: state, store: store, configuration: configuration)
        let baseline = journal.accepted
        let grant: TraktSharedGrant
        if let tokens {
            grant = .ready(tokens)
        } else {
            grant = .init(
                epoch: UUID(), generation: (baseline?.generation ?? 0) &+ 1,
                phase: .disconnected
            )
        }
        journal.pending = .init(
            kind: tokens == nil ? .disconnect : .connect,
            grant: grant,
            expectedEpoch: tokens == nil ? baseline?.epoch : context?.expectedEpoch,
            needsBaseline: tokens == nil && baseline == nil
        )
        try persistSharedState(journal, key: key, configuration: configuration)
        if tokens == nil { try store.clear() }
        _ = try await sharedAccess(
            store: store, configuration: configuration, revision: revision, exchange: nil
        )
    }

    private func retainUnspentClaim(
        journal: inout TraktSharedJournalState, key: String,
        configuration: TraktSharedRefreshConfiguration, retryNotBefore: Date?
    ) -> TraktSharedRefreshError {
        journal.pending?.kind = .claimPrepared
        journal.pending?.retryNotBefore = retryNotBefore
        // persistSharedState retains this exact recoverable state in memory if
        // Keychain is unavailable. A retry must durably write the boundary again.
        try? persistSharedState(journal, key: key, configuration: configuration)
        return .retryable(retryNotBefore: retryNotBefore)
    }

    func checkSharedRevision(_ key: String, _ revision: UInt64) throws {
        try Task.checkCancellation()
        guard revisions[key, default: 0] == revision else { throw CancellationError() }
    }

    private func loadSharedState(
        _ key: String, configuration: TraktSharedRefreshConfiguration
    ) throws -> TraktSharedJournalState? {
        if let retained = sharedJournalRecovery[key] { return retained }
        guard let data = try configuration.journal.read(scope: key) else { return nil }
        let state = try JSONDecoder().decode(TraktSharedJournalState.self, from: data)
        guard state.format == 1, !state.accountID.isEmpty else { throw TraktSharedRefreshError.invalidRecord }
        if let accepted = state.accepted { _ = try TraktSharedGrant.decode(accepted.encoded()) }
        if let pending = state.pending {
            _ = try TraktSharedGrant.decode(pending.grant.encoded())
            let expectedPhase: TraktSharedGrant.Phase
            switch pending.kind {
            case .connect, .successor: expectedPhase = .ready
            case .disconnect: expectedPhase = .disconnected
            case .claimPrepared, .exchangeStarted: expectedPhase = .refreshing
            }
            guard pending.grant.phase == expectedPhase else { throw TraktSharedRefreshError.invalidRecord }
        }
        return state
    }

    private func permitsOfflineAccess(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let shared = error as? TraktSharedRefreshError { return shared == .unavailable }
        return true
    }

    private func persistSharedState(
        _ state: TraktSharedJournalState, key: String, configuration: TraktSharedRefreshConfiguration
    ) throws {
        sharedJournalRecovery[key] = state
        do {
            try configuration.journal.write(JSONEncoder().encode(state), scope: key)
        } catch {
            if state.pending?.kind == .claimPrepared {
                throw TraktSharedRefreshError.retryable(retryNotBefore: state.pending?.retryNotBefore)
            }
            throw error
        }
        sharedJournalRecovery[key] = nil
    }

    private func bindSharedAccount(
        _ account: String, state: TraktSharedJournalState?,
        store: any TraktTokenStoring, configuration: TraktSharedRefreshConfiguration
    ) throws -> TraktSharedJournalState {
        if let state, state.accountID == account { return state }
        let fresh = TraktSharedJournalState(accountID: account)
        if state != nil {
            // Clear before rebinding. Failure leaves the old binding in place.
            try store.clear()
            try persistSharedState(fresh, key: store.coordinationID, configuration: configuration)
            throw TraktSharedRefreshError.accountChanged
        }
        try persistSharedState(fresh, key: store.coordinationID, configuration: configuration)
        return fresh
    }

    private func acceptShared(
        _ grant: TraktSharedGrant, journal: inout TraktSharedJournalState,
        store: any TraktTokenStoring, configuration: TraktSharedRefreshConfiguration
    ) throws -> String? {
        if let accepted = journal.accepted, accepted.epoch == grant.epoch,
           grant.generation < accepted.generation {
            throw TraktSharedRefreshError.superseded
        }
        // Keep pending results until the local store also succeeds. On failure,
        // the server (or the journal) still contains the only valid successor.
        if let tokens = grant.tokens {
            if store.load() != tokens { try store.save(tokens) }
        } else {
            try store.clear()
        }
        journal.accepted = grant
        journal.pending = nil
        try persistSharedState(journal, key: store.coordinationID, configuration: configuration)
        return grant.tokens?.accessToken
    }
}
