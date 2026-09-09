import SwiftUI
import BudsCore

struct StrengthControl: View {
    @ObservedObject var buds: BudsController
    let setting: NoiseSetting
    @State private var value: Double
    @State private var editing = false

    init(buds: BudsController, setting: NoiseSetting) {
        self.buds = buds
        self.setting = setting
        _value = State(initialValue: Double(setting.strength))
    }

    var body: some View {
        if let range = setting.mode.strengthRange {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(setting.mode == .anc ? "Noise cancelling strength" : "Transparency")
                    Spacer()
                    Text(setting.mode.strengthLabel(UInt8(clamping: Int(value))))
                        .foregroundStyle(.secondary).monospacedDigit()
                }.font(.caption)
                Slider(value: $value, in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { isEditing in
                    editing = isEditing
                    if !isEditing { apply() }
                }
                .disabled(!buds.connected || buds.changing)
                .accessibilityLabel(setting.mode == .anc ? "Noise cancelling strength" : "Transparency preset")
                .accessibilityValue(setting.mode.strengthLabel(UInt8(clamping: Int(value))))
                .accessibilityIdentifier("strength.\(setting.mode.rawValue)")
                HStack {
                    Text(setting.mode == .anc ? "Less" : "Regular")
                    Spacer()
                    if setting.mode == .transparency { Text("Voice"); Spacer() }
                    Text(setting.mode == .anc ? "More" : "Ambient")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            .onChange(of: value) { _, _ in
                // Keyboard and accessibility adjustments need no drag-end event.
                if !editing { apply() }
            }
            .onChange(of: setting) { _, actual in
                if !editing { value = Double(actual.strength) }
            }
            .onChange(of: buds.changing) { _, changing in
                // On failure, return to the last device-confirmed position too.
                if !changing, !editing { value = Double(setting.strength) }
            }
        }
    }

    private func apply() {
        guard !buds.changing, let current = buds.noise, current.mode == setting.mode else { return }
        let strength = UInt8(clamping: Int(value.rounded()))
        guard strength != current.strength else { return }
        buds.setStrength(strength, for: setting.mode)
    }
}
