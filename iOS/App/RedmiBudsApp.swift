import SwiftUI

@main struct RedmiBudsApp: App {
    var body: some Scene { WindowGroup { BudsView() } }
}
struct BudsView: View {
    @ObservedObject private var buds = BLEBuds.shared
    @Environment(\.scenePhase) private var phase
    @State private var strength: Double = 19
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: "earbuds").font(.largeTitle).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("REDMI Buds 8 Pro").font(.headline)
                            Label(buds.status, systemImage: buds.noise != nil && buds.error == nil ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                                .font(.caption).foregroundStyle(buds.noise != nil && buds.error == nil ? .green : .secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await buds.refresh() }
                        } label: {
                            Group {
                                if buds.refreshingManually { ProgressView() }
                                else { Image(systemName: "arrow.clockwise") }
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .disabled(buds.refreshingManually || buds.changing || buds.updatingFirmware)
                        .accessibilityLabel("Refresh")
                        .accessibilityIdentifier("refresh")
                    }.padding(.vertical, 8)
                    HStack {
                        battery("Left", buds.left)
                        battery("Right", buds.right)
                        battery("Case", buds.caseBattery)
                    }
                }
                Section("Noise control") {
                    ForEach(NoiseMode.allCases, id: \.rawValue) { mode in
                        Button {
                            Task { try? await buds.setMode(mode) }
                        } label: {
                            HStack {
                                Label(mode.title, systemImage: mode.symbol)
                                Spacer()
                                if buds.noise?.mode == mode { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }
                        }.disabled(!buds.canControl || buds.changing || buds.updatingFirmware)
                        .accessibilityIdentifier("mode.\(mode.rawValue)")
                    }
                    if buds.changing { HStack { ProgressView(); Text("Confirming change…").foregroundStyle(.secondary) } }
                }
                if let noise = buds.noise {
                    if noise.mode == .anc {
                        Section("Noise cancelling strength") {
                            Text(NoiseMode.anc.strengthLabel(UInt8(strength.rounded())))
                            Slider(value: $strength, in: 0...19, step: 1) { editing in
                                if !editing { Task { try? await buds.setMode(.anc, strength: UInt8(strength.rounded())); syncStrength() } }
                            }.disabled(buds.changing || buds.updatingFirmware)
                            Text("Adjusting the level uses manual noise cancelling.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if noise.mode == .transparency {
                        Section("Transparency") {
                            ForEach(UInt8(0)...UInt8(2), id: \.self) { value in
                                Button {
                                    Task { try? await buds.setMode(.transparency, strength: value) }
                                } label: {
                                    HStack {
                                        Text(NoiseMode.transparency.strengthLabel(value))
                                        Spacer()
                                        if noise.strength == value { Image(systemName: "checkmark") }
                                    }
                                }.disabled(buds.changing || buds.updatingFirmware)
                            }
                        }
                    }
                }
                if let error = buds.error {
                    Section { Text(error).foregroundStyle(.orange) }
                }
                Section {
                    NavigationLink {
                        FirmwareView(buds: buds)
                    } label: { LabeledContent("Firmware", value: buds.firmware) }
                }
                Section("Control Center") {
                    Text("Open Control Center, touch and hold, then choose Add a Control. Search for Redmi Buds and add Cycle noise mode. Each tap cycles noise cancelling → transparency → off; the icon shows the last confirmed mode.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.navigationTitle("Redmi Buds")
        }
        .task(id: phase) {
            guard phase == .active else { return }
            BudsDiagnostics.record("appOpened")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-noise") || ProcessInfo.processInfo.arguments.contains("--verify-connection") || ProcessInfo.processInfo.arguments.contains("--verify-firmware-readiness") {
                await DeviceVerification.run(buds)
                syncStrength()
                return
            }
            #endif
            while !Task.isCancelled {
                await buds.refresh(silently: true)
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        .onChange(of: buds.noise) { _, _ in syncStrength() }
        .onChange(of: phase) { _, next in
            BudsDiagnostics.record("scenePhase", ["phase": String(describing: next)])
        }
    }
    private func syncStrength() { if buds.noise?.mode == .anc { strength = Double(buds.noise?.strength ?? 19) } }
    private func battery(_ title: String, _ value: Battery?) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Label(value.map { "\($0.percent)%" } ?? "—", systemImage: value?.charging == true ? "battery.100percent.bolt" : "battery.100percent")
                .font(.subheadline.monospacedDigit())
        }.frame(maxWidth: .infinity).padding(.vertical, 5)
    }
}
