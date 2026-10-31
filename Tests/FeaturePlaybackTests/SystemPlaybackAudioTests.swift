import SwiftUI
import XCTest
@testable import FeaturePlayback

@MainActor
func controlsWithoutSystemAudio() -> PlayerControlsModel {
    #if os(tvOS)
    PlayerControlsModel(systemAudio: SystemPlaybackAudio(backend: SystemAudioTestBackend()))
    #else
    PlayerControlsModel()
    #endif
}

#if os(tvOS)
@MainActor
final class SystemAudioTestBackend: SystemPlaybackAudioControlling {
    var values: [SystemPlaybackAudioSetting: Bool] = [:]
    var writes: [(SystemPlaybackAudioSetting, Bool)] = []
    var onRead: (() -> Void)?
    var onSet: ((Bool, SystemPlaybackAudioSetting) throws -> Void)?
    var dialogueLevel: SystemDialogueLevel?
    var levelWrites: [SystemDialogueLevel] = []
    var onSetLevel: ((SystemDialogueLevel) throws -> Void)?

    func read() -> SystemPlaybackAudioState {
        onRead?()
        return .init(values: values, dialogueLevel: dialogueLevel)
    }

    func setDialogueLevel(_ level: SystemDialogueLevel) throws {
        levelWrites.append(level)
        if let onSetLevel {
            try onSetLevel(level)
        } else {
            dialogueLevel = level
            values[.enhanceDialogue] = level != .off
        }
    }

    func setEnabled(_ enabled: Bool, for setting: SystemPlaybackAudioSetting) throws {
        writes.append((setting, enabled))
        if let onSet {
            try onSet(enabled, setting)
        } else {
            values[setting] = enabled
        }
    }
}

@MainActor
final class SystemPlaybackAudioTests: XCTestCase {
    func testAvailabilityRequiresBothTheBridgeAndOutputSupport() {
        let preferences = [
            "lateNightModeIsAvailable": true, "latenightmode": true,
            "enhanceDialogIsAvailable": false, "enhancedialog": true
        ]
        XCTAssertEqual(SystemPlaybackAudioPreferences.availableValues(canPost: true) {
            preferences[$0] ?? false
        }, [.reduceLoudSounds: true])
        XCTAssertTrue(SystemPlaybackAudioPreferences.availableValues(canPost: false) { _ in
            XCTFail("An unavailable bridge must not offer controls.")
            return true
        }.isEmpty)
        XCTAssertTrue(SystemPlaybackAudioPreferences.availableValues(canPost: true) { _ in false }.isEmpty)
    }

    func testAvailableButUnsetPreferenceIsOffNotUnavailable() {
        XCTAssertEqual(SystemPlaybackAudioPreferences.availableValues(canPost: true) {
            $0 == "enhanceDialogIsAvailable"
        }, [.enhanceDialogue: false])
    }

    func testCommandsOnlyToggleTheTwoSystemEffects() {
        XCTAssertEqual(SystemPlaybackAudioSetting.reduceLoudSounds.notification(enabled: true).rawValue,
                       "com.apple.TVPAudioVideoSettings.enableLateNightMode")
        XCTAssertEqual(SystemPlaybackAudioSetting.reduceLoudSounds.notification(enabled: false).rawValue,
                       "com.apple.TVPAudioVideoSettings.disableLateNightMode")
        XCTAssertEqual(SystemPlaybackAudioSetting.enhanceDialogue.notification(enabled: true).rawValue,
                       "com.apple.TVPAudioVideoSettings.enableEnhanceDialog")
        XCTAssertEqual(SystemPlaybackAudioSetting.enhanceDialogue.notification(enabled: false).rawValue,
                       "com.apple.TVPAudioVideoSettings.disableEnhanceDialog")
    }

    func testInitializationAndExternalRefreshNeverWritePreferences() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: true, .reduceLoudSounds: false]
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.refresh().value
        XCTAssertEqual(audio.availableSettings, [.enhanceDialogue, .reduceLoudSounds])
        backend.values = [.enhanceDialogue: false]
        await audio.refresh().value
        XCTAssertEqual(audio.values, [.enhanceDialogue: false])
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testPlayerInstancesShareSystemStateWithoutChangingEngineFlags() async {
        let backend = SystemAudioTestBackend()
        let audio = SystemPlaybackAudio(backend: backend)
        let vod = PlayerControlsModel(systemAudio: audio)
        let live = PlayerControlsModel(systemAudio: audio)
        backend.values = [.enhanceDialogue: true]
        await vod.systemAudio.refresh().value
        XCTAssertEqual(live.systemAudio.values, [.enhanceDialogue: true])
        XCTAssertFalse(vod.dialogEnhanceEnabled)
        XCTAssertFalse(live.dialogEnhanceEnabled)
        XCTAssertTrue(vod.engineCapabilities.isEmpty)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertTrue(PlayerControlsModel().systemAudio === PlayerControlsModel().systemAudio)
    }

    func testSystemOnlyRowsKeepAudioReachableForVODAndLive() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.reduceLoudSounds: false, .enhanceDialogue: false]
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.refresh().value
        let model = PlayerControlsModel(systemAudio: audio)
        for trackCount in 0...1 {
            model.audioOptions = trackCount == 0 ? [] : [.init(id: 42, title: Text("English"), isSelected: true)]
            XCTAssertTrue(model.hasAudioControls)
            XCTAssertEqual(model.trackControlCategories, [.audio])
            XCTAssertTrue(LiveChannelOverlay.showsAudio(trackCount: trackCount, systemAudio: audio))
            let rows = PlayerOptionsPanel.audioRows(model: model, actions: PlayerOptionsActions())
            XCTAssertEqual(rows.map(\.id), [-101, -100])
            XCTAssertTrue(rows.allSatisfy(\.isToggle))
            XCTAssertTrue(rows.allSatisfy { $0.subtitle == nil && !$0.startsSection })
            XCTAssertFalse(rows.contains(where: \.isSelected))
            XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .audio, subtitleScreen: .tracks, model: model),
                           .row(-101))
        }
        backend.values = [:]
        await audio.refresh().value
        XCTAssertFalse(model.hasAudioControls)
        XCTAssertFalse(LiveChannelOverlay.showsAudio(trackCount: 1, systemAudio: audio))
        XCTAssertTrue(LiveChannelOverlay.showsAudio(trackCount: 2, systemAudio: audio))
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testTrackSelectionAndEngineEffectStaySeparateFromSystemEffects() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: true]
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.refresh().value
        let model = PlayerControlsModel(systemAudio: audio)
        model.audioOptions = [
            .init(id: 12, title: Text("English"), isSelected: false),
            .init(id: 27, title: Text("French"), isSelected: true)
        ]
        model.engineCapabilities = [.dialogEnhance]
        var selections: [Int] = []
        var enhancements: [Bool] = []
        let rows = PlayerOptionsPanel.audioRows(model: model, actions: PlayerOptionsActions(
            selectAudio: { selections.append($0) }, setDialogEnhance: { enhancements.append($0) }
        ))
        XCTAssertEqual(rows.map(\.id), [-101, 0, 1, 2])
        XCTAssertEqual(rows.filter(\.startsSection).map(\.id), [0])
        XCTAssertTrue(rows[1].marqueeTitle)
        XCTAssertTrue(rows[2].marqueeTitle)
        rows[1].action()
        rows[3].action()
        XCTAssertEqual(selections, [12])
        XCTAssertEqual(enhancements, [true])
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(PlayerOptionsPanel.selectedRowIndex(for: .audio, model: model), 1)
    }

    func testBothEffectsCanBeEnabledAndDisabledWithReadback() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.reduceLoudSounds: false, .enhanceDialogue: false]
        let audio = SystemPlaybackAudio(backend: backend)
        for setting in SystemPlaybackAudioSetting.allCases {
            await audio.setEnabled(true, for: setting)
            XCTAssertEqual(audio.values[setting], true)
            await audio.setEnabled(false, for: setting)
            XCTAssertEqual(audio.values[setting], false)
            XCTAssertNil(audio.failure)
            XCTAssertTrue(audio.pending.isEmpty)
        }
        XCTAssertEqual(backend.writes.map(\.1), [true, false, true, false])
    }

    func testDelayedAcknowledgementKeepsActualStateAndIgnoresRepeatPresses() async throws {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: false]
        backend.onSet = { _, _ in }
        let audio = SystemPlaybackAudio(backend: backend)
        let change = Task { await audio.setEnabled(true, for: .enhanceDialogue) }
        defer { change.cancel() }
        let deadline = ContinuousClock.now + .seconds(1)
        while backend.writes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertTrue(audio.pending.contains(.enhanceDialogue))
        XCTAssertEqual(audio.values[.enhanceDialogue], false)
        await audio.setEnabled(true, for: .enhanceDialogue)
        XCTAssertEqual(backend.writes.count, 1)
        backend.values[.enhanceDialogue] = true
        await change.value
        XCTAssertEqual(audio.values[.enhanceDialogue], true)
        XCTAssertNil(audio.failure)
        XCTAssertTrue(audio.pending.isEmpty)
    }

    func testUnacknowledgedChangeSurfacesFailureWithoutOptimisticCheckmark() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.reduceLoudSounds: false]
        backend.onSet = { _, _ in }
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.setEnabled(true, for: .reduceLoudSounds)
        XCTAssertEqual(audio.failure, .unconfirmed)
        XCTAssertEqual(audio.values[.reduceLoudSounds], false)
        XCTAssertTrue(audio.pending.isEmpty)
    }

    func testUnsupportedOrRejectedChangesAreVisibleFailures() async {
        let backend = SystemAudioTestBackend()
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.setEnabled(true, for: .enhanceDialogue)
        XCTAssertEqual(audio.failure, .unavailable)
        XCTAssertTrue(backend.writes.isEmpty)
        backend.values[.enhanceDialogue] = false
        backend.onSet = { _, _ in throw SystemPlaybackAudio.Failure.unavailable }
        await audio.setEnabled(true, for: .enhanceDialogue)
        XCTAssertEqual(audio.failure, .unavailable)
        XCTAssertEqual(audio.values[.enhanceDialogue], false)
        XCTAssertTrue(audio.pending.isEmpty)
    }

    func testRouteLossDuringAcknowledgementDoesNotClaimSuccess() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: false]
        backend.onSet = { [weak backend] _, _ in backend?.values = [:] }
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.setEnabled(true, for: .enhanceDialogue)
        XCTAssertEqual(audio.failure, .unavailable)
        XCTAssertTrue(audio.values.isEmpty)
        XCTAssertTrue(audio.pending.isEmpty)
    }

    func testCancelledRequestDoesNotWriteAndUnchangedRequestDoesNotPost() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.reduceLoudSounds: false]
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.setEnabled(false, for: .reduceLoudSounds)
        let task = Task { await audio.setEnabled(true, for: .reduceLoudSounds) }
        task.cancel()
        await task.value
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNil(audio.failure)
        XCTAssertTrue(audio.pending.isEmpty)
    }

    func testDialogueLevelsUseSystemCommandsAndPreserveExistingIsolateState() {
        XCTAssertEqual(SystemDialogueLevel.enhance.command.name.rawValue,
                       "com.apple.TVPAudioVideoSettings.setEnhanceDialogueLevel")
        XCTAssertEqual(SystemDialogueLevel.enhance.command.object, "1")
        XCTAssertEqual(SystemDialogueLevel.enhanceMore.command.object, "2")
        XCTAssertEqual(SystemDialogueLevel.off.command.name.rawValue,
                       "com.apple.TVPAudioVideoSettings.disableEnhanceDialog")
        XCTAssertNil(SystemDialogueLevel.off.command.object)
        XCTAssertEqual(SystemDialogueLevel.effective(enabled: false, rawValue: 2), .off)
        for raw in [nil, -1, 0, 99] {
            XCTAssertEqual(SystemDialogueLevel.effective(enabled: true, rawValue: raw), .enhance)
        }
        XCTAssertEqual(SystemDialogueLevel.effective(enabled: true, rawValue: 2), .enhanceMore)
        XCTAssertEqual(SystemDialogueLevel.effective(enabled: true, rawValue: 3), .isolate)
        XCTAssertEqual(SystemDialogueLevel.choices, [.enhanceMore, .enhance, .off])
    }

    func testDialogueSubmenuReplacesToggleOnlyWhenLevelsAreAvailable() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: true, .reduceLoudSounds: false]
        let model = PlayerControlsModel(systemAudio: SystemPlaybackAudio(backend: backend))
        await model.systemAudio.refresh().value
        XCTAssertNil(PlayerOptionsPanel.audioRows(model: model, actions: .init())[0].submenu)
        backend.dialogueLevel = .enhanceMore
        await model.systemAudio.refresh().value
        var opened = false
        let rows = PlayerOptionsPanel.audioRows(model: model, actions: .init(), openDialogue: { opened = true })
        guard case let .submenu(summary, open)? = rows[0].submenu?.kind else {
            return XCTFail("Dialogue levels must be a submenu, not a toggle.")
        }
        XCTAssertEqual(summary, Text(SystemDialogueLevel.enhanceMore.title))
        open()
        XCTAssertTrue(opened)
        opened = false
        rows[0].action()
        XCTAssertTrue(opened)
        XCTAssertFalse(rows[0].isToggle)
        XCTAssertNil(rows[0].subtitle)
        XCTAssertFalse(rows.contains(where: \.startsSection), "No divider without a track group.")
        let choices = PlayerOptionsPanel.dialogueRows(model: model)
        XCTAssertEqual(choices.map(\.id), [-202, -201, -200])
        XCTAssertEqual(choices.filter(\.isSelected).map(\.id), [-202])
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(
            for: .audio, subtitleScreen: .tracks, model: model, audioScreen: .dialogue
        ), .row(-202))
        backend.dialogueLevel = .isolate
        await model.systemAudio.refresh().value
        XCTAssertFalse(PlayerOptionsPanel.dialogueRows(model: model).contains(where: \.isSelected))
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertTrue(backend.levelWrites.isEmpty)
    }

    func testDialogueLevelsConfirmEnablementAndStrengthIncludingOff() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: false]
        backend.dialogueLevel = .off
        let audio = SystemPlaybackAudio(backend: backend)
        for level in [SystemDialogueLevel.enhance, .enhanceMore, .off] {
            await audio.setDialogueLevel(level)
            XCTAssertEqual(audio.dialogueLevel, level)
            XCTAssertEqual(audio.values[.enhanceDialogue], level != .off)
            XCTAssertNil(audio.failure)
            XCTAssertTrue(audio.pending.isEmpty)
        }
        XCTAssertEqual(backend.levelWrites, [.enhance, .enhanceMore, .off])
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testEnablingDialogueWithoutRequestedStrengthIsNotSuccess() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: true]
        backend.dialogueLevel = .enhance
        backend.onSetLevel = { _ in }
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.setDialogueLevel(.enhanceMore)
        XCTAssertEqual(audio.failure, .unconfirmed)
        XCTAssertEqual(audio.dialogueLevel, .enhance)
    }

    func testUnsupportedLevelsAndIsolateNeverPostCommands() async {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: true]
        let audio = SystemPlaybackAudio(backend: backend)
        await audio.setDialogueLevel(.enhanceMore)
        XCTAssertEqual(audio.failure, .unavailable)
        backend.dialogueLevel = .enhance
        await audio.setDialogueLevel(.isolate)
        XCTAssertEqual(audio.failure, .unavailable)
        XCTAssertTrue(backend.levelWrites.isEmpty)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testPendingDialogueChoiceCannotDismissBeforeTheRequestedLevelIsConfirmed() async throws {
        let backend = SystemAudioTestBackend()
        backend.values = [.enhanceDialogue: true]
        backend.dialogueLevel = .enhance
        backend.onSetLevel = { _ in }
        let model = PlayerControlsModel(systemAudio: SystemPlaybackAudio(backend: backend))
        await model.systemAudio.refresh().value
        var returns = 0
        let rows = PlayerOptionsPanel.dialogueRows(model: model, selected: { returns += 1 })
        try XCTUnwrap(rows.first { $0.id == -202 }).action()
        let started = ContinuousClock.now + .seconds(1)
        while backend.levelWrites.isEmpty, ContinuousClock.now < started {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(backend.levelWrites, [.enhanceMore])
        try XCTUnwrap(rows.first { $0.id == -201 }).action()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(returns, 0, "Selecting the old level during a pending change must not dismiss the submenu.")
        backend.dialogueLevel = .enhanceMore
        let confirmed = ContinuousClock.now + .seconds(1)
        while returns == 0, ContinuousClock.now < confirmed {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(model.systemAudio.dialogueLevel, .enhanceMore)
        XCTAssertEqual(backend.levelWrites, [.enhanceMore])
    }
}
#endif
