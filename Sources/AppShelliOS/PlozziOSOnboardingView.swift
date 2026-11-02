#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

/// iOS/iPadOS first-run onboarding — mirrors the tvOS entry: the branded Plozz
/// logo + "Free forever and open source." tagline, a direct provider chooser
/// and a "Set up from another device" button.
@MainActor
struct PlozziOSOnboardingView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    @State private var addProvider: OnboardingProvider?
    @State private var showReceive = false
    @State private var showAddShare = false

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 32) {
                        Spacer(minLength: geo.size.height * 0.08)
                        header
                        providerList
                        receiveButton
                        Spacer(minLength: 32)
                    }
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        .plozzFullScreenCover(item: $addProvider) { wrapped in
            AddServerView(appModel: appModel, initialProvider: wrapped.kind)
        }
        .plozzFullScreenCover(isPresented: $showReceive) {
            PlozziOSSyncSetupReceiveView(appModel: appModel) { showReceive = false }
        }
        .plozzFullScreenCover(isPresented: $showAddShare) {
            PlozziOSUnifiedAddShareView(appModel: appModel)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("PlozzLogo")
                .resizable().scaledToFit()
                .frame(width: 88, height: 88)
            Image("PlozzWordmark")
                .resizable().scaledToFit()
                .frame(height: 38)
                .foregroundStyle(palette.primaryText)
            Text("Free forever and open source.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var providerList: some View {
        ServerProviderChoices { provider in
            if provider == .mediaShare {
                showAddShare = true
            } else {
                addProvider = OnboardingProvider(kind: provider)
            }
        }
    }

    private var receiveButton: some View {
        Button {
            showReceive = true
        } label: {
            Label("Set Up from Another Device", systemImage: "qrcode")
                .plozzPageActionLabel()
        }
        .plozzPageActionButton(role: .secondary)
        .controlSize(.large)
        .tint(palette.accent)
    }
}

/// Identifiable wrapper so a chosen provider can drive `.fullScreenCover(item:)`.
private struct OnboardingProvider: Identifiable {
    let kind: ProviderKind
    var id: String { kind.rawValue }
}
#endif
