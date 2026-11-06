#if os(iOS)
import SwiftUI
import CoreModels
import CoreUI
import Network
import Observation

@MainActor
@Observable
final class PlozziOSOfflineModeModel {
    enum Notice: Equatable {
        case offlineMode
        case noNetwork

        var title: LocalizedStringResource {
            switch self {
            case .offlineMode: "Offline Mode"
            case .noNetwork: "No Network Connection"
            }
        }
    }

    var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled {
                dismissedNotice = nil
                announcedNotice = nil
            }
        }
    }
    var isChanging = false
    var generation = 0
    private(set) var hasNetworkConnection: Bool?
    private var dismissedNotice: Notice?
    @ObservationIgnored private var announcedNotice: Notice?
    @ObservationIgnored private let networkMonitor: NWPathMonitor?

    private var currentNotice: Notice? {
        isEnabled ? .offlineMode : (hasNetworkConnection == false ? .noNetwork : nil)
    }

    var notice: Notice? {
        currentNotice == dismissedNotice ? nil : currentNotice
    }

    init(isEnabled: Bool, monitorsConnectivity: Bool = true) {
        self.isEnabled = isEnabled
        let monitor = monitorsConnectivity ? NWPathMonitor() : nil
        networkMonitor = monitor
        monitor?.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in self?.updateNetworkConnection(connected) }
        }
        monitor?.start(queue: DispatchQueue(label: "com.plozz.offline-status"))
    }

    deinit { networkMonitor?.cancel() }

    func updateNetworkConnection(_ connected: Bool) {
        let previous = currentNotice
        hasNetworkConnection = connected
        if currentNotice != previous {
            dismissedNotice = nil
            announcedNotice = nil
        }
    }

    func dismissNotice() { dismissedNotice = currentNotice }

    func announceNoticeIfNeeded() {
        guard let notice, notice != announcedNotice else { return }
        announcedNotice = notice
        AccessibilityNotification.Announcement(
            String(localized: notice.title) // l10n:content — resolved for an immediate spoken announcement
        ).post()
    }
}

struct PlozziOSOfflineModeToggle: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { appModel.isOfflineMode },
            set: { enabled in Task { await appModel.setOfflineMode(enabled) } }
        )) {
            Label("Offline Mode", systemImage: "wifi.slash")
        }
        .disabled(appModel.isChangingOfflineMode)
        .accessibilityHint("Show downloaded content without using the network.")
        .accessibilityIdentifier("offline-mode-toggle")
    }
}

extension View {
    func offlineStatusOverlay(
        appModel: PlozziOSAppModel, palette: ThemePalette, isEnabled: Bool = true
    ) -> some View {
        modifier(PlozziOSOfflineStatusOverlay(appModel: appModel, palette: palette, isEnabled: isEnabled))
    }
}

private struct PlozziOSOfflineStatusOverlay: ViewModifier {
    let appModel: PlozziOSAppModel
    let palette: ThemePalette
    let isEnabled: Bool

    private var notice: PlozziOSOfflineModeModel.Notice? {
        guard isEnabled, appModel.isOfflineModeAvailable, appModel.transientStatusPresenter.message == nil,
              appModel.guidePreparation.notificationStatus == nil else { return nil }
        return appModel.offlineMode.notice
    }

    func body(content: Content) -> some View {
        content.adaptiveStatusOverlay(isPresented: notice != nil) {
            if let notice {
                PlozziOSOfflineStatusNotice(notice: notice, palette: palette) {
                    appModel.offlineMode.dismissNotice()
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
            }
        }
        .onChange(of: notice, initial: true) { _, notice in
            if notice != nil { appModel.offlineMode.announceNoticeIfNeeded() }
        }
    }
}

struct PlozziOSOfflineStatusNotice: View {
    let notice: PlozziOSOfflineModeModel.Notice
    let palette: ThemePalette
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label { Text(notice.title) } icon: { Image(systemName: "wifi.slash") }
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("offline-status-dismiss")
        }
        .font(.subheadline)
        .foregroundStyle(palette.primaryText)
        .tint(palette.primaryText)
        .transientStatusSurface(palette: palette, style: .compact)
        .accessibilityIdentifier("offline-status")
    }
}

struct PlozziOSOfflineUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Unavailable Offline",
            systemImage: "wifi.slash",
            description: Text("Turn off Offline Mode to connect.")
        )
    }
}
#endif
