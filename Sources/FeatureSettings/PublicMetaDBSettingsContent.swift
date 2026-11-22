#if canImport(SwiftUI)
import CoreModels
import CoreUI
import PublicMetaDBService
import SwiftUI

public struct PublicMetaDBSettingsContent: View {
    private let service: PublicMetaDBService
    private let makeHistoryImport: (@MainActor () -> TrackerHistoryImportSession)?
    @Environment(SettingsSearchRequest.self) private var searchRequest: SettingsSearchRequest?
    @State private var key = ""
    @State private var showingAccount = false
    @State private var confirmingDisconnect = false
    @State private var confirmingReplacement = false
    @State private var operation: Task<Void, Never>?
    @State private var storageError: AppError?
    @State private var showingEntry = false

    public init(
        service: PublicMetaDBService, makeHistoryImport: (@MainActor () -> TrackerHistoryImportSession)? = nil
    ) {
        self.service = service
        self.makeHistoryImport = makeHistoryImport
    }

    public var body: some View {
        connectionSection {
            if !showingEntry && (service.phase != .disconnected || service.hasSavedKey) {
                PublicMetaDBConnectionStatus(phase: service.phase)
            }
            if service.phase == .connected {
                Button("Tracking settings") { showingAccount = true }
                    .settingsActionRow()
                    .accessibilityIdentifier("publicmetadb.browse")
                    .settingsSearchAnchor("publicmetadb-account", fallbackFor: Self.searchTargets)
            }
            if showingEntry {
                PublicMetaDBKeyEntryView(
                    service: service, key: $key,
                    onConnect: connectManually, onRetry: startPairing, onCancel: cancelEntry
                )
            } else {
                Button(service.hasSavedKey ? "Replace API key" : "Connect PublicMetaDB") {
                    if service.hasSavedKey { confirmingReplacement = true }
                    else { beginEntry() }
                }
                .settingsActionRow()
                .disabled(service.phase == .connecting)
                .accessibilityIdentifier("publicmetadb.pair")
                .settingsSearchAnchor(
                    service.hasSavedKey ? "publicmetadb-replace" : "publicmetadb-account",
                    fallbackFor: service.hasSavedKey ? [] : Self.searchTargets
                )
            }
            if !showingEntry, service.hasSavedKey, service.phase != .connected, service.phase != .connecting {
                Button("Retry saved connection") {
                    operation?.cancel()
                    operation = Task { await service.refreshStatus() }
                }
                .settingsActionRow()
                .settingsSearchAnchor("publicmetadb-account", fallbackFor: Self.searchTargets)
            }
            if service.hasSavedKey {
                Button("Disconnect") { confirmingDisconnect = true }
                    .settingsActionRow()
            }
        }
        .confirmationDialog("Replace this profile's PublicMetaDB API key?", isPresented: $confirmingReplacement) {
            Button("Replace API key", role: .destructive, action: beginEntry)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces the key on this profile’s synced devices. The old key stays valid on PublicMetaDB.")
        }
        .confirmationDialog("Disconnect PublicMetaDB?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                do { try service.disconnect() }
                catch { storageError = .unknown("Could not remove the saved PublicMetaDB key.") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the key from this profile’s synced devices. Your history stays intact. To revoke the key, use PublicMetaDB.")
        }
        .alert("PublicMetaDB", isPresented: Binding(
            get: { storageError != nil }, set: { if !$0 { storageError = nil } }
        )) {
            Button("OK", role: .cancel) { storageError = nil }
        } message: {
            if let storageError { Text(storageError.userMessage) }
        }
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                // A search identifies the setting, not a grant to open private account data.
                // Reveal the row only after the user opens tracking settings.
                if let target = searchRequest?.targetID, target != "publicmetadb-account", Self.searchTargets.contains(target) {
                    SettingsSearchLanding(targetID: target) { accountPage }
                } else {
                    accountPage
                }
            }
        }
        .onChange(of: service.connectionID) { _, _ in
            key = ""
            showingAccount = false
            confirmingReplacement = false
            confirmingDisconnect = false
        }
        .onChange(of: service.phase) { _, phase in
            if phase == .connected {
                key = ""
                showingEntry = false
            }
        }
        .onChange(of: service.profileNamespace) { _, _ in
            cancelEntry()
            showingAccount = false
            confirmingReplacement = false
            confirmingDisconnect = false
        }
        .onDisappear {
            cancelEntry()
        }
    }

    private var accountPage: some View {
        PublicMetaDBAccountView(service: service, makeHistoryImport: makeHistoryImport)
    }

    private static let searchTargets = SettingsSearchCatalog.targets(on: .publicMetaDB)

    @ViewBuilder private func connectionSection<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        #if os(iOS)
        SettingsSectionGroup(verbatim: "PublicMetaDB", content: rows)
        #else
        VStack(alignment: .leading, spacing: SettingsFormMetrics.controlSpacing, content: rows)
        #endif
    }

    private func beginEntry() {
        key = ""
        showingEntry = true
        #if os(tvOS)
        startPairing()
        #endif
    }

    private func startPairing() {
        operation?.cancel()
        operation = Task {
            guard !Task.isCancelled else { return }
            await service.connectUsingBrowser()
        }
    }

    private func connectManually() {
        let candidate = key
        operation?.cancel()
        operation = Task { await service.connect(key: candidate) }
    }

    private func cancelEntry() {
        let restoreStatus = showingEntry && (service.hasSavedKey || service.phase != .disconnected)
            && service.phase != .connected && service.phase != .credentialChangeFailed
        let namespace = service.profileNamespace
        operation?.cancel()
        service.browserPairing.cancel()
        showingEntry = false
        key = ""
        if restoreStatus {
            operation = Task {
                guard !Task.isCancelled, service.profileNamespace == namespace else { return }
                await service.refreshStatus()
            }
        }
    }
}

struct PublicMetaDBKeyEntryView: View {
    let service: PublicMetaDBService
    @Binding var key: String
    let onConnect: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void
    #if os(tvOS)
    @Environment(\.isEnabled) private var isEnabled
    @State private var manual = false
    private enum EntryFocus { case manualAction, key }
    @FocusState private var entryFocus: EntryFocus?
    #endif

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: SettingsFormMetrics.controlSpacing) {
            if manual {
                keyField.focused($entryFocus, equals: .key)
                statusRows
                HStack(spacing: 16) { actions }
            } else {
                websiteEntry
                HStack(spacing: 16) {
                    Button("Enter API key manually") {
                        service.switchToManualKeyEntry()
                        manual = true
                    }
                    .plozzActionButton()
                    .disabled(service.phase == .connecting)
                    .focused($entryFocus, equals: .manualAction)
                    .accessibilityIdentifier("publicmetadb.pair.manual")
                    cancelButton.plozzActionButton(role: .secondary)
                }
            }
        }
        .focusSection()
        .task(id: manual) {
            await Task.yield()
            guard !Task.isCancelled, isEnabled else { return }
            entryFocus = manual ? .key : .manualAction
        }
        #else
        keyField
        statusRows
        actions
        #endif
    }

    #if os(tvOS)
    private var websiteEntry: some View {
        let pairing = service.browserPairing
        return TrackerPhoneEntryPanel(
            instruction: pairing.challenge == nil ? nil : "Scan to enter your API key, or visit:",
            qrPayload: pairing.challenge?.url.absoluteString, website: "plozz.app/pmdb"
        ) {
            if let challenge = pairing.challenge {
                HStack {
                    Text("Pairing code").plozzForeground(.secondary)
                    Text(verbatim: challenge.displayCode)
                        .font(.headline.monospaced())
                        .accessibilityIdentifier("publicmetadb.pair.code")
                }
                .lineLimit(1)
            } else if pairing.isStarting {
                ProgressView("Loading QR code…")
            }
            statusRows
            if !pairing.isActive && service.phase != .connecting {
                Button("Try again", action: onRetry)
                    .accessibilityIdentifier("publicmetadb.pair.retry")
            }
        }
    }
    #endif

    private var keyField: some View {
        SecureField("API key", text: $key)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("publicmetadb.key")
    }

    @ViewBuilder private var statusRows: some View {
        if case .failed(let error) = service.phase { Text(error.userMessage) }
        if service.phase == .credentialChangeFailed {
            Text("Connection change failed. Retry before closing the app.")
        }
        if case .pairingFailed(let error) = service.phase {
            Text(error.userMessage).accessibilityIdentifier("publicmetadb.pair.error")
        }
        if service.phase == .connecting { ProgressView("Checking API key…") }
    }

    @ViewBuilder private var actions: some View {
        Button("Connect", action: onConnect)
            .settingsActionRow()
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.phase == .connecting)
            .accessibilityIdentifier("publicmetadb.connect")
        cancelButton
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel, action: onCancel)
            .settingsActionRow()
            .accessibilityIdentifier("publicmetadb.pair.cancel")
    }
}

struct PublicMetaDBConnectionStatus: View {
    let phase: PublicMetaDBService.Phase
    var text: Text {
        switch phase {
        case .disconnected: Text("Not connected")
        case .connecting: Text("Checking API key…")
        case .connected: Text("Connected")
        case .failed(let error): Text(error.userMessage)
        case .pairingFailed(let error): Text(error.userMessage)
        case .credentialChangeFailed: Text("Connection change failed. Retry before closing the app.")
        }
    }
    var body: some View {
        Group {
            if phase == .connected {
                TrackerConnectedStatus()
            } else {
                HStack {
                    if phase == .connecting { ProgressView() }
                    text
                }
            }
        }
        .accessibilityIdentifier("publicmetadb.status")
    }
}

#endif
