import CoreModels
import SwiftUI
import TVUIKit
import UIKit
@testable import CoreUI

struct NativeArtworkFocusComparisonScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NativeArtworkFocusComparisonController {
        NativeArtworkFocusComparisonController()
    }

    func updateUIViewController(_ controller: NativeArtworkFocusComparisonController, context: Context) {}
}

@MainActor
final class NativeArtworkFocusComparisonController: UIViewController {
    enum Variant: String, CaseIterable {
        case poster, compositedPoster, maskedPoster, card

        var title: String {
            switch self {
            case .poster: "Native poster - current"
            case .compositedPoster: "Native poster - single image"
            case .maskedPoster: "Native poster - content mask"
            case .card: "Native card - default"
            }
        }
    }

    struct Sample {
        let variant: Variant
        let control: TVLockupView
        let artwork: UIImageView
        let overlay: UIView
        let hostedOverlay: (UIView & UIContentView)?
    }

    let artworkSize = CGSize(width: 400, height: 225)
    private(set) var samples: [Sample] = []
    private(set) var activations = 0
    let restingTarget = UIButton(type: .system)
    weak var focusTarget: UIView?
    private let status = UILabel()
    private var labels: [UILabel] = []

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        [focusTarget ?? samples.first(where: { $0.variant == .compositedPoster })?.control ?? restingTarget]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.055, alpha: 1)
        let title = label("Native focus: enlargement without internal cropping", size: 42)
        title.frame = CGRect(x: 100, y: 105, width: 1720, height: 60)
        view.addSubview(title)
        let detail = label("Compare the image edges and moving highlight. Move between cards; press Select to activate.", size: 24)
        detail.frame = CGRect(x: 100, y: 175, width: 1720, height: 45)
        view.addSubview(detail)
        let pattern = NativeComparisonPattern.makeImage()
        let format = UIGraphicsImageRendererFormat()
        format.scale = pattern.size.width / artworkSize.width
        let image = UIGraphicsImageRenderer(size: artworkSize, format: format).image { _ in
            UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: artworkSize),
                cornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius
            ).addClip()
            pattern.draw(in: CGRect(origin: .zero, size: artworkSize))
        }
        // Freeze overlay chrome to isolate native motion; a real card must also handle content updates.
        let compositedImage = composite(image, focused: false)
        for variant in Variant.allCases {
            let control: TVLockupView
            let artwork: UIImageView
            let overlayParent: UIView
            if variant != .card {
                let poster = TVPosterView(image: variant == .compositedPoster ? compositedImage : image)
                poster.imageView.masksFocusEffectToContents = variant == .maskedPoster || variant == .compositedPoster
                control = poster
                artwork = poster.imageView
                overlayParent = artwork.overlayContentView
            } else {
                let card = TVCardView()
                card.cardBackgroundColor = .black
                artwork = UIImageView(image: image)
                artwork.contentMode = .scaleAspectFill
                artwork.clipsToBounds = true
                artwork.layer.cornerRadius = PlozzTheme.Metrics.nativePosterArtworkCornerRadius
                card.contentView.addSubview(artwork)
                fill(artwork, in: card.contentView)
                control = card
                overlayParent = card.contentView
            }
            control.contentSize = artworkSize
            control.isAccessibilityElement = true
            control.accessibilityLabel = variant.title
            control.accessibilityIdentifier = variant.rawValue
            control.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                activations += 1
                updateStatus()
            }, for: .primaryActionTriggered)
            let overlay: (UIView & UIContentView)?
            if variant == .compositedPoster {
                overlay = nil
            } else {
                let hosted = overlayConfiguration(focused: false).makeContentView()
                hosted.layer.shouldRasterize = true
                hosted.layer.rasterizationScale = traitCollection.displayScale
                overlayParent.addSubview(hosted)
                fill(hosted, in: overlayParent)
                overlay = hosted
            }
            samples.append(Sample(
                variant: variant, control: control, artwork: artwork,
                overlay: overlay ?? artwork, hostedOverlay: overlay
            ))
            view.addSubview(control)
            let caption = label(variant.title, size: 28)
            labels.append(caption)
            view.addSubview(caption)
        }
        restingTarget.setTitle("Resting appearance", for: .normal)
        restingTarget.accessibilityIdentifier = "comparison-resting-target"
        view.addSubview(restingTarget)
        status.textColor = .lightGray
        status.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        status.numberOfLines = 0
        view.addSubview(status)
        updateStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (index, sample) in samples.enumerated() {
            let center = CGPoint(x: 480 + CGFloat(index % 2) * 960, y: 380 + CGFloat(index / 2) * 350)
            let size = sample.control.intrinsicContentSize
            let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height)
            if sample.control.frame != frame { sample.control.frame = frame }
            labels[index].frame = CGRect(x: center.x - 350, y: center.y + 135, width: 700, height: 45)
        }
        restingTarget.frame = CGRect(x: 760, y: 935, width: 400, height: 55)
        status.frame = CGRect(x: 110, y: 1000, width: 1700, height: 70)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        for sample in samples where sample.control === context.previouslyFocusedView || sample.control === context.nextFocusedView {
            sample.hostedOverlay?.configuration = overlayConfiguration(focused: sample.control.isFocused)
        }
        updateStatus()
    }

    private func updateStatus() {
        let focused = samples.first { $0.control.isFocused }?.variant.title ?? "Resting appearance"
        status.text = "Focused: \(focused)   Activations: \(activations)\nGreen frame is baked into the image. Magenta corner markers belong to the overlay."
    }

    private func label(_ text: String, size: CGFloat) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: size, weight: .medium)
        label.textAlignment = .center
        return label
    }

    private func fill(_ child: UIView, in parent: UIView) {
        // TVUIKit owns these animated bounds; do not feed hosted intrinsic sizes back into them.
        child.frame = parent.bounds
        child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    private func overlayConfiguration(focused: Bool) -> any UIContentConfiguration {
        UIHostingConfiguration { overlayContent(focused: focused) }.margins(.all, 0)
    }

    private func composite(_ image: UIImage, focused: Bool) -> UIImage {
        let renderer = ImageRenderer(content: overlayContent(focused: focused)
            .frame(width: artworkSize.width, height: artworkSize.height))
        renderer.scale = image.scale
        guard let overlay = renderer.uiImage else {
            preconditionFailure("The native comparison overlay must render.")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: artworkSize, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: artworkSize)
            UIBezierPath(roundedRect: bounds, cornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius).addClip()
            image.draw(in: bounds)
            overlay.draw(in: bounds)
        }
    }

    private func overlayContent(focused: Bool) -> some View {
        var item = MediaItem(id: "comparison", title: "Comparison", kind: .movie)
        item.isPlayed = true
        item.playedPercentage = 0.42
        return ZStack {
            MediaCardPlaybackIndicators(
                item: item, badgeInset: 12, progressHeight: 6,
                progressHorizontalInset: 16, progressBottomInset: 16,
                downloadState: .completed,
                artworkCornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius
            )
            VStack {
                HStack {
                    Rectangle().fill(Color(red: 1, green: 0, blue: 1)).frame(width: 10, height: 18)
                    Spacer()
                    Rectangle().fill(Color(red: 1, green: 0, blue: 1)).frame(width: 10, height: 18)
                }
                Spacer()
            }
            .padding(8)
        }
        .environment(\.themePalette, .dark)
        .plozzChromeFocused(focused)
        .allowsHitTesting(false)
    }
}
