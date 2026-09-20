#if os(tvOS)
import CoreModels
import CoreNetworking
import SwiftUI
import TVUIKit
import UIKit

@MainActor
protocol NativeGridFocusContainer: AnyObject {
    var isMediaFocused: Bool { get }
}

/// A native, non-focus-owning presentation. The enclosing SwiftUI cell owns
/// directional input so recycling an offscreen TVLockupView cannot end a hold.
struct NativeTVGridCard<Content: View>: UIViewRepresentable {
    let content: Content
    let isFocused: Bool

    func makeUIView(context: Context) -> Container {
        let hosting = hostingConfiguration(context).makeContentView()
        return Container(hosting: hosting)
    }

    func updateUIView(_ view: Container, context: Context) {
        view.isMediaFocused = isFocused
        view.hosting.configuration = hostingConfiguration(context)
        let color = UIColor(context.environment.themePalette.raised.fill)
        if view.backgroundColorValue != color {
            view.backgroundColorValue = color
            view.image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image {
                color.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
        var configuration = TVMediaItemContentConfiguration.wideCell()
        configuration.image = view.image
        configuration.overlayView = view.hosting
        var state = UICellConfigurationState(traitCollection: view.traitCollection)
        state.isFocused = isFocused
        view.media.configuration = configuration.updated(for: state)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let height = proposal.height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let size = uiView.hosting.systemLayoutSizeFitting(
            CGSize(width: width ?? 0, height: height ?? 0),
            withHorizontalFittingPriority: width == nil ? .fittingSizeLevel : .required,
            verticalFittingPriority: height == nil ? .fittingSizeLevel : .required
        )
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height >= 0 else {
            PlozzLog.app.error("Native grid content returned invalid fitting dimensions")
            return nil
        }
        return CGSize(width: width ?? size.width, height: size.height)
    }

    private func hostingConfiguration(_ context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            content
                .environment(\.self, context.environment)
                .environment(\.plozzNativeFocusSurface, true)
        }.margins(.all, 0)
    }

    final class Container: UIView, NativeGridFocusContainer {
        let hosting: UIView & UIContentView
        let media: TVMediaItemContentView
        var image: UIImage?
        var backgroundColorValue: UIColor?
        var isMediaFocused = false

        init(hosting: UIView & UIContentView) {
            self.hosting = hosting
            let configuration = TVMediaItemContentConfiguration.wideCell()
            guard let media = configuration.makeContentView() as? TVMediaItemContentView else {
                preconditionFailure("TVUIKit did not create its media content view")
            }
            self.media = media
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            addSubview(media)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            media.frame = bounds
        }
    }
}

struct NativeTVGridPoster<Overlay: View>: UIViewRepresentable {
    let image: UIImage?
    let aspectRatio: CGFloat
    let fallbackWidth: CGFloat
    let overlay: Overlay
    let isFocused: Bool
    let source: DetailTransitionSourceReference

    func makeUIView(context: Context) -> Container {
        Container(aspectRatio: aspectRatio, fallbackWidth: fallbackWidth,
                  hosting: hostingConfiguration(context).makeContentView())
    }

    func updateUIView(_ view: Container, context: Context) {
        view.aspectRatio = aspectRatio
        view.isMediaFocused = isFocused
        view.hosting.configuration = hostingConfiguration(context)
        var configuration = TVMediaItemContentConfiguration.wideCell()
        configuration.image = image ?? view.placeholder
        configuration.overlayView = view.hosting
        var state = UICellConfigurationState(traitCollection: view.traitCollection)
        state.isFocused = isFocused
        view.media.configuration = configuration.updated(for: state)
        source.nativeArtworkView = view.media
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? fallbackWidth
        return CGSize(width: width, height: width / aspectRatio + uiView.verticalClearance)
    }

    private func hostingConfiguration(_ context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            overlay
                .environment(\.self, context.environment)
                .environment(\.plozzNativeFocusSurface, true)
        }.margins(.all, 0)
    }

    final class Container: UIView, NativeGridFocusContainer {
        let media: TVMediaItemContentView
        let hosting: UIView & UIContentView
        let placeholder: UIImage
        var aspectRatio: CGFloat
        var isMediaFocused = false
        private(set) var verticalClearance: CGFloat = 40

        init(aspectRatio: CGFloat, fallbackWidth: CGFloat, hosting: UIView & UIContentView) {
            self.aspectRatio = aspectRatio
            self.hosting = hosting
            placeholder = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image {
                UIColor.darkGray.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            let configuration = TVMediaItemContentConfiguration.wideCell()
            guard let media = configuration.makeContentView() as? TVMediaItemContentView else {
                preconditionFailure("TVUIKit did not create its media content view")
            }
            self.media = media
            super.init(frame: CGRect(x: 0, y: 0, width: fallbackWidth, height: fallbackWidth / aspectRatio + 40))
            isUserInteractionEnabled = false
            addSubview(media)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0 else { return }
            let height = bounds.width / aspectRatio
            media.frame = CGRect(x: 0, y: verticalClearance / 2, width: bounds.width, height: height)
            media.layoutIfNeeded()
            let guide = media.focusedFrameGuide.layoutFrame
            let clearance = max(0, -guide.minY) + max(0, guide.maxY - height)
            if abs(clearance - verticalClearance) > 0.5 {
                verticalClearance = clearance
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }
    }
}
#endif
