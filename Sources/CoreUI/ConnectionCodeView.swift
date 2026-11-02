#if canImport(SwiftUI)
import SwiftUI

/// The same readable code surface for server sign-in and device setup.
public struct ConnectionCodeView: View {
    @Environment(\.themePalette) private var palette
    @ScaledMetric private var size: CGFloat
    private let code: String
    private let baseSize: CGFloat

    public init(_ code: String, size: CGFloat? = nil) {
        self.code = code
        #if os(tvOS)
        baseSize = size ?? 88
        #else
        baseSize = size ?? 44
        #endif
        _size = ScaledMetric(wrappedValue: baseSize, relativeTo: .largeTitle)
    }

    public var body: some View {
        Text(verbatim: code)
            .font(.plozzCode(size: size))
            .tracking(baseSize / 12)
            .lineLimit(1)
            .minimumScaleFactor(0.25)
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, baseSize / 2)
            .padding(.vertical, baseSize / 4)
            #if os(iOS)
            .settingsGroupSurface(cornerRadius: PlozzTheme.Metrics.Radius.panel)
            #else
            .background {
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.panel)
                    .fill(palette.cardSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.panel)
                            .fill(.black.opacity(palette.isLight ? 0.06 : 0.26))
                    }
            }
            #endif
            .accessibilityIdentifier("connection-code")
    }
}

public struct SetupCodeComparisonView: View {
    private let code: String
    private let onResult: ((Bool) -> Void)?

    public init(code: String, onResult: ((Bool) -> Void)? = nil) {
        self.code = code
        self.onResult = onResult
    }

    public var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 40))
                .plozzForeground(.primary)
                .accessibilityHidden(true)
            OnboardingHeader(
                Text("Check the code"),
                subtitle: Text("Make sure both devices show the same code.")
            )
            ConnectionCodeView(code)
            if let onResult {
                #if os(tvOS)
                let layout = AnyLayout(HStackLayout(spacing: 24))
                #else
                let layout = AnyLayout(VStackLayout(spacing: 16))
                #endif
                layout {
                    Button("Yes, they match") { onResult(true) }
                        .plozzActionButton()
                    Button("No, they're different", role: .cancel) { onResult(false) }
                        .plozzActionButton(role: .secondary)
                }
            } else {
                Text("Confirm on your other device.")
                    .font(.callout).plozzForeground(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }
}
#endif
