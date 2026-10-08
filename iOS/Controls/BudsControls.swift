import WidgetKit
import SwiftUI

@main struct BudsControls: WidgetBundle {
    var body: some Widget {
        CycleNoiseControl()
        ANCControl()
        TransparencyControl()
        NoiseOffControl()
    }
}
struct CycleNoiseControl: ControlWidget {
    struct Provider: ControlValueProvider {
        var previewValue: NoiseMode? { .anc }
        func currentValue() async throws -> NoiseMode? { NoiseControlState.load() }
    }
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: NoiseControlState.kind, provider: Provider()) { mode in
            ControlWidgetButton(action: CycleNoiseModeIntent()) {
                Label(mode?.title ?? "Noise mode", systemImage: mode?.symbol ?? "earbuds")
                    .controlWidgetActionHint("Cycle noise mode")
            }
        }.displayName("Cycle noise mode").description("Tap to cycle noise cancelling → transparency → off. The icon shows the last confirmed mode.")
    }
}
struct ANCControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "build.robin.RedmiBuds.anc") {
            ControlWidgetButton(action: SetNoiseModeIntent(.anc)) { Label("Noise cancelling", systemImage: "ear.badge.waveform") }
        }.displayName("Noise cancelling").description("Turn on noise cancelling on your Redmi Buds.")
    }
}
struct TransparencyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "build.robin.RedmiBuds.transparency") {
            ControlWidgetButton(action: SetNoiseModeIntent(.transparency)) { Label("Transparency", systemImage: "ear") }
        }.displayName("Transparency").description("Hear your surroundings through your Redmi Buds.")
    }
}
struct NoiseOffControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "build.robin.RedmiBuds.off") {
            ControlWidgetButton(action: SetNoiseModeIntent(.off)) { Label("Noise off", systemImage: "speaker.wave.2") }
        }.displayName("Noise off").description("Turn off noise cancelling and transparency.")
    }
}
