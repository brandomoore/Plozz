#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct SelectHomeLayoutView: View {
    let hero: HeroSettingsModel
    let onContinue: () -> Void
    @Environment(\.themePalette) private var palette
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case layout(HeroStyle)
        case continueButton
    }

    private var selectedLayout: HeroStyle {
        hero.settings.style
    }

    private static let cardWidth: CGFloat = 480

    var body: some View {
        VStack(spacing: 40) {
            Spacer(minLength: 0)

            Text(LocalizedStringResource(
                "homeLayout.onboarding.title",
                defaultValue: "Choose Home layout for this profile",
                comment: "Apple TV setup heading above the Fullscreen Hero and Showcase layout choices."
            ))
            .font(.largeTitle.weight(.bold))
            .multilineTextAlignment(.center)

            HStack(alignment: .top, spacing: 28) {
                ForEach(HeroStyle.allCases, id: \.self) { layout in
                    HomeLayoutOptionCard(
                        style: layout,
                        isSelected: layout == selectedLayout,
                        swatchHeight: (Self.cardWidth - PlozzTheme.Metrics.Radius.inset * 2) * 9 / 16,
                        action: { hero.settings.style = layout }
                    )
                    .frame(width: Self.cardWidth)
                    .focused($focus, equals: .layout(layout))
                }
            }
            .focusSection()

            ZStack {
                Button(action: onContinue) {
                    Text("Continue")
                }
                .plozzActionButton()
                .focused($focus, equals: .continueButton)
            }
            .frame(maxWidth: .infinity)
            .focusSection()
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground(palette: palette).ignoresSafeArea() }
        .onAppear { focus = .layout(selectedLayout) }
        .onExitCommand { onContinue() }
    }
}
#endif
