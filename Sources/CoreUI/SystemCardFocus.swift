import CoreModels
import SwiftUI

private struct NativeFocusSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NativeArtworkSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var plozzNativeFocusSurface: Bool {
        get { self[NativeFocusSurfaceKey.self] }
        set { self[NativeFocusSurfaceKey.self] = newValue }
    }

    var plozzNativeArtworkSurface: Bool {
        get { self[NativeArtworkSurfaceKey.self] }
        set { self[NativeArtworkSurfaceKey.self] = newValue }
    }
}

@propertyWrapper
public struct PlozzCardFocus: DynamicProperty {
    @FocusState private var focused: Bool
    @State private var observed = false
    @State private var request = Request()
    @Environment(\.plozzCardFocusStyle) private var style

    public init() {}

    public var wrappedValue: Bool {
        get {
            #if os(tvOS)
            usesNativeFocus ? observed : focused
            #else
            focused
            #endif
        }
        nonmutating set {
            if newValue {
                projectedValue.requestFocus()
            } else {
                request.wantsFocus = false
                focused = false
            }
        }
    }

    private var usesNativeFocus: Bool {
        #if os(tvOS)
        style.usesSystemEffect
        #else
        false
        #endif
    }

    struct Request: Equatable {
        var generation: UInt64 = 0
        var wantsFocus = false
        var animated = true
    }

    public var projectedValue: Binding {
        Binding(
            focusState: $focused, observed: $observed, request: $request,
            requestSnapshot: request, usesNativeFocus: usesNativeFocus
        )
    }

    public struct Binding {
        public let focusState: FocusState<Bool>.Binding
        let observed: SwiftUI.Binding<Bool>
        let request: SwiftUI.Binding<Request>
        // The command value participates in SwiftUI invalidation even when the
        // native coordinator is the only consumer of the writable binding.
        let requestSnapshot: Request
        let usesNativeFocus: Bool

        public func requestFocus(animated: Bool = true) {
            if usesNativeFocus {
                var next = request.wrappedValue
                next.generation &+= 1
                next.wantsFocus = true
                next.animated = animated
                request.wrappedValue = next
            } else {
                focusState.wrappedValue = true
            }
        }
    }
}

public extension View {
    func plozzCardFocusEffect() -> some View {
        modifier(CardFocusEffectAvailability())
    }

    /// Focus presentation belongs to the surrounding TVUIKit control.
    func plozzSystemCardProjection(cornerRadius: CGFloat) -> some View {
        self
    }

    func plozzRestingCardShadow(isFocused: Bool) -> some View {
        modifier(RestingCardShadow(isFocused: isFocused))
    }

    func plozzCardArtworkClip<S: Shape>(_ shape: S) -> some View {
        modifier(CardArtworkClip(shape: shape))
    }

    func plozzNativeMediaButtonStyle() -> some View {
        modifier(NativeMediaButtonStyle())
    }

    func plozzCardFocusButtonStyle<Style: ButtonStyle>(
        _ fallback: Style, cornerRadius: CGFloat, contentSuppliesProjection: Bool = false
    ) -> some View {
        modifier(CardFocusButtonStyle(fallback: fallback, contentSuppliesProjection: contentSuppliesProjection))
    }
}

private struct CardFocusButtonStyle<Style: ButtonStyle>: ViewModifier {
    let fallback: Style
    let contentSuppliesProjection: Bool
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        #if os(tvOS)
        if style.usesSystemEffect {
            content.buttonStyle(NativeTVCardButtonStyle())
        } else {
            content.buttonStyle(fallback).focusEffectDisabled()
        }
        #else
        content.buttonStyle(fallback)
        #endif
    }
}

private struct NativeMediaButtonStyle: ViewModifier {
    @Environment(\.plozzCardStyle) private var cardStyle

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.buttonStyle(NativeTVCardButtonStyle())
        #else
        content
        #endif
    }
}

private struct CardArtworkClip<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.plozzNativeArtworkSurface) private var nativeArtworkSurface

    func body(content: Content) -> some View {
        #if os(tvOS)
        if nativeArtworkSurface {
            content
        } else {
            content.clipShape(shape)
        }
        #else
        content.clipShape(shape)
        #endif
    }
}

private struct CardFocusEffectAvailability: ViewModifier {
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        content.focusEffectDisabled(!style.usesSystemEffect)
    }
}

private struct RestingCardShadow: ViewModifier {
    let isFocused: Bool
    @Environment(\.plozzNativeFocusSurface) private var nativeSurface

    func body(content: Content) -> some View {
        if nativeSurface {
            content
        } else {
            content.shadow(
                color: .black.opacity(isFocused ? 0.36 : 0.15),
                radius: isFocused ? 20 : 8,
                y: isFocused ? 10 : 4
            )
        }
    }
}

#if os(tvOS)
import TVUIKit
import UIKit

/// Geometry only: retain Z until ancestor perspective is applied when capturing
/// a native focused image for the separate detail-page transition.
enum NativeFocusProjection {
    @MainActor
    static func artworkFrame(of view: UIView, in window: UIWindow) -> CGRect? {
        var bounds: CGRect?
        if let media = view as? TVMediaItemContentView, media.superview?.isFocused == true {
            bounds = media.focusedFrameGuide.layoutFrame
        } else if let image = view as? UIImageView, image.adjustsImageWhenAncestorFocused {
            var ancestor: UIView? = image
            while let current = ancestor {
                if current.isFocused {
                    // UIImageView's native focus rendering need not change its
                    // layer transform. The public guide describes the painted image.
                    bounds = image.focusedFrameGuide.layoutFrame
                    break
                }
                ancestor = current.superview
            }
        }
        return frame(of: view.layer, in: window.layer, bounds: bounds)
    }

    static func frame(of layer: CALayer, in ancestor: CALayer, bounds: CGRect? = nil) -> CGRect? {
        let bounds = bounds ?? (layer.presentation() ?? layer).bounds
        guard !bounds.isEmpty else { return nil }
        var points = [
            Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY),
            Point(x: bounds.minX, y: bounds.maxY), Point(x: bounds.maxX, y: bounds.maxY)
        ]
        var current: CALayer? = layer
        while let node = current, node !== ancestor {
            guard let parent = node.superlayer else { return nil }
            let state = node.presentation() ?? node
            let parentState = parent.presentation() ?? parent
            let anchor = CGPoint(
                x: state.bounds.minX + state.bounds.width * state.anchorPoint.x,
                y: state.bounds.minY + state.bounds.height * state.anchorPoint.y
            )
            for index in points.indices {
                points[index].translate(x: -anchor.x, y: -anchor.y, z: -state.anchorPointZ)
                points[index].apply(state.transform)
                points[index].translate(x: state.position.x, y: state.position.y, z: state.zPosition + state.anchorPointZ)
                if !CATransform3DIsIdentity(parentState.sublayerTransform) {
                    let center = CGPoint(x: parentState.bounds.midX, y: parentState.bounds.midY)
                    points[index].translate(x: -center.x, y: -center.y)
                    points[index].apply(parentState.sublayerTransform)
                    points[index].translate(x: center.x, y: center.y)
                }
            }
            current = parent
        }
        guard current === ancestor, points.allSatisfy({ $0.w.isFinite && abs($0.w) > 0.000001 }) else { return nil }
        let projected = points.map { CGPoint(x: $0.x / $0.w, y: $0.y / $0.w) }
        guard projected.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minX = projected.map(\.x).min(), let maxX = projected.map(\.x).max(),
              let minY = projected.map(\.y).min(), let maxY = projected.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private struct Point {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat = 0
        var w: CGFloat = 1

        mutating func translate(x: CGFloat, y: CGFloat, z: CGFloat = 0) {
            self.x += x * w
            self.y += y * w
            self.z += z * w
        }

        mutating func apply(_ transform: CATransform3D) {
            self = Point(
                x: x * transform.m11 + y * transform.m21 + z * transform.m31 + w * transform.m41,
                y: x * transform.m12 + y * transform.m22 + z * transform.m32 + w * transform.m42,
                z: x * transform.m13 + y * transform.m23 + z * transform.m33 + w * transform.m43,
                w: x * transform.m14 + y * transform.m24 + z * transform.m34 + w * transform.m44
            )
        }
    }
}
#endif
