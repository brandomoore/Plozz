#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct SkipMarkerSettingsControl: View {
    @Bindable private var model: PlaybackSettingsModel
    #if os(tvOS)
    public init(model: PlaybackSettingsModel) {
        self.model = model
    }
    #else
    private let onOpenSettings: () -> Void

    public init(model: PlaybackSettingsModel, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
    }
    #endif

    public var body: some View {
        #if os(tvOS)
        SettingsControlRows {
            SkipMarkerEnableControl(model: model)
            if model.settings.skipMarkersEnabled {
                SettingsPageLink {
                    SkipMarkerSettingsView(model: model)
                } label: {
                    SettingsDisclosureLabel { Text("Customize") }
                        .settingsFormRowLayout()
                }
                .buttonStyle(SettingsFormButtonStyle())
                .accessibilityIdentifier("skip-marker-settings")
            }
        }
        #else
        SettingsSectionGroup {
            SkipMarkerEnableControl(model: model)
            if model.settings.skipMarkersEnabled {
                Button(action: onOpenSettings) {
                    SettingsDisclosureLabel { Text("Customize") }
                }
                .accessibilityIdentifier("skip-marker-settings")
            }
        }
        #endif
    }
}

private struct SkipMarkerEnableControl: View {
    @Bindable var model: PlaybackSettingsModel

    var body: some View {
        Toggle("Skip intros, credits & more", isOn: Binding(
            get: { model.settings.skipMarkersEnabled },
            set: { model.settings.setSkipMarkersEnabled($0) }
        ))
        .accessibilityIdentifier("skip-markers-enabled")
    }
}

public struct SkipMarkerSettingsView: View {
    @Bindable private var model: PlaybackSettingsModel
    @State private var selectedKind: MediaSegment.Kind?

    public init(model: PlaybackSettingsModel) {
        self.model = model
    }

    public var body: some View {
        #if os(tvOS)
        SettingsFormLayout(title: Text("Intros, credits & more"), rows: rows, showsBack: true)
        #else
        List {
            SettingsSectionGroup {
                SkipMarkerRuleControls(model: model, scope: .defaultBehavior)
            }
            SettingsSectionGroup("Enable for") {
                SkipMarkerContentControls(model: model)
            }
            SettingsSectionGroup {
                ForEach(MediaSegment.Kind.skippable, id: \.self) { kind in
                    Button { selectedKind = kind } label: {
                        SettingsDisclosureLabel { Text(kind.settingsTitle) }
                    }
                    .accessibilityIdentifier("skip-marker-\(kind.rawValue)")
                }
            }
            SettingsSectionGroup {
                SkipMarkerCommunityControl(model: model)
            }
        }
        .settingsPageSurface()
        .navigationTitle("Intros, credits & more")
        .navigationDestination(item: $selectedKind) { kind in
            SkipMarkerContentSettingsView(model: model, kind: kind)
        }
        #endif
    }

    #if os(tvOS)
    private var rows: [SettingsSplitRow] {
        [
            SettingsSplitRow(id: "skip-default", title: "Default behavior") {
                SkipMarkerRuleControls(model: model, scope: .defaultBehavior)
            }.labeledControl(),
            SettingsSplitRow(id: "skip-content", title: "Enable for") {
                SettingsControlRows {
                    SkipMarkerContentControls(model: model)
                }
            },
            SettingsSplitRow(id: "skip-kinds", title: "Markers") {
                SettingsControlRows {
                    ForEach(MediaSegment.Kind.skippable, id: \.self) { kind in
                        SettingsPageLink {
                            SkipMarkerContentSettingsView(model: model, kind: kind)
                        } label: {
                            SettingsDisclosureLabel { Text(kind.settingsTitle) }
                                .settingsFormRowLayout()
                        }
                        .buttonStyle(SettingsFormButtonStyle())
                        .accessibilityIdentifier("skip-marker-\(kind.rawValue)")
                    }
                }
            }.labeledControl(),
            SettingsSplitRow(id: "skip-community", title: "Use community markers") {
                SkipMarkerCommunityControl(model: model)
            }.labeledControl()
        ]
    }
    #endif
}

public struct SkipMarkerContentSettingsView: View {
    @Bindable private var model: PlaybackSettingsModel
    private let kind: MediaSegment.Kind
    private let categories: [ContentCategory] = [.movie, .tvShow, .anime]

    public init(model: PlaybackSettingsModel, kind: MediaSegment.Kind) {
        self.model = model
        self.kind = kind
    }

    public var body: some View {
        #if os(tvOS)
        SettingsFormLayout(
            title: Text(kind.settingsTitle),
            rows: categories.map { category in
                SettingsSplitRow(id: "skip-\(category.rawValue)", title: category.displayName) {
                    controls(for: category)
                }.labeledControl()
            },
            showsBack: true
        )
        #else
        List {
            ForEach(categories, id: \.self) { category in
                SettingsSectionGroup {
                    controls(for: category)
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(Text(kind.settingsTitle))
        #endif
    }

    private func controls(for category: ContentCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SkipMarkerRuleControls(model: model, scope: .content(kind, category))
                .disabled(!model.settings.skipContentCategories.contains(category))
            if !model.settings.skipContentCategories.contains(category) {
                Text("Disabled on the previous page.")
                    .settingsHelperText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SkipMarkerContentControls: View {
    @Bindable var model: PlaybackSettingsModel

    var body: some View {
        ForEach([ContentCategory.movie, .tvShow, .anime], id: \.self) { category in
            Toggle(isOn: Binding(
                get: { model.settings.skipContentCategories.contains(category) },
                set: { enabled in
                    if enabled { model.settings.skipContentCategories.insert(category) }
                    else { model.settings.skipContentCategories.remove(category) }
                }
            )) {
                Text(category.displayName)
            }
            .accessibilityIdentifier("skip-content-\(category.rawValue)")
        }
    }
}

private struct SkipMarkerCommunityControl: View {
    @Bindable var model: PlaybackSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use community markers", isOn: $model.settings.useCommunityMarkers)
                .accessibilityIdentifier("skip-community-markers")
            Text("From IntroDB and TheIntroDB when your server has none. Shares IMDb/TMDB IDs.")
                .settingsHelperText()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum SkipBehavior: CaseIterable, Hashable {
    case useDefault, manual, instant, delayed, off

    var title: LocalizedStringResource {
        switch self {
        case .useDefault: "Use default"
        case .off: "Off"
        case .manual: "Show skip button"
        case .instant: "Skip instantly"
        case .delayed: "Skip after"
        }
    }

    init(mode: SkipIntrosMode, delay: Int) {
        switch mode {
        case .off: self = .off
        case .on: self = .manual
        case .autoInstant: self = .instant
        case .autoDelay: self = delay == 0 ? .instant : .delayed
        }
    }
}

struct SkipMarkerRuleControls: View {
    enum Scope {
        case defaultBehavior
        case content(MediaSegment.Kind, ContentCategory)
    }

    @Bindable var model: PlaybackSettingsModel
    let scope: Scope
    @Environment(\.locale) private var locale

    private var title: LocalizedStringResource {
        switch scope {
        case .defaultBehavior: "Default behavior"
        case .content(_, let category): category.displayName
        }
    }
    private var identifier: String {
        switch scope {
        case .defaultBehavior: "default"
        case .content(let kind, let category): "\(kind.rawValue)-\(category.rawValue)"
        }
    }
    var behaviors: [SkipBehavior] {
        switch scope {
        case .defaultBehavior:
            model.settings.skipIntros == .off ? [.manual, .instant, .delayed, .off] : [.manual, .instant, .delayed]
        case .content: SkipBehavior.allCases
        }
    }
    var behavior: Binding<SkipBehavior> {
        Binding(
            get: {
                switch scope {
                case .defaultBehavior:
                    return SkipBehavior(mode: model.settings.skipIntros, delay: model.settings.configuredSkipDelay())
                case .content(let kind, let category):
                    if model.settings.usesDefaultSkipRule(for: kind, category: category) { return .useDefault }
                    return SkipBehavior(
                        mode: model.settings.configuredSkipMode(for: kind, category: category),
                        delay: model.settings.configuredSkipDelay(for: kind, category: category)
                    )
                }
            },
            set: { value in
                var settings = model.settings
                if value == .useDefault {
                    if case .content(let kind, let category) = scope {
                        settings.useDefaultSkipRule(for: kind, category: category)
                    } else {
                        preconditionFailure("Only content rules can use the shared default")
                    }
                    model.settings = settings
                    return
                }
                let mode: SkipIntrosMode = switch value {
                case .off: .off
                case .manual: .on
                case .instant: .autoInstant
                case .delayed: .autoDelay
                case .useDefault: preconditionFailure("Handled above")
                }
                switch scope {
                case .defaultBehavior:
                    if value == .delayed, settings.configuredSkipDelay() == 0 {
                        settings.setSkipAutomaticDelay(PlaybackSettings.default.skipAutomaticDelaySeconds)
                    }
                    settings.setConfiguredSkipMode(mode)
                case .content(let kind, let category):
                    if value == .delayed, settings.configuredSkipDelay(for: kind, category: category) == 0 {
                        settings.setSkipAutomaticDelay(
                            PlaybackSettings.default.skipAutomaticDelaySeconds, for: kind, category: category
                        )
                    }
                    settings.setConfiguredSkipMode(mode, for: kind, category: category)
                }
                model.settings = settings
            }
        )
    }
    private var delay: Binding<Int> {
        Binding(
            get: {
                switch scope {
                case .defaultBehavior: model.settings.configuredSkipDelay()
                case .content(let kind, let category): model.settings.configuredSkipDelay(for: kind, category: category)
                }
            },
            set: { seconds in
                switch scope {
                case .defaultBehavior: model.settings.setSkipAutomaticDelay(seconds)
                case .content(let kind, let category):
                    model.settings.setSkipAutomaticDelay(seconds, for: kind, category: category)
                }
            }
        )
    }

    var body: some View {
        SettingsControlRows(nonTVSpacing: 12) {
            #if os(tvOS)
            SettingsMenuRow(title: title, value: selectionSummary) {
                SkipBehaviorMenuContent(behaviors: behaviors, selection: behavior)
            }
            .accessibilityIdentifier("skip-behavior-\(identifier)")
            #else
            Menu {
                SkipBehaviorMenuContent(behaviors: behaviors, selection: behavior)
            } label: {
                SettingsMenuLabel(title, value: selectionSummary)
            }
            .menuStyle(.button)
            .accessibilityLabel(Text(title))
            .accessibilityValue(selectionSummary)
            .accessibilityIdentifier("skip-behavior-\(identifier)")
            #endif
            if behavior.wrappedValue == .delayed {
                #if os(tvOS)
                SettingsStepper(
                    options: PlaybackSettings.skipAutomaticDelayOptions.filter { $0 > 0 },
                    selection: delay, label: "Skip after",
                    textTitle: { seconds in
                        Text(Duration.seconds(seconds), format: .units(allowed: [.seconds], width: .wide).locale(locale))
                    }
                )
                .accessibilityIdentifier("skip-delay-\(identifier)")
                #else
                Stepper(value: delay, in: 1...30) {
                    LabeledContent {
                        Text(Duration.seconds(delay.wrappedValue), format: .units(allowed: [.seconds], width: .wide))
                    } label: {
                        Text("Skip after")
                    }
                }
                .accessibilityIdentifier("skip-delay-\(identifier)")
                #endif
            }
        }
    }

    private var selectionSummary: Text {
        behavior.wrappedValue == .useDefault
            ? Text("\(defaultSummary) (default)")
            : Text(behavior.wrappedValue.title)
    }

    private var defaultSummary: Text {
        let seconds = model.settings.configuredSkipDelay()
        let behavior = SkipBehavior(mode: model.settings.skipIntros, delay: seconds)
        if behavior == .delayed {
            return Text("Skip after \(Text(Duration.seconds(seconds), format: .units(allowed: [.seconds], width: .wide).locale(locale)))")
        }
        return Text(behavior.title)
    }
}

private struct SkipBehaviorMenuContent: View {
    let behaviors: [SkipBehavior]
    @Binding var selection: SkipBehavior

    var body: some View {
        ForEach(behaviors, id: \.self) { behavior in
            if behavior == .off {
                Divider()
            }
            // Native checked actions retain one selection without flattening the divider.
            Toggle(isOn: Binding(
                get: { selection == behavior },
                set: { _ in selection = behavior }
            )) {
                Text(behavior.title)
            }
            .toggleStyle(.automatic)
            .menuActionDismissBehavior(.enabled)
        }
    }
}
#endif
