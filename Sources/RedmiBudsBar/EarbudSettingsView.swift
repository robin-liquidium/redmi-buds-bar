import SwiftUI
#if os(macOS)
import BudsCore
#endif

struct EarbudSettingsView: View {
    #if os(macOS)
    @ObservedObject var buds: BudsController
    #else
    @ObservedObject var buds: BLEBuds
    #endif
    @State private var working = false
    @State private var confirmFind = false
    @State private var findingTask: Task<Void, Never>?
    @State private var actionResult: String?
    @State private var failure: String?
    private var busy: Bool { working || buds.changing || buds.updatingFirmware }
    var body: some View {
        Form {
            if let settings = buds.earbudSettings {
                ForEach(EarbudSide.allCases, id: \.rawValue) { side in
                    Section(side.title) {
                        ForEach(EarbudGesture.allCases, id: \.rawValue) { kind in
                            if let value = settings.action(kind, side: side) {
                                Picker(kind.title, selection: Binding(get: { value }, set: { if let action = GestureAction(rawValue: $0) { edit(.assignment(kind, side, action)) } })) {
                                    if !kind.actions.contains(where: { $0.rawValue == value }) { Text("Unknown action (\(value))").tag(value) }
                                    ForEach(kind.actions, id: \.rawValue) { action in Text(action.title).tag(action.rawValue) }
                                }
                            }
                        }
                        if settings.action(.hold, side: side) == GestureAction.noiseControl.rawValue, let mask = settings.noiseMask(side) {
                            Picker("Noise cycle", selection: Binding(get: { mask }, set: { edit(.noiseCycle(side, $0)) })) {
                                Text("Off + noise cancelling").tag(UInt8(3))
                                Text("Off + transparency").tag(UInt8(5))
                                Text("Noise cancelling + transparency").tag(UInt8(6))
                                Text("All three modes").tag(UInt8(7))
                            }
                        }
                    }
                }
                Section {
                    if let value = settings.wearDetection {
                        Toggle("In-ear detection", isOn: Binding(get: { value }, set: { edit(.wearDetection($0)) }))
                    }
                    if let value = settings.multipoint {
                        Toggle("Dual connection", isOn: Binding(get: { value }, set: { edit(.multipoint($0)) }))
                    }
                    if let value = settings.autoAnswer {
                        Toggle("Take calls automatically", isOn: Binding(get: { value }, set: { edit(.autoAnswer($0)) }))
                    }
                } header: { Text("Behavior") } footer: {
                    Text("Call gestures are handled separately by the earbud firmware. Setting taps or holds to None does not disable call hang-up. A separate hang-up setting has not been identified for this model.")
                }
                Section("Sound") {
                    ForEach(EarbudToggle.allCases, id: \.rawValue) { option in
                        if let value = settings.boolean(option.rawValue) {
                            Toggle(option.title, isOn: Binding(get: { value }, set: { edit(.toggle(option, $0)) }))
                        }
                    }
                    if let engine = settings.value(0x68), engine.count == 1, engine[0] <= 1 {
                        Picker("Dimensional audio engine", selection: Binding(get: { engine[0] }, set: { edit(.audioEngine($0)) })) {
                            Text("Xiaomi").tag(UInt8(0)); Text("Dolby Audio").tag(UInt8(1))
                        }
                    }
                    if let mode = settings.spatialMode, let byte = settings.spatialByte {
                        Picker("Dimensional audio", selection: Binding(get: { mode.rawValue }, set: { edit(.spatial(SpatialMode(rawValue: $0)!)) })) {
                            ForEach(SpatialMode.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode.rawValue) }
                        }
                        Picker("Audio preference", selection: Binding(get: { (byte >> 1) & 3 }, set: { edit(.spatialPreference($0)) })) {
                            Text("Sound quality").tag(UInt8(0))
                            Text("Low latency").tag(UInt8(1))
                        }
                    }
                    if let value = settings.value(0x36), value.first == 0 || value.first == 1, value.count <= 2 {
                        Picker("Audio scene", selection: Binding(get: { value.first == 0 ? UInt8(0) : value.count == 2 ? value[1] : 0 }, set: { edit(.scene($0)) })) {
                            Text("Off").tag(UInt8(0)); Text("Standard").tag(UInt8(1)); Text("Music").tag(UInt8(2))
                            Text("Video").tag(UInt8(3)); Text("Games").tag(UInt8(4)); Text("Audiobooks").tag(UInt8(5))
                        }
                    }
                }
                if let value = settings.value(7), value.count == 1, value != [0xff] {
                    Section("Equalizer") {
                        Picker("Preset", selection: Binding(get: { value[0] }, set: { edit(.equalizerPreset($0)) })) {
                            Text("Default").tag(UInt8(0)); Text("Bass").tag(UInt8(5)); Text("Voice").tag(UInt8(1))
                            Text("Treble").tag(UInt8(6)); Text("Custom").tag(UInt8(10))
                        }
                        if value[0] == 10, let eq = settings.equalizer {
                            ForEach(eq.bands, id: \.frequency) { band in
                                EqualizerBandView(band: band, bound: eq.bound) { edit(.equalizerBand(band.frequency, $0)) }
                            }
                            Text("Release a slider to save. Other bands are preserved.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

            } else {
                Text("Connect your earbuds to load their settings.").foregroundStyle(.secondary)
            }
            Section("Tools") {
                Button("Ear tip fit test") { action(.fitTest) }
                Text("Wear both earbuds and sit somewhere quiet. The test plays a short sound.").font(.caption).foregroundStyle(.secondary)
                Button("Find earbuds…") { confirmFind = true }
                Button("Stop sound") { findingTask?.cancel(); action(.stopFinding) }
                if let actionResult { Text(actionResult).foregroundStyle(.secondary) }
                Text("Rename the earbuds in your system’s Bluetooth settings.").font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Section { Text(failure).foregroundStyle(.orange) } }
            Section {
                Button { Task { await reload() } } label: {
                    HStack { if working { ProgressView().controlSize(.small) }; Label("Refresh settings", systemImage: "arrow.clockwise") }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .task { await reload() }
        .alert("Play find sound?", isPresented: $confirmFind) {
            Button("Play sound") { action(.find(3)) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Take both earbuds out of your ears. They will play a loud sound. Keep this app open; it requests Stop sound after 30 seconds. You can stop it sooner using Stop sound.") }
        #if os(macOS)
        .frame(width: 540, height: 680)
        #else
        .navigationTitle("Earbud settings")
        #endif
    }
    @MainActor private func reload() async {
        guard !busy else { return }
        working = true; failure = nil
        defer { working = false }
        do { try await buds.readEarbudSettings() }
        catch { failure = error.localizedDescription }
    }
    private func action(_ requested: EarbudAction) {
        guard !busy else { return }
        working = true; failure = nil
        Task { @MainActor in
            defer { working = false }
            do {
                actionResult = try await buds.performEarbudAction(requested)
                if case .find = requested {
                    findingTask?.cancel()
                    findingTask = Task { @MainActor in
                        do {
                            try await Task.sleep(for: .seconds(30))
                            actionResult = try await buds.performEarbudAction(.stopFinding)
                        } catch is CancellationError {} catch { failure = error.localizedDescription }
                    }
                }
            } catch { failure = error.localizedDescription }
        }
    }
    private func edit(_ change: EarbudEdit) {
        guard !busy else { return }
        working = true; failure = nil
        Task { @MainActor in
            defer { working = false }
            do { try await buds.editEarbudSetting(change) }
            catch { failure = error.localizedDescription }
        }
    }
}

private struct EqualizerBandView: View {
    let band: EqualizerBand
    let bound: Int
    var save: (Int) -> Void
    @State private var gain: Double
    init(band: EqualizerBand, bound: Int, save: @escaping (Int) -> Void) {
        self.band = band; self.bound = bound; self.save = save
        _gain = State(initialValue: Double(band.gain))
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("\(band.frequency) Hz"); Spacer(); Text("\(Int(gain)) dB").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $gain, in: Double(-bound)...Double(bound), step: 1) { editing in
                if !editing { save(Int(gain)) }
            }
        }
        .onChange(of: band.gain) { gain = Double(band.gain) }
    }
}
