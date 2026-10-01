#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Model

/// The live tint for the Gradient theme's page background.
///
/// Home's hero publishes the colours of the slide it is showing; the navigation
/// shell says whether Home is the visible destination. Only when both hold does
/// the background take the artwork's colours — every other destination (and
/// Home before its first sample lands) shows the stock gradient.
///
/// One instance lives at the app root and is handed down through
/// ``SwiftUI/EnvironmentValues/ambientBackdrop``.
@MainActor
@Observable
public final class AmbientBackdropModel {
    public init() {}

    /// Colours sampled from the fronted hero slide, most prominent first.
    public private(set) var heroColors: [Color]?
    /// Whether the destination that owns the hero is the one on screen.
    public var isHeroDestinationVisible = false

    /// What the background should paint with right now; `nil` = stock.
    public var tint: [Color]? { isHeroDestinationVisible ? heroColors : nil }

    @ObservationIgnored private var sampled: [String: [Color]] = [:]
    @ObservationIgnored private var sampledOrder: [String] = []

    public func publishHeroColors(_ colors: [Color]?) {
        guard heroColors != colors else { return }
        heroColors = colors
    }

    func cachedColors(for key: String) -> [Color]? { sampled[key] }

    func store(_ colors: [Color], for key: String) {
        if sampled[key] == nil { sampledOrder.append(key) }
        sampled[key] = colors
        while sampledOrder.count > 24 {
            sampled.removeValue(forKey: sampledOrder.removeFirst())
        }
    }
}

private struct AmbientBackdropKey: EnvironmentKey {
    static let defaultValue: AmbientBackdropModel? = nil
}

public extension EnvironmentValues {
    /// The root's ambient backdrop model. `nil` outside the main app shell
    /// (onboarding, previews), where the gradient always renders stock.
    var ambientBackdrop: AmbientBackdropModel? {
        get { self[AmbientBackdropKey.self] }
        set { self[AmbientBackdropKey.self] = newValue }
    }
}

// MARK: - Background

/// The Gradient theme's page: a soft 3×3 mesh recreating the stock tvOS system
/// background — slate blue upper-left, a dim warm centre, olive lower-left and
/// a faint teal lower-right.
///
/// tvOS doesn't expose its system wallpaper, so the stops are sampled from it.
/// A mesh (rather than a bundled image) keeps it resolution-independent and lets
/// it be recoloured: given a tint, each stop keeps the stock gradient's
/// brightness but takes its hue from the artwork, so a tinted page has exactly
/// the same shape and depth as the stock one.
public struct AmbientGradientBackground: View {
    private enum Source {
        case environment
        case fixed([Color]?)
    }

    private let source: Source
    @Environment(\.ambientBackdrop) private var model

    /// Follows the environment's ``AmbientBackdropModel`` (stock when absent).
    public init() {
        source = .environment
    }

    /// A fixed tint; `nil` draws the stock gradient.
    public init(tint: [Color]?) {
        source = .fixed(tint)
    }

    private var tint: [Color]? {
        switch source {
        case .environment: return model?.tint
        case .fixed(let colors): return colors
        }
    }

    public var body: some View {
        let colors = Self.meshColors(tint: tint)
        MeshGradient(
            width: 3,
            height: 3,
            points: Self.points,
            colors: colors,
            smoothsColors: true
        )
        .animation(.easeInOut(duration: 1.2), value: colors)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Slightly off-grid interior points so the bands don't read as a lattice.
    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.58, 0.55], [1, 0.45],
        [0, 1], [0.45, 1], [1, 1],
    ]

    /// The stock stops, row-major, sampled from the system background.
    static let stock: [(r: Double, g: Double, b: Double)] = [
        (0.196, 0.227, 0.251), (0.188, 0.208, 0.235), (0.212, 0.208, 0.220),
        (0.192, 0.216, 0.231), (0.165, 0.163, 0.165), (0.190, 0.182, 0.176),
        (0.165, 0.149, 0.114), (0.129, 0.129, 0.118), (0.149, 0.165, 0.149),
    ]

    /// Which artwork colour feeds each stop (index into the tint, wrapped).
    /// The most prominent colour takes the large upper-left field; secondaries
    /// fill the lower corners so a multi-colour poster reads as a blend.
    private static let tintSlot: [Int] = [
        0, 0, 1,
        0, 1, 1,
        2, 2, 3,
    ]

    static func meshColors(tint: [Color]?) -> [Color] {
        let stockColors = stock.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
        guard let tint, !tint.isEmpty else { return stockColors }
        #if canImport(UIKit)
        return stock.indices.map { index in
            let source = UIColor(tint[tintSlot[index] % tint.count])
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            guard source.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else {
                return stockColors[index]
            }
            let stop = stock[index]
            let stockBrightness = max(stop.r, stop.g, stop.b)
            // Saturated colours read darker than greys at equal brightness, so
            // lift a touch to keep the page's overall depth matched to stock.
            let brightness = min(stockBrightness * 1.25, 0.36)
            let saturation = min(s, 0.75) * 0.8
            return Color(hue: Double(h), saturation: Double(saturation), brightness: Double(brightness))
        }
        #else
        return stockColors
        #endif
    }
}

// MARK: - Hero source

#if canImport(UIKit)
public extension View {
    /// Publishes the colours of the hero slide `id` into the root's
    /// ``AmbientBackdropModel`` so the Gradient theme can tint the page to it.
    /// Only active when the theme uses the ambient gradient; otherwise it does
    /// no work. Samples the already-decoded hero backdrop where possible.
    func ambientBackdropSource(
        id: String?,
        references: [ArtworkReference],
        fallbackURL: (@Sendable () async -> URL?)? = nil
    ) -> some View {
        modifier(AmbientBackdropSourceModifier(id: id, references: references, fallbackURL: fallbackURL))
    }
}

private struct AmbientBackdropSourceModifier: ViewModifier {
    let id: String?
    let references: [ArtworkReference]
    let fallbackURL: (@Sendable () async -> URL?)?

    @Environment(\.ambientBackdrop) private var model
    @Environment(\.themePalette) private var palette

    private var taskKey: String? {
        guard palette.usesAmbientGradient, model != nil else { return nil }
        return id
    }

    func body(content: Content) -> some View {
        content
            .task(id: taskKey) {
                guard let model, let id = taskKey else { return }
                if let cached = model.cachedColors(for: id) {
                    model.publishHeroColors(cached)
                    return
                }
                guard let colors = await Self.sample(references: references, fallbackURL: fallbackURL),
                      !Task.isCancelled else { return }
                model.store(colors, for: id)
                model.publishHeroColors(colors)
            }
            .onDisappear { model?.publishHeroColors(nil) }
    }

    private static func sample(
        references: [ArtworkReference],
        fallbackURL: (@Sendable () async -> URL?)?
    ) async -> [Color]? {
        var image: UIImage?
        for reference in references {
            if let loaded = await ArtworkImageCache.shared.image(for: reference, variant: .heroBackdrop) {
                image = loaded
                break
            }
        }
        if image == nil, let fallbackURL, let url = await fallbackURL() {
            image = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
        }
        guard let image else { return nil }
        let colors = await Task.detached(priority: .utility) {
            ArtworkColorExtractor.palette(from: image, maxColors: 4)
        }.value
        return colors.isEmpty ? nil : colors
    }
}
#endif
#endif
