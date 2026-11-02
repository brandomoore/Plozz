import SwiftUI

/// Shared touch-target sizing and appearance for Home and detail hero actions.
public struct TouchHeroActionButtonStyle: ButtonStyle {
    public enum Kind {
        case primary
        case secondary
    }

    private let kind: Kind
    private let circular: Bool
    /// Optional emphasis for a primary action; nil keeps its natural size and wrapping fallback.
    private let minimumWidth: CGFloat?
    private let compact: Bool
    @Environment(\.themePalette) private var palette

    public init(kind: Kind, circular: Bool = false, minimumWidth: CGFloat? = nil, compact: Bool = false) {
        self.kind = kind
        self.circular = circular
        self.minimumWidth = minimumWidth
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        styledLabel(configuration)
            .contentShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 24)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styledLabel(_ configuration: Configuration) -> some View {
        if circular {
            configuration.label
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(kind == .primary ? palette.backgroundBase : palette.primaryText)
                .frame(width: compact ? 44 : 48, height: compact ? 44 : 48)
                .background {
                    Circle()
                        .fill(backgroundColor)
                        .overlay {
                            if kind == .secondary {
                                Circle().strokeBorder(palette.primaryText.opacity(0.2), lineWidth: 1)
                            }
                        }
                }
        } else {
            configuration.label
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .font((compact ? Font.subheadline : .headline).weight(.semibold))
                .foregroundStyle(kind == .primary ? palette.backgroundBase : palette.primaryText)
                .padding(.horizontal, compact ? 16 : 20)
                .padding(.vertical, compact ? 10 : 12)
                .frame(minWidth: minimumWidth, minHeight: compact ? 44 : 48)
                .background {
                    // Bounded corners keep multiline and accessibility-size text
                    // inside the surface instead of turning tall buttons into ovals.
                    RoundedRectangle(cornerRadius: 24)
                        .fill(backgroundColor)
                        .overlay {
                            if kind == .secondary {
                                RoundedRectangle(cornerRadius: 24)
                                    .strokeBorder(palette.primaryText.opacity(0.2), lineWidth: 1)
                            }
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: 24))
        }
    }

    private var backgroundColor: Color {
        kind == .primary ? palette.primaryText : palette.cardSurface.opacity(0.92)
    }
}
