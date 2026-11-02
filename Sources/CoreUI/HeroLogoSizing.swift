import CoreGraphics
import CoreModels

/// Shared by real heroes and their Settings preview. Size never changes image identity.
public enum HeroLogoSizing {
    public enum Surface: Sendable {
        case home, showcase, detail
    }

    public enum Layout: Sendable {
        case television, showcase, compact, regular, desktop

        public var budget: CGSize {
            switch self {
            case .television: CGSize(width: 496, height: 160)
            case .showcase: CGSize(width: 440, height: 124)
            case .compact: CGSize(width: 330, height: 95)
            case .regular: CGSize(width: 480, height: 130)
            case .desktop: CGSize(width: 320, height: 90)
            }
        }

        public var constrainsToBounds: Bool { self == .showcase }
    }

    public static func box(
        for layout: Layout,
        size: HeroLogoSize = .default,
        availableWidth: CGFloat = .infinity
    ) -> CGSize {
        let budget = layout.budget
        let base = layout.constrainsToBounds
            ? budget
            : HeroLogoFit.pinnedBox(budget: budget, drawnWidth: budget.width)
        let scale = CGFloat(size.scale)
        let widthFlex: CGFloat = layout.constrainsToBounds ? 1 : HeroLogoFit.widthFlex
        let heightFlex: CGFloat = layout.constrainsToBounds ? 1 : HeroLogoFit.heightFlex
        let maximumHeight: CGFloat = switch layout {
        case .television: 360
        case .showcase: 186
        case .compact: 240
        case .regular: 330
        case .desktop: 220
        }
        return CGSize(
            width: min(base.width * scale, max(1, availableWidth) / widthFlex),
            height: min(base.height * scale, maximumHeight / heightFlex)
        )
    }

    /// Home copy shares the logo's allowed width, without narrowing existing copy for smaller logos.
    public static func homeTextWidth(
        for layout: Layout,
        logoSize: HeroLogoSize = .default,
        minimumWidth: CGFloat = 0,
        availableWidth: CGFloat = .infinity
    ) -> CGFloat {
        min(
            max(1, availableWidth),
            max(minimumWidth, layout.budget.width * max(1, CGFloat(logoSize.scale)))
        )
    }
}
