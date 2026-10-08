import AppKit
import Combine
import SwiftUI
import BudsCore

@MainActor
final class MacFirmwareUpdater: ObservableObject {
    @Published private(set) var release: FirmwareService.Release?
    @Published private(set) var working = false
    @Published private(set) var downloaded = false
    @Published private(set) var upToDate = false
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""
    private var image: MMAFirmwareImage?
    private var updateTask: Task<Void, Never>?

    func check(_ buds: BudsController) async {
        guard !working else { return }
        working = true
        defer { working = false }
        release = nil; image = nil; downloaded = false; upToDate = false; progress = nil
        message = "Checking Xiaomi's firmware service…"
        do {
            try await buds.checkFirmwareVersions()
            let result = try await FirmwareService.latest(current: buds.firmware)
            release = result
            reconcileVersion(buds)
            message = upToDate ? "Both earbuds are up to date." : "Firmware \(result.title) is available."
            buds.log?("Official firmware check: version=\(result.title) upToDate=\(upToDate)")
        } catch { message = error.localizedDescription; buds.log?("Firmware check failed: \(message)") }
    }
    func download(_ buds: BudsController) async {
        guard !working, let release else { return }
        working = true
        defer { working = false }
        message = "Downloading and validating firmware…"
        do {
            let verified = try await FirmwareService.download(release)
            image = verified; downloaded = true
            message = "Firmware downloaded and verified. Prepare both earbuds before updating."
            buds.log?("Official firmware download verified: version=\(verified.versionName) bytes=\(verified.bytes.count)")
        } catch { message = error.localizedDescription; buds.log?("Firmware download failed: \(message)") }
    }
    func startUpdate(_ buds: BudsController) {
        guard !working, let image, !upToDate else { return }
        working = true; progress = 0
        updateTask = Task {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Updating REDMI Buds firmware")
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                working = false; updateTask = nil
            }
            do {
                try await buds.installFirmware(image) { value, status in
                    self.progress = value; self.message = status
                }
                upToDate = true
                message = "Both earbuds are running firmware \(image.versionName). Update complete."
            } catch { message = error is CancellationError ? "Update cancelled." : error.localizedDescription }
        }
    }
    func cancel() { updateTask?.cancel(); message = "Cancelling the update…" }
    func reconcileVersion(_ buds: BudsController) {
        guard let target = release?.code,
              let primary = MMAFirmwareImage.versionCode(buds.firmware),
              let peer = buds.peerFirmware.flatMap(MMAFirmwareImage.versionCode) else { upToDate = false; return }
        upToDate = primary >= target && peer >= target
        guard upToDate else { return }
        if !working { message = "Both earbuds are up to date."; if progress != nil { progress = 1 } }
    }
}

struct FirmwareView: View {
    @ObservedObject var buds: BudsController
    @ObservedObject var updater: MacFirmwareUpdater
    var body: some View {
        Form {
            Section("Installed firmware") {
                LabeledContent("Primary earbud", value: buds.firmware.isEmpty ? "Unavailable" : buds.firmware)
                LabeledContent("Other earbud", value: buds.peerFirmware ?? "Unavailable")
            }
            Section {
                Button("Check for firmware updates") { Task { await updater.check(buds) } }
                    .disabled(updater.working)
                if let release = updater.release, !updater.upToDate {
                    LabeledContent("Available", value: release.title)
                    Text(release.changeLog).font(.callout)
                    if !updater.downloaded {
                        Button("Download firmware") { Task { await updater.download(buds) } }.disabled(updater.working)
                    } else {
                        Button("Update earbuds") { updater.startUpdate(buds) }.disabled(updater.working)
                    }
                }
                if updater.working, updater.progress == nil { ProgressView().controlSize(.small) }
                if let progress = updater.progress { ProgressView(value: progress) }
                if !updater.message.isEmpty { Text(updater.message).font(.callout).textSelection(.enabled) }
                if buds.updatingFirmware, let progress = updater.progress, progress < 1 {
                    Button("Cancel update", role: .destructive) { updater.cancel() }
                }
            }
            Section("Before updating") {
                Text("Charge both earbuds and the case. Put both earbuds in the case and leave the lid open. Disconnect the buds from your iPhone and other devices during the update.")
                Text("Firmware downloads directly from Xiaomi. No Xiaomi app or account is required.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 550)
        .onChange(of: [buds.firmware, buds.peerFirmware ?? ""]) { _, _ in updater.reconcileVersion(buds) }
    }
}
