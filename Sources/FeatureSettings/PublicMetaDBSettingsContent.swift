#if canImport(SwiftUI)
import CoreModels
import CoreUI
import PublicMetaDBService
import SwiftUI

public struct PublicMetaDBSettingsContent: View {
    private let service: PublicMetaDBService
    private let makeHistoryImport: (@MainActor () -> TrackerHistoryImportSession)?
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
        VStack(alignment: .leading, spacing: SettingsFormMetrics.controlSpacing) {
            if !showingEntry {
                PublicMetaDBConnectionStatus(phase: service.phase)
            }
            if service.phase == .connected {
                Button("Browse PublicMetaDB") { showingAccount = true }
                    .accessibilityIdentifier("publicmetadb.browse")
            }
            if showingEntry {
                PublicMetaDBKeyEntryView(
                    service: service, key: $key,
                    onConnect: connectManually, onRetry: startPairing, onCancel: cancelEntry
                )
            } else {
                Button(service.hasSavedKey ? "Replace API key" : "Enter API key") {
                    if service.hasSavedKey { confirmingReplacement = true }
                    else { beginEntry() }
                }
                .disabled(service.phase == .connecting)
                .accessibilityIdentifier("publicmetadb.pair")
            }
            if !showingEntry, service.hasSavedKey, service.phase != .connected, service.phase != .connecting {
                Button("Retry saved connection") {
                    operation?.cancel()
                    operation = Task { await service.refreshStatus() }
                }
            }
            if service.hasSavedKey {
                Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
            }
        }
        .confirmationDialog("Replace this profile's PublicMetaDB API key?", isPresented: $confirmingReplacement) {
            Button("Replace API key", role: .destructive, action: beginEntry)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The replacement applies to this profile on your synced Plozz devices. It does not revoke the previous key on PublicMetaDB.")
        }
        .confirmationDialog("Disconnect PublicMetaDB?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                do { try service.disconnect() }
                catch { storageError = .unknown("Could not remove the saved PublicMetaDB key.") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this profile's saved key from your synced Plozz devices. Your PublicMetaDB records and media-server history are not deleted. Revoke the key on the website if needed.")
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
                PublicMetaDBAccountView(service: service, makeHistoryImport: makeHistoryImport)
            }
            .environment(\.publicMetaDBCatalogService, service)
        }
        .onChange(of: service.catalogNavigation?.id) { _, request in
            if request != nil { showingAccount = false }
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

    private func beginEntry() {
        key = ""
        showingEntry = true
        startPairing()
    }

    private func startPairing() {
        operation?.cancel()
        operation = Task { await service.connectUsingBrowser() }
    }

    private func connectManually() {
        let candidate = key
        operation?.cancel()
        operation = Task { await service.connect(key: candidate) }
    }

    private func cancelEntry() {
        operation?.cancel()
        service.browserPairing.cancel()
        showingEntry = false
        key = ""
    }
}

struct PublicMetaDBKeyEntryView: View {
    let service: PublicMetaDBService
    @Binding var key: String
    let onConnect: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        layout {
            PublicMetaDBBrowserEntryView(
                pairing: service.browserPairing,
                isVerifying: service.phase == .connecting, onRetry: onRetry
            )
            VStack(alignment: .leading, spacing: 16) {
                SecureField("API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("publicmetadb.key")
                if case .failed(let error) = service.phase {
                    Text(error.userMessage)
                }
                if case .pairingFailed(let error) = service.phase {
                    Text(error.userMessage)
                        .accessibilityIdentifier("publicmetadb.pair.error")
                }
                if service.phase == .connecting {
                    ProgressView("Checking API key…")
                }
                HStack(spacing: 16) {
                    Button("Connect", action: onConnect)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.phase == .connecting)
                        .accessibilityIdentifier("publicmetadb.connect")
                    Button("Cancel", role: .cancel, action: onCancel)
                        .accessibilityIdentifier("publicmetadb.pair.cancel")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var layout: AnyLayout {
        #if os(tvOS)
        AnyLayout(HStackLayout(alignment: .top, spacing: 32))
        #else
        AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        #endif
    }
}

private struct PublicMetaDBBrowserEntryView: View {
    let pairing: PublicMetaDBBrowserPairing
    let isVerifying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let challenge = pairing.challenge {
                #if os(tvOS)
                SettingsQRCode(string: challenge.url.absoluteString, centerMark: nil)
                    .frame(width: 260, height: 260)
                    .accessibilityLabel("Enter your API key in a browser")
                Text("plozz.app/publicmetadb")
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                #else
                Link("Enter API key in a browser", destination: challenge.url)
                Text("On another device, visit plozz.app/publicmetadb.")
                    .font(.callout)
                #endif
                Text("Pairing code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: challenge.displayCode)
                    .font(.title3.monospaced())
                    #if os(tvOS)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    #endif
                    .accessibilityIdentifier("publicmetadb.pair.code")
            } else if pairing.isStarting {
                ProgressView("Loading QR code…")
            } else if !isVerifying {
                Button("Try again", action: onRetry)
                    .accessibilityIdentifier("publicmetadb.pair.retry")
            }
        }
        #if os(tvOS)
        .frame(width: 260, alignment: .leading)
        #endif
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
        }
    }
    var body: some View {
        HStack {
            if phase == .connecting { ProgressView() }
            text
        }
        .accessibilityIdentifier("publicmetadb.status")
    }
}

#endif
