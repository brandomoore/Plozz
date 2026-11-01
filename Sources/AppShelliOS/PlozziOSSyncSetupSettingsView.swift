#if os(iOS)
import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI
import FeatureSyncSetup

/// Dedicated Sync & Setup settings page. The device-setup flow lives directly on
/// this page (no extra tap): opening it starts discovering nearby devices to pair.
@MainActor
struct PlozziOSSyncSetupSettingsView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    @State private var model: SyncSetupPairingModel
    @State private var showScanner = false
    @State private var showCodeEntry = false
    @State private var showReceive = false
    @State private var scannedSourceInvite: SyncSetupSourceInvite?
    @State private var serverToReceive: SyncedAccountDescriptor?
    @State private var serverToSignIn: SyncedAccountDescriptor?
    @State private var serverPrompt: SyncedAccountDescriptor?
    @State private var serverPromptFollowUp: ServerPromptFollowUp?
    @State private var showAddShare = false
    @State private var handled = false

    init(appModel: PlozziOSAppModel) {
        self.appModel = appModel
        _model = State(initialValue: appModel.makeSyncSetupSender())
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                idleList
            case .connecting, .sending:
                centered {
                    ProgressView().controlSize(.large)
                    Text("Setting up your device…").font(.headline).plozzForeground(.secondary)
                }
            case .sent:
                successView
            case .confirmingSAS(let code):
                sasConfirm(code)
            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60)).foregroundStyle(.orange)
                    Text("Setup didn’t finish").font(.title3.bold())
                    Text(message).plozzForeground(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Button("Try Again") { handled = false; model.reset(); model.startDiscovery() }
                        .syncPrimaryButtonStyle()
                }
            default:
                centered { ProgressView() }
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if case .idle = model.phase { model.startDiscovery() } }
        .onChange(of: model.canSend, initial: true) { _, _ in model.authorizationDidChange() }
        .onDisappear {
            model.stopDiscovery()
            model.cancelSending()
        }
        .plozzFullScreenCover(isPresented: $showReceive) {
            PlozziOSSyncSetupReceiveView(appModel: appModel, sourceInvite: scannedSourceInvite) {
                showReceive = false
            }
        }
        .plozzFullScreenCover(item: $serverToReceive) { server in
            PlozziOSSyncSetupReceiveView(appModel: appModel, requestedServer: server) {
                serverToReceive = nil
            }
        }
        .plozzSheet(item: $serverPrompt, onDismiss: consumeServerPromptFollowUp) { server in
            SyncedServerSetupPrompt(
                descriptor: server, palette: palette,
                onSignIn: {
                    serverPromptFollowUp = .signIn(server)
                    serverPrompt = nil
                },
                onUseOtherDevice: {
                    serverPromptFollowUp = .pairDevice(server)
                    serverPrompt = nil
                },
                onNotNow: {
                    serverPromptFollowUp = nil
                    serverPrompt = nil
                }
            )
        }
        .plozzFullScreenCover(isPresented: $showAddShare, onDismiss: appModel.refreshPendingSyncedServers) {
            PlozziOSUnifiedAddShareView(appModel: appModel)
        }
        .plozzSheet(item: $serverToSignIn, onDismiss: {
            appModel.finishManagedServerPresentation()
            appModel.refreshPendingSyncedServers()
        }) { server in
            AddServerView(
                appModel: appModel,
                initialProvider: server.provider,
                initialAddress: server.candidateBaseURLs.first?.absoluteString ?? ""
            )
            .presentationSizing(.page)
        }
        .plozzFullScreenCover(isPresented: $showScanner, onDismiss: {
            if scannedSourceInvite != nil { showReceive = true }
        }) {
            SyncSetupScannerScreen(
                onCode: { code in
                    if let invite = SyncSetupSourceInvite.decode(code) {
                        scannedSourceInvite = invite
                        showScanner = false
                        return
                    }
                    showScanner = false
                    guard !handled else { return }
                    handled = true
                    Task { await model.send(inviteString: code) }
                },
                onCancel: { showScanner = false }
            )
        }
        .plozzSheet(isPresented: $showCodeEntry) {
            SyncSetupCodeEntryScreen(
                onSubmit: { code in
                    showCodeEntry = false
                    guard !handled else { return }
                    handled = true
                    Task { await model.send(code: code) }
                },
                onCancel: { showCodeEntry = false }
            )
        }
    }

    // MARK: Success

    @ViewBuilder
    private func sasConfirm(_ code: String) -> some View {
        SyncSetupSASConfirmView(code: code) { model.confirmSASMatch($0) }
    }

    private var successView: some View {
        SyncSetupSentSuccessView(
            accounts: appModel.accounts,
            profiles: appModel.profiles.profiles,
            onDone: {
                handled = false
                model.reset()
                model.startDiscovery()
            }
        )
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 16) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    // MARK: Idle list

    private var idleList: some View {
        SettingsPageList {
            SettingsSectionGroup {
                Toggle(isOn: Binding(
                    get: { appModel.syncSetup.isEnabled },
                    set: { appModel.setSyncSetupEnabled($0) }
                )) {
                    Label("iCloud Sync", systemImage: "icloud")
                }
                .disabled(appModel.cloudSyncStatus.isRecovering).settingsSearchAnchor("icloud-sync")
                if appModel.syncSetup.isEnabled {
                    HStack {
                        SyncStatusLine(provider: syncStatusProvider)
                            .font(.footnote)
                            .plozzForeground(.secondary)
                        Spacer()
                        Button("Sync Now") { appModel.syncCloudNow() }
                            .font(.footnote.weight(.semibold))
                            .disabled(appModel.cloudSyncStatus.isRecovering)
                    }
                }
            } footer: {
                Text("Syncs profiles, settings, and servers. Logins stay on each device.")
            }

            SettingsSectionGroup("Set Up Another Device") {
                if model.nearbyDevices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for nearby devices…")
                            .plozzForeground(.secondary)
                    }
                } else {
                    ForEach(model.nearbyDevices) { device in
                        Button {
                            guard !handled else { return }
                            handled = true
                            Task { await model.pair(with: device) }
                        } label: {
                            HStack {
                                Image(systemName: "tv").font(.title3)
                                VStack(alignment: .leading) {
                                    Text(device.displayName).fontWeight(.semibold)
                                    Text("Code \(SyncPairingCode.grouped(device.serviceName))")
                                        .font(.footnote).plozzForeground(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward").plozzForeground(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { scannedSourceInvite = nil; showScanner = true } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                Button { showCodeEntry = true } label: {
                    Label("Enter Code", systemImage: "keyboard")
                }
            } footer: {
                Text("Choose a nearby device, or scan its code.")
            }

            SettingsSectionGroup("This Device") {
                Button { scannedSourceInvite = nil; showReceive = true } label: {
                    Label("Set Up From Another Device", systemImage: "qrcode")
                }
            }

            if !appModel.pendingSyncedServers.isEmpty {
                SettingsSectionGroup("Servers to Set Up") {
                    ForEach(appModel.pendingSyncedServers, id: \.id) { server in
                        HStack(spacing: 12) {
                            Button {
                                serverPrompt = server
                            } label: {
                                HStack(spacing: 12) {
                                    ProviderBrandMark(
                                        provider: server.provider, size: 32,
                                        mediaShareTransport: server.mediaShareTransportKind
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.serverName).fontWeight(.medium)
                                        Text("Needs sign-in")
                                            .font(.footnote)
                                            .plozzForeground(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.forward")
                                        .font(.footnote.weight(.semibold))
                                        .plozzForeground(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pending-server-setup-\(server.id)")
                            Button("Ignore") {
                                appModel.ignorePendingSyncedServer(server.id)
                            }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            SettingsSectionGroup {
                NavigationLink {
                    PlozziOSSyncTroubleshootingView(appModel: appModel)
                } label: {
                    Label(
                        "Troubleshooting",
                        systemImage: "wrench.and.screwdriver"
                    )
                }
            }
        }
    }

    private func consumeServerPromptFollowUp() {
        guard let followUp = serverPromptFollowUp else { return }
        serverPromptFollowUp = nil
        switch followUp {
        case .pairDevice(let server):
            serverToReceive = server
        case .signIn(let server):
            if server.provider == .mediaShare {
                showAddShare = true
            } else {
                appModel.beginManagedServerPresentation()
                serverToSignIn = server
            }
        }
    }

    private var syncStatusProvider: SyncStatusProvider {
        SyncStatusProvider(inventory: {
            guard let sync = appModel.cloudSync else { throw CocoaError(.featureUnsupported) }
            return try await sync.dataInventory()
        }) {
            SyncStatusPresentation(
                summary: appModel.cloudSyncStatus.summary,
                isSyncing: appModel.cloudSyncStatus.phase == .syncing,
                itemCount: appModel.cloudSyncStatus.syncedRecordCount,
                accountTag: appModel.cloudSyncStatus.accountTag,
                isRecovering: appModel.cloudSyncStatus.isRecovering
            )
        }
    }
}

private struct PlozziOSSyncTroubleshootingView: View {
    let appModel: PlozziOSAppModel
    @State private var showResetConfirm = false
    @State private var showErasureReview = false

    var body: some View {
        SettingsPageList {
            SettingsSectionGroup("Compare Devices") {
                LabeledContent("iCloud items") {
                    Text(verbatim: appModel.cloudSyncStatus.syncedRecordCount?.formatted() ?? "—")
                }
                LabeledContent("iCloud account") {
                    Text(
                        verbatim: appModel.cloudSyncStatus.accountTag.map {
                            "\($0)…"
                        } ?? "—"
                    )
                }
            } footer: {
                Text("These should match on every device.")
            }

            SyncDataBreakdown(provider: statusProvider)

            SettingsSectionGroup("Recovery") {
                SyncRecoveryWarning()
                Button {
                    appModel.redownloadCloudSync()
                } label: {
                    Label("Reload From iCloud", systemImage: "arrow.down.circle")
                }
                .disabled(appModel.cloudSyncStatus.isRecovering || !appModel.syncSetup.isEnabled)
                .accessibilityIdentifier("cloud-sync-reload")
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset Sync", systemImage: "arrow.counterclockwise.icloud")
                }
                .disabled(appModel.cloudSyncStatus.isRecovering || !appModel.syncSetup.isEnabled)
            }
            LiveTVPortableSyncPendingSettings()
            if !appModel.profiles.activeProfile.isKids, !appModel.managementRequiresParentalPIN {
                SettingsSectionGroup {
                    Button { showErasureReview = true } label: {
                        Label("Erase Sync Data", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(appModel.cloudSyncStatus.isRecovering)
                    .accessibilityIdentifier("cloud-sync-erase")
                }
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
        .plozzSheet(isPresented: $showErasureReview) {
            SyncEraseDataView(
                profileID: appModel.profiles.activeProfileID,
                isAllowed: !appModel.profiles.activeProfile.isKids && !appModel.managementRequiresParentalPIN,
                status: statusProvider,
                erase: { appModel.eraseCloudSyncData() }
            )
        }
        .confirmationDialog(
            "Reset synced data?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset & Re-upload From This Device", role: .destructive) {
                appModel.resetCloudSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces iCloud data with this device’s copy. Other devices keep their logins.")
        }
    }

    private var statusProvider: SyncStatusProvider {
        SyncStatusProvider(inventory: {
            guard let sync = appModel.cloudSync else { throw CocoaError(.featureUnsupported) }
            return try await sync.dataInventory()
        }) {
            SyncStatusPresentation(
                summary: appModel.cloudSyncStatus.summary,
                isSyncing: appModel.cloudSyncStatus.phase == .syncing,
                accountTag: appModel.cloudSyncStatus.accountTag,
                isRecovering: appModel.cloudSyncStatus.isRecovering
            )
        }
    }
}
#endif
