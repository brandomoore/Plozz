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
        let black = palette == .pureBlack
        return stock.indices.map { index in
            let stop = stock[index]
            let floor = black ? 0.22 : 1.0
            let fallback = Color(red: stop.0 * floor, green: stop.1 * floor, blue: stop.2 * floor)
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
                brightness: palette.isLight ? value : min(value * 1.25, 0.36) * floor
            )
            #else
            return fallback
            #endif
        }
    }
}

struct AmbientArtworkKey: Hashable {
    let id: String
    let references: [ArtworkReference]
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
        guard let key else { colors = nil; return }
        if let cached = cache[key] { colors = cached; return }
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled, generation == ticket else { return }
        let result = await sample()
        guard !Task.isCancelled, generation == ticket else { return }
        guard let resolved = result, !resolved.isEmpty else { colors = nil; return }
        if cache[key] == nil { order.append(key) }
        cache[key] = resolved
        while order.count > 24 { cache.removeValue(forKey: order.removeFirst()) }
        colors = resolved
    }

    func release(owner: UUID) {
        guard self.owner == owner else { return }
        generation &+= 1
        self.owner = nil
        colors = nil
    }
}

private enum AmbientPaletteSampler {
    #if canImport(UIKit)
    private actor Worker {
        func extract(_ image: UIImage) -> [Color] {
            guard !Task.isCancelled else { return [] }
            return ArtworkColorExtractor.palette(from: image, maxColors: 4)
        }
    }
    private static let worker = Worker()
    #endif

    static func sample(references: [ArtworkReference], fallback: (@Sendable () async -> URL?)?) async -> [Color]? {
        #if canImport(UIKit)
        for reference in references {
            guard !Task.isCancelled else { return nil }
            if let image = await ArtworkImageCache.shared.image(for: reference, variant: .heroBackdrop, background: true) {
                return await worker.extract(image)
            }
        }
        guard !Task.isCancelled, let url = await fallback?(),
              let image = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop, background: true) else {
            return nil
        }
        return await worker.extract(image)
        #else
        return nil
        #endif
    }
}

private struct GradientBackgroundsKey: EnvironmentKey {
    static let defaultValue = ThemeSettingsStore.defaultGradientEnabled
}
private struct AmbientBackdropKey: EnvironmentKey {
    static let defaultValue: AmbientBackdropModel? = nil
}
public extension EnvironmentValues {
    var gradientBackgroundsEnabled: Bool {
        get { self[GradientBackgroundsKey.self] }
        set { self[GradientBackgroundsKey.self] = newValue }
    }
}
private extension EnvironmentValues {
    var ambientBackdrop: AmbientBackdropModel? {
        get { self[AmbientBackdropKey.self] }
        set { self[AmbientBackdropKey.self] = newValue }
    }
}

public extension View {
    /// Scope the tint and its cache to one Home view-model identity, never the app root.
    func homeGradientBackground(scope: ObjectIdentifier, isVisible: Bool) -> some View {
        modifier(HomeGradientHost(scope: scope, isVisible: isVisible))
    }

    func ambientBackdropSource(
        id: String?, references: [ArtworkReference], isActive: Bool,
        fallbackURL: (@Sendable () async -> URL?)? = nil
    ) -> some View {
        modifier(AmbientBackdropSource(id: id, references: references, isActive: isActive, fallback: fallbackURL))
    }
}

private struct HomeGradientHost: ViewModifier {
    let scope: ObjectIdentifier
    let isVisible: Bool
    @State private var model = AmbientBackdropModel()
    @Environment(\.gradientBackgroundsEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .background { HomeGradientPaint(model: model, isVisible: isVisible) }
            .environment(\.ambientBackdrop, enabled && isVisible ? model : nil)
            .onChange(of: scope) { _, _ in model = AmbientBackdropModel() }
    }
}

private struct HomeGradientPaint: View {
    let model: AmbientBackdropModel
    let isVisible: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var enabled

    var body: some View {
        if enabled {
            AmbientGradientBackground(palette: palette, tint: isVisible ? model.colors : nil)
        }
    }
}

private struct AmbientBackdropSource: ViewModifier {
    let id: String?
    let references: [ArtworkReference]
    let isActive: Bool
    let fallback: (@Sendable () async -> URL?)?
    @Environment(\.ambientBackdrop) private var model
    @Environment(\.gradientBackgroundsEnabled) private var enabled
    @State private var owner = UUID()

    private struct Request: Hashable {
        let model: ObjectIdentifier?
        let artwork: AmbientArtworkKey?
    }
    private var request: Request {
        Request(model: model.map(ObjectIdentifier.init),
                artwork: enabled && isActive ? id.map { AmbientArtworkKey(id: $0, references: references) } : nil)
    }

    func body(content: Content) -> some View {
        content
            .task(id: request) {
                guard let model else { return }
                let references = references, fallback = fallback
                await model.update(owner: owner, key: request.artwork) {
                    await AmbientPaletteSampler.sample(references: references, fallback: fallback)
                }
            }
            .onDisappear { model?.release(owner: owner) }
    }
}
#endif
