#if canImport(SwiftUI)
import CoreModels
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Static mesh design adapted from tresby's Ambient theme (Plozz PR #75).
/// Only palette changes crossfade; there is no display-clock or drifting mesh.
public struct AmbientGradientBackground: View {
    let palette: ThemePalette
    var tint: [Color]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(palette: ThemePalette, tint: [Color]? = nil) {
        self.palette = palette
        self.tint = tint
    }

    public var body: some View {
        let colors = Self.meshColors(tint: tint, palette: palette)
        MeshGradient(width: 3, height: 3, points: Self.points, colors: colors, smoothsColors: true)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: colors)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: colors, initial: true) { _, colors in
                #if canImport(UIKit)
                HeroArtDiagnostics.emit(
                    "palette mesh theme=\(palette) source=\(tint?.isEmpty == false ? "artwork" : "stock") "
                    + "input=\(ArtworkPaletteDiagnostics.colors(tint)) output=\(ArtworkPaletteDiagnostics.colors(colors))"
                )
                #endif
            }
    }

    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.58, 0.55], [1, 0.45],
        [0, 1], [0.45, 1], [1, 1]
    ]

    private static let dark: [(Double, Double, Double)] = [
        (0.196, 0.227, 0.251), (0.188, 0.208, 0.235), (0.212, 0.208, 0.220),
        (0.192, 0.216, 0.231), (0.165, 0.163, 0.165), (0.190, 0.182, 0.176),
        (0.165, 0.149, 0.114), (0.129, 0.129, 0.118), (0.149, 0.165, 0.149)
    ]
    private static let light: [(Double, Double, Double)] = [
        (0.86, 0.89, 0.93), (0.88, 0.90, 0.93), (0.91, 0.90, 0.91),
        (0.88, 0.90, 0.92), (0.93, 0.93, 0.93), (0.92, 0.91, 0.90),
        (0.91, 0.89, 0.84), (0.94, 0.94, 0.92), (0.89, 0.92, 0.89)
    ]
    private static let tintSlots = [0, 0, 1, 0, 1, 1, 2, 2, 3]

    static func meshColors(tint: [Color]?, palette: ThemePalette) -> [Color] {
        let stock = palette.isLight ? light : dark
        let brightnessScale = palette.isLight ? 1.0 : (palette == .pureBlack ? 0.32 : 0.88)
        return stock.indices.map { index in
            let stop = stock[index]
            let fallback = Color(
                red: stop.0 * brightnessScale, green: stop.1 * brightnessScale, blue: stop.2 * brightnessScale
            )
            guard let tint, !tint.isEmpty else { return fallback }
            #if canImport(UIKit)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(tint[tintSlots[index] % tint.count])
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
                return fallback
            }
            let value = max(stop.0, stop.1, stop.2)
            return Color(
                hue: Double(hue),
                saturation: palette.isLight ? Double(min(saturation, 0.6)) * 0.3 : Double(min(saturation, 0.75)) * 0.8,
                brightness: palette.isLight ? value : min(value * 1.25, 0.36) * brightnessScale
            )
            #else
            return fallback
            #endif
        }
    }
}

struct AmbientArtworkKey: Hashable, Sendable {
    let id: String
    let reference: ArtworkReference
    var variant: ArtworkImageVariant = .heroBackdrop
}

@MainActor @Observable
final class AmbientBackdropModel {
    private(set) var colors: [Color]?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cache: [AmbientArtworkKey: [Color]] = [:]
    @ObservationIgnored private var order: [AmbientArtworkKey] = []

    func update(
        owner: UUID, key: AmbientArtworkKey?,
        delay: Duration = .milliseconds(180),
        sample: @Sendable () async -> [Color]?
    ) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let ticket = generation
        self.owner = owner
        trace("request", key: key, ticket: ticket)
        guard let key else { colors = nil; trace("stock-no-source", key: nil, ticket: ticket); return }
        if let cached = cache[key] {
            colors = cached
            trace("cache-hit", key: key, ticket: ticket)
            return
        }
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled, generation == ticket else { return }
        let result = await sample()
        guard !Task.isCancelled, generation == ticket else { return }
        guard let resolved = result, !resolved.isEmpty else {
            colors = nil
            trace("stock-sample-failed", key: key, ticket: ticket)
            return
        }
        if cache[key] == nil { order.append(key) }
        cache[key] = resolved
        while order.count > 24 { cache.removeValue(forKey: order.removeFirst()) }
        colors = resolved
        trace("applied", key: key, ticket: ticket)
    }

    func release(owner: UUID) {
        guard self.owner == owner else { return }
        generation &+= 1
        self.owner = nil
        colors = nil
        trace("released", key: nil, ticket: generation)
    }

    private func trace(_ event: String, key: AmbientArtworkKey?, ticket: Int) {
        #if canImport(UIKit)
        HeroArtDiagnostics.emit(
            "palette ambient event=\(event) owner=\(owner?.uuidString ?? "none") generation=\(ticket) "
            + "item=\(HandoffDiagnostics.correlationID(key?.id)) key=\(ArtworkPaletteDiagnostics.keyID(key)) "
            + "colors=\(ArtworkPaletteDiagnostics.colors(colors))"
        )
        #endif
    }
}

enum AmbientPaletteSampler {
    #if canImport(UIKit)
    private actor Worker {
        func extract(_ image: UIImage, reference: ArtworkReference, key: AmbientArtworkKey?, source: String) -> [Color] {
            guard !Task.isCancelled else { return [] }
            let colors = ArtworkColorExtractor.palette(from: image, maxColors: 4)
            HeroArtDiagnostics.emit(
                "palette sample item=\(HandoffDiagnostics.correlationID(key?.id)) key=\(ArtworkPaletteDiagnostics.keyID(key)) "
                + "source=\(source) reference=\(ArtworkPaletteDiagnostics.referenceID(reference)) "
                + "\(ArtworkPaletteDiagnostics.imageSummary(image)) colors=\(ArtworkPaletteDiagnostics.colors(colors))"
            )
            return colors
        }
    }
    private static let worker = Worker()
    #endif

    #if canImport(UIKit)
    static func sample(_ displayed: DisplayedHeroArtwork) async -> [Color]? {
        guard !Task.isCancelled else { return nil }
        return await worker.extract(
            displayed.artwork.image, reference: displayed.artwork.reference,
            key: displayed.key, source: "displayed"
        )
    }
    #endif
}

private struct GradientBackgroundsKey: EnvironmentKey {
    static let defaultValue = ThemeSettingsStore.defaultGradientEnabled
}
public extension EnvironmentValues {
    var gradientBackgroundsEnabled: Bool {
        get { self[GradientBackgroundsKey.self] }
        set { self[GradientBackgroundsKey.self] = newValue }
    }
}

public extension View {
    /// Scope the tint and its cache to one Home view-model identity, never the app root.
    func homeGradientBackground(scope: ObjectIdentifier, isVisible: Bool) -> some View {
        modifier(HomeGradientHost(scope: scope, isVisible: isVisible))
    }

}

private struct HomeGradientHost: ViewModifier {
    let scope: ObjectIdentifier
    let isVisible: Bool
    @State private var model = AmbientBackdropModel()
    #if canImport(UIKit)
    @State private var artwork = HeroArtworkDisplayState()
    #endif

    func body(content: Content) -> some View {
        content
            .background {
                HomeGradientPaint(model: model, isVisible: isVisible)
                    #if canImport(UIKit)
                    .environment(\.heroArtworkDisplayState, artwork)
                    #endif
            }
            #if canImport(UIKit)
            .environment(\.heroArtworkDisplayState, artwork)
            #endif
            .onChange(of: scope) { _, _ in
                model = AmbientBackdropModel()
                #if canImport(UIKit)
                artwork = HeroArtworkDisplayState()
                #endif
            }
    }
}

private struct HomeGradientPaint: View {
    let model: AmbientBackdropModel
    let isVisible: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var enabled
    #if canImport(UIKit)
    @Environment(\.heroArtworkDisplayState) private var artwork
    @State private var owner = UUID()
    private struct Request: Hashable {
        let model: ObjectIdentifier
        let key: AmbientArtworkKey?
    }
    #endif

    var body: some View {
        if enabled {
            AmbientGradientBackground(palette: palette, tint: isVisible ? model.colors : nil)
                #if canImport(UIKit)
                .task(id: Request(model: ObjectIdentifier(model), key: isVisible ? artwork?.displayed?.key : nil)) {
                    let displayed = isVisible ? artwork?.displayed : nil
                    await model.update(owner: owner, key: displayed?.key) {
                        guard let displayed else { return nil }
                        return await AmbientPaletteSampler.sample(displayed)
                    }
                }
                .onDisappear { model.release(owner: owner) }
                #endif
        }
    }
}
#endif
