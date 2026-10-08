import AppIntents

enum NoiseChoice: String, AppEnum {
    case anc, transparency, off
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Noise mode"
    static var caseDisplayRepresentations: [NoiseChoice: DisplayRepresentation] = [
        .anc: "Noise cancelling", .transparency: "Transparency", .off: "Off"
    ]
    var mode: NoiseMode { switch self { case .anc: .anc; case .transparency: .transparency; case .off: .off } }
}

struct SetNoiseModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Redmi Buds noise mode"
    static var description = IntentDescription("Change noise cancelling, transparency or off on your connected REDMI Buds 8 Pro.")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    @Parameter(title: "Mode") var mode: NoiseChoice
    init() {}
    init(_ mode: NoiseChoice) { self.mode = mode }
    static var parameterSummary: some ParameterSummary { Summary("Set Redmi Buds to \(\.$mode)") }
    func perform() async throws -> some IntentResult {
        await BudsDiagnostics.record("intentStarted", ["action": "setMode", "mode": mode.rawValue])
        do {
            try await BLEBuds.shared.setMode(mode.mode)
            await BudsDiagnostics.record("intentSucceeded", ["action": "setMode"])
        } catch {
            await BudsDiagnostics.record("intentFailed", ["action": "setMode", "error": error.localizedDescription])
            throw error
        }
        return .result()
    }
}

struct BudsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetNoiseModeIntent(.anc), phrases: ["Turn on noise cancelling with \(.applicationName)"], shortTitle: "Noise cancelling", systemImageName: "ear.badge.waveform")
        AppShortcut(intent: SetNoiseModeIntent(.transparency), phrases: ["Turn on transparency with \(.applicationName)"], shortTitle: "Transparency", systemImageName: "ear")
        AppShortcut(intent: SetNoiseModeIntent(.off), phrases: ["Turn off noise control with \(.applicationName)"], shortTitle: "Noise off", systemImageName: "speaker.wave.2")
    }
}

struct CycleNoiseModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Cycle Redmi Buds noise mode"
    static var description = IntentDescription("Cycle noise cancelling → transparency → off, starting from the buds’ current mode.")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    func perform() async throws -> some IntentResult {
        await BudsDiagnostics.record("intentStarted", ["action": "cycle"])
        do {
            try await BLEBuds.shared.cycleMode()
            await BudsDiagnostics.record("intentSucceeded", ["action": "cycle"])
        } catch {
            await BudsDiagnostics.record("intentFailed", ["action": "cycle", "error": error.localizedDescription])
            throw error
        }
        return .result()
    }
}
