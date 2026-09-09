import AppKit
import Combine
import ServiceManagement
import Sparkle

final class AppSettings: ObservableObject {
    @Published private(set) var launchAtLogin = false
    @Published private(set) var needsLoginApproval = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticUpdates = false
    @Published var error: String?
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var observations: [NSKeyValueObservation] = []

    init() {
        observations.append(controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.canCheckForUpdates = updater.canCheckForUpdates }
        })
        observations.append(controller.updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.automaticUpdates = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates }
        })
        observations.append(controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.automaticUpdates = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates }
        })
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        needsLoginApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Could not change launch at login: \(error.localizedDescription)" }
        refreshLoginStatus()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func setAutomaticUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
        automaticUpdates = enabled
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
