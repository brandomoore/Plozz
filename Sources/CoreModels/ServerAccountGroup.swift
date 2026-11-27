import Foundation

public struct ServerAccountGroup: Sendable {
    public let serverKey: String
    public let serverName: String
    public let providerKind: ProviderKind
    public let accounts: [Account]

    public init(
        serverKey: String,
        serverName: String,
        providerKind: ProviderKind,
        accounts: [Account]
    ) {
        self.serverKey = serverKey
        self.serverName = serverName
        self.providerKind = providerKind
        self.accounts = accounts
    }

    public var transportKind: MediaShareTransportKind? {
        guard providerKind == .mediaShare else { return nil }
        return MediaShareTransportKind(
            mediaShareScheme: accounts.first?.server.baseURL.scheme
        )
    }
}

public func serverGroups(from accounts: [Account]) -> [ServerAccountGroup] {
    groupedAccounts(accounts, key: serverKey(for:), name: { $0.server.name })
}

/// Display grouping only. Connection management and profile mutations still
/// address individual roots. Never compare credential revisions or secrets here.
public func libraryPickerGroups(from accounts: [Account]) -> [ServerAccountGroup] {
    func endpoint(_ account: Account) -> String? {
        let url = account.server.baseURL
        guard account.server.provider == .mediaShare, url.scheme?.lowercased() == "smb",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return url.port.map { $0 == 445 ? host : "\(host):\($0)" } ?? host
    }
    return groupedAccounts(accounts, key: { account in
        guard let host = endpoint(account) else { return serverKey(for: account) }
        // Guest sessions have an empty username, distinct from a named "guest".
        return [host, account.userID, account.userName].reduce("smb-picker:") {
            $0 + "\($1.utf8.count):\($1)"
        }
    }, name: { endpoint($0) ?? $0.server.name })
}

private func groupedAccounts(_ accounts: [Account], key: (Account) -> String,
                             name: (Account) -> String) -> [ServerAccountGroup] {
    var order: [String] = []
    var grouped: [String: ServerAccountGroup] = [:]

    for account in accounts {
        let key = key(account)
        if grouped[key] == nil {
            order.append(key)
            grouped[key] = ServerAccountGroup(
                serverKey: key,
                serverName: name(account),
                providerKind: account.server.provider,
                accounts: []
            )
        }

        guard let current = grouped[key] else { continue }
        grouped[key] = ServerAccountGroup(
            serverKey: current.serverKey,
            serverName: current.serverName,
            providerKind: current.providerKind,
            accounts: current.accounts + [account]
        )
    }

    return order.compactMap { grouped[$0] }
}

public func serverKey(for account: Account) -> String {
    let url = account.server.baseURL
    let host = url.host?.lowercased() ?? url.absoluteString

    if account.server.provider == .mediaShare {
        let scheme = (url.scheme ?? "").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(account.server.provider.rawValue)|\(scheme)://\(host)\(port)\(path)"
    }

    return "\(account.server.provider.rawValue)|\(host)"
}
