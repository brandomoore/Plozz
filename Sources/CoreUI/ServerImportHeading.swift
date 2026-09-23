#if canImport(SwiftUI)
import SwiftUI

public struct ServerImportHeading: View {
    public enum Content {
        case server, servers, account, accounts, setup

        public var primaryAction: LocalizedStringResource {
            switch self {
            case .server: "Import server"
            case .servers: "Import servers"
            case .account: "Import account"
            case .accounts: "Import accounts"
            case .setup: "Import setup"
            }
        }
    }

    @Environment(\.themePalette) private var palette
    private let content: Content
    private let deviceName: String?
    private let deviceIcon: String

    public init(content: Content, deviceName: String?, deviceIcon: String) {
        self.content = content
        self.deviceName = deviceName
        self.deviceIcon = deviceIcon
    }

    public var body: some View {
        heading(device: emphasizedDevice)
            .font(.title2.weight(.semibold))
            .foregroundStyle(palette.primaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(heading(device: deviceName.map { Text(verbatim: $0) }))
    }

    private var emphasizedDevice: Text? {
        guard let deviceName else { return nil }
        // Only icon/spacing and user content are composed here; the surrounding
        // sentence remains one localizable interpolation.
        return (Text(Image(systemName: deviceIcon)) + Text(verbatim: "\u{00a0}" + deviceName))
            .foregroundColor(palette.primaryText.opacity(0.85))
            .fontWeight(.bold)
    }

    private func heading(device: Text?) -> Text {
        if let device {
            switch content {
            case .server: return Text("Import your server from \(device)?")
            case .servers: return Text("Import your servers from \(device)?")
            case .account: return Text("Import your account from \(device)?")
            case .accounts: return Text("Import your accounts from \(device)?")
            case .setup: return Text("Import your setup from \(device)?")
            }
        }
        switch content {
        case .server: return Text("Import your server from another device?")
        case .servers: return Text("Import your servers from another device?")
        case .account: return Text("Import your account from another device?")
        case .accounts: return Text("Import your accounts from another device?")
        case .setup: return Text("Import your setup from another device?")
        }
    }
}
#endif
