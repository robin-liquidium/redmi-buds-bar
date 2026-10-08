import AppKit
import Combine
import SwiftUI
import BudsCore

struct BudsView: View {
    @ObservedObject var buds: BudsController
    @ObservedObject var settings: AppSettings
    @ObservedObject var media: NowPlayingController
    var checkForUpdates: () -> Void
    var showEarbudSettings: () -> Void
    var showFirmware: () -> Void
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
            NowPlayingView(media: media)
            if let error = settings.error ?? buds.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button(buds.connected ? "Refresh" : "Reconnect") {
                    if buds.connected { buds.refresh() } else { buds.reconnect() }
                }.disabled(buds.changing || buds.updatingFirmware)
                Spacer()
                Menu {
                    Toggle("Always show menu bar icon", isOn: $settings.alwaysShowMenuBarIcon)
                    Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin))
                    if settings.needsLoginApproval {
                        Button("Allow in Login Items…", action: settings.openLoginSettings)
                    }
                    Toggle("Automatic updates", isOn: Binding(get: { settings.automaticUpdates }, set: settings.setAutomaticUpdates))
                    Button("Check for app updates…", action: checkForUpdates).disabled(!settings.canCheckForUpdates || buds.updatingFirmware)
                    Button("Earbud settings…", action: showEarbudSettings)
                    Button("Earbud firmware…", action: showFirmware)
                    Divider()
                    Text("Redmi Buds Bar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    if !buds.firmware.isEmpty { Text("Earbuds firmware \(buds.firmware)") }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Settings")
                Button("Quit") { NSApp.terminate(nil) }.disabled(buds.updatingFirmware)
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
        .disabled(!buds.connected || buds.noise == nil || buds.changing || buds.updatingFirmware)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("noise.\(mode.rawValue)")
    }

}

@MainActor
final class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    let buds = BudsController()
    let media = NowPlayingController()
    let firmwareUpdater = MacFirmwareUpdater()
    let settings = AppSettings()
    @Published var menuInserted = false
    private var menuVisible = false
    private var visibilityObservation: AnyCancellable?
    private var controlsWindow: NSWindow?
    private var earbudSettingsWindow: NSWindow?
    private var firmwareWindow: NSWindow?
    var logFile: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/RedmiBudsBar.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: logURL)
        buds.log = { [weak self] line in
            // Local diagnostic log, bounded to one app session and rotated at 256 KB.
            guard let self, let file = self.logFile else { return }
            if (try? file.offset()) ?? 0 > 262144 { try? file.truncate(atOffset: 0); try? file.seek(toOffset: 0) }
            try? file.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
        }
        if CommandLine.arguments.contains("--enable-login") { settings.setLaunchAtLogin(true) }
        buds.log?("Launch at login: enabled=\(settings.launchAtLogin), needsApproval=\(settings.needsLoginApproval)")
        visibilityObservation = buds.$bluetoothConnected.combineLatest(settings.$alwaysShowMenuBarIcon, buds.$updatingFirmware)
            .map { connected, alwaysShow, updating in connected || alwaysShow || updating }
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.menuInserted = visible
                self?.buds.log?("Menu bar visibility: inserted=\(visible)")
            }
        buds.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.showControls() }
        }
    }
    func controlsView() -> BudsView {
        BudsView(buds: buds, settings: settings, media: media,
                 checkForUpdates: { [weak self] in self?.settings.checkForUpdates() },
                 showEarbudSettings: { [weak self] in self?.showEarbudSettings() },
                 showFirmware: { [weak self] in self?.showFirmware() })
    }
    func menuDidOpen() {
        menuVisible = true
        media.start()
        buds.refresh()
        settings.refreshLoginStatus()
    }
    func menuDidClose() {
        menuVisible = false
        if controlsWindow?.isVisible != true { media.stop() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !menuVisible { showControls() }
        return false
    }
    private func showControls() {
        if controlsWindow == nil {
            let hosting = NSHostingController(rootView: controlsView())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Redmi Buds Bar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            controlsWindow = window
        }
        controlsWindow?.makeKeyAndOrderFront(nil)
        media.start()
        buds.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settings.refreshLoginStatus()
    }
    private func showEarbudSettings() {
        if earbudSettingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: EarbudSettingsView(buds: buds)))
            window.title = "Earbud settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            earbudSettingsWindow = window
        }
        earbudSettingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func showFirmware() {
        if firmwareWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: FirmwareView(buds: buds, updater: firmwareUpdater)))
            window.title = "Earbud firmware"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            firmwareWindow = window
        }
        firmwareWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === firmwareWindow { firmwareWindow = nil }
        else if notification.object as? NSWindow === earbudSettingsWindow { earbudSettingsWindow = nil }
        else { controlsWindow = nil }
        if !menuVisible && controlsWindow?.isVisible != true { media.stop() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        buds.updatingFirmware ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { media.stop(); buds.stop(); try? logFile?.close() }
}

@main
struct RedmiBudsBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        BudsMenuScene(delegate: delegate)
    }
}

private struct BudsMenuScene: Scene {
    @ObservedObject var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { delegate.menuInserted }, set: { visible in
            if delegate.menuInserted != visible { delegate.menuInserted = visible }
        })) {
            delegate.controlsView()
                .onAppear { delegate.menuDidOpen() }
                .onDisappear { delegate.menuDidClose() }
        } label: {
            Image(systemName: "earbuds")
                .accessibilityLabel("Redmi Buds controls")
                .accessibilityIdentifier("redmi.status")
        }
        .menuBarExtraStyle(.window)
    }
}
