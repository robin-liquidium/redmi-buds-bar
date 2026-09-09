import AppKit
import SwiftUI
import BudsCore

struct BudsView: View {
    @ObservedObject var buds: BudsController
    @ObservedObject var settings: AppSettings
    var checkForUpdates: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "earbuds").font(.system(size: 28)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("REDMI Buds 8 Pro").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(buds.connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(buds.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if buds.connected {
                HStack(spacing: 8) {
                    battery("Left", buds.left)
                    battery("Right", buds.right)
                    battery("Case", buds.caseBattery)
                }
                Divider()
                Text("Noise control").font(.subheadline.weight(.semibold))
                HStack(alignment: .top, spacing: 8) {
                    modeButton(.off)
                    modeButton(.transparency)
                    modeButton(.anc)
                }
                if let noise = buds.noise, noise.mode.strengthRange != nil {
                    StrengthControl(buds: buds, setting: noise)
                        .id(noise.mode)
                }
                if buds.changing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Confirming change…").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error = settings.error ?? buds.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button(buds.connected ? "Refresh" : "Reconnect") {
                    if buds.connected { buds.refresh() } else { buds.reconnect() }
                }.disabled(buds.changing)
                Spacer()
                Menu {
                    Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin))
                    if settings.needsLoginApproval {
                        Button("Allow in Login Items…", action: settings.openLoginSettings)
                    }
                    Toggle("Automatic updates", isOn: Binding(get: { settings.automaticUpdates }, set: settings.setAutomaticUpdates))
                    Button("Check for updates…", action: checkForUpdates).disabled(!settings.canCheckForUpdates)
                    Divider()
                    Text("Redmi Buds Bar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    if !buds.firmware.isEmpty { Text("Earbuds firmware \(buds.firmware)") }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Settings")
                Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless).font(.caption)
            if !buds.connected {
                Button("Open Bluetooth settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }.font(.caption)
            }
        }
        .padding(20)
        .frame(width: 352)
    }
    private func battery(_ title: String, _ battery: Battery?) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if battery?.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                Text(battery.map { "\($0.percent)%" } ?? "—").monospacedDigit().fontWeight(.medium)
            }.font(.callout)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) battery, \(battery.map { "\($0.percent) percent" } ?? "unavailable")")
    }
    private func modeButton(_ mode: NoiseMode) -> some View {
        let selected = buds.noise?.mode == mode
        return Button { buds.setMode(mode) } label: {
            VStack(spacing: 9) {
                Image(systemName: mode.symbol).font(.system(size: 21)).frame(height: 27)
                Text(mode.title).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center).frame(height: 29, alignment: .top)
            }
            .frame(maxWidth: .infinity).padding(.top, 13).padding(.bottom, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!buds.connected || buds.noise == nil || buds.changing)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("noise.\(mode.rawValue)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let buds = BudsController()
    var settings: AppSettings!
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var logFile: FileHandle?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/RedmiBudsBar.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: logURL)
        buds.log = { [weak self] line in
            // Local diagnostic log, bounded to one app session and rotated at 256 KB.
            guard let self, let file = self.logFile else { return }
            if (try? file.offset()) ?? 0 > 262144 { try? file.truncate(atOffset: 0); try? file.seek(toOffset: 0) }
            try? file.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "earbuds", accessibilityDescription: "Redmi Buds controls")
            button.image?.isTemplate = true
            button.toolTip = "Redmi Buds controls"
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityIdentifier("redmi.status")
        }
        popover.behavior = .transient
        settings = AppSettings()
        if CommandLine.arguments.contains("--enable-login") { settings.setLaunchAtLogin(true) }
        buds.log?("Launch at login: enabled=\(settings.launchAtLogin), needsApproval=\(settings.needsLoginApproval)")
        let hosting = NSHostingController(rootView: BudsView(buds: buds, settings: settings, checkForUpdates: { [weak self] in
            self?.popover.performClose(nil)
            DispatchQueue.main.async { self?.settings.checkForUpdates() }
        }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        buds.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.togglePopover() }
        }
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            buds.refresh()
            settings.refreshLoginStatus()
        }
    }
    func applicationWillTerminate(_ notification: Notification) { buds.stop(); try? logFile?.close() }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
