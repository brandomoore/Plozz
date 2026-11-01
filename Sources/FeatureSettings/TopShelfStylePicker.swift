#if os(tvOS)
import CoreUI
import SwiftUI

struct TopShelfStylePicker: View {
    @Binding var usesFullScreen: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            ForEach([false, true], id: \.self) { fullScreen in
                PreviewCard(
                    title: fullScreen ? "Full Screen" : "Posters",
                    isSelected: usesFullScreen == fullScreen,
                    accent: palette.accent, compact: true, swatchAspectRatio: 16.0 / 9.0,
                    action: { usesFullScreen = fullScreen }
                ) {
                    TopShelfStylePreview(usesFullScreen: fullScreen)
                }
                .accessibilityIdentifier(fullScreen ? "top-shelf-style-fullscreen" : "top-shelf-style-posters")
                .settingsSearchAnchor(
                    usesFullScreen == fullScreen ? "top-shelf-style" : "top-shelf-option-\(fullScreen)"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A schematic Home Screen, not a preview of the current profile's media.
private struct TopShelfStylePreview: View {
    let usesFullScreen: Bool
    private let colors: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.61),
        Color(red: 0.60, green: 0.37, blue: 0.27),
        Color(red: 0.43, green: 0.37, blue: 0.59),
        Color(red: 0.31, green: 0.51, blue: 0.42)
    ]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
                Color(white: 0.08)
                if usesFullScreen {
                    landscape
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: height * 0.035) {
                        Capsule().fill(.white.opacity(0.9)).frame(width: width * 0.33, height: height * 0.04)
                        Capsule().fill(.white.opacity(0.6)).frame(width: width * 0.22, height: height * 0.02)
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.system(size: height * 0.05, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, width * 0.065)
                    .padding(.top, height * 0.12)
                    .padding(.bottom, height * 0.27)
                } else {
                    VStack(alignment: .leading, spacing: height * 0.04) {
                        Capsule().fill(.white.opacity(0.65))
                            .frame(width: width * 0.35, height: height * 0.025)
                        HStack(spacing: width * 0.025) {
                            ForEach(colors.indices, id: \.self) { index in
                                RoundedRectangle(cornerRadius: width * 0.015)
                                    .fill(LinearGradient(
                                        colors: [colors[index], colors[index].opacity(0.35)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                                    .overlay(alignment: .bottomLeading) {
                                        Capsule().fill(.white.opacity(0.75))
                                            .frame(width: width * 0.09, height: height * 0.015)
                                            .padding(width * 0.02)
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, width * 0.065)
                    .padding(.top, height * 0.10)
                    .padding(.bottom, height * 0.30)
                }
                HStack(spacing: width * 0.025) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: width * 0.02)
                            .fill(.white.opacity(index == 2 ? 1 : 0.24))
                            .scaleEffect(index == 2 ? 1.12 : 1)
                    }
                }
                .padding(width * 0.025)
                .frame(height: height * 0.20)
                .background(Color(white: 0.20).opacity(0.95), in: RoundedRectangle(cornerRadius: width * 0.035))
                .padding(.horizontal, width * 0.04)
                .padding(.bottom, height * 0.05)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityHidden(true)
    }

    private var landscape: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.33, blue: 0.49), colors[0]],
                    startPoint: .top, endPoint: .bottom
                )
                Circle().fill(Color(red: 0.96, green: 0.80, blue: 0.57))
                    .frame(width: height * 0.25, height: height * 0.25)
                    .position(x: width * 0.76, y: height * 0.28)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.44, y: height * 0.24))
                    path.addLine(to: CGPoint(x: width * 0.72, y: height * 0.68))
                    path.addLine(to: CGPoint(x: width, y: height * 0.4))
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.12, green: 0.25, blue: 0.30))
            }
        }
    }
}
#endif
