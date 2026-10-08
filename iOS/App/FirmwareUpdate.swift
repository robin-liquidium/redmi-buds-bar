import SwiftUI

@MainActor
final class FirmwareUpdater: ObservableObject {
    @Published private(set) var release: FirmwareService.Release?
    @Published private(set) var working = false
    @Published private(set) var message = ""
    @Published private(set) var progress: Double?
    @Published private(set) var upToDate = false
    @Published private(set) var downloaded = false
    private var image: MMAFirmwareImage?
    private var updateTask: Task<Void, Never>?

    func check(_ buds: BLEBuds) async {
        guard !working else { return }
        working = true
        defer { working = false }
        release = nil; image = nil; downloaded = false; upToDate = false; progress = nil
        message = "Checking Xiaomi's update service…"
        do {
            try await buds.connect()
            let result = try await FirmwareService.latest(current: buds.firmware)
            release = result
            BudsDiagnostics.record("firmwareUpdateAvailable", ["version": result.title])
            upToDate = result.code.map { target in
                MMAFirmwareImage.versionCode(buds.firmware).map { $0 >= target } == true &&
                buds.peerFirmware.flatMap(MMAFirmwareImage.versionCode).map { $0 >= target } == true
            } ?? false
            message = upToDate ? "Both earbuds are up to date." : "Firmware \(result.title) is available."
        } catch { message = error.localizedDescription; BudsDiagnostics.record("firmwareCheckFailed", ["error": message]) }
    }
    func download() async {
        guard !working, let release else { return }
        working = true
        defer { working = false }
        message = "Downloading and validating firmware…"
        do {
            image = try await FirmwareService.download(release)
            downloaded = true
            BudsDiagnostics.record("firmwareDownloadVerified", ["version": image!.versionName, "bytes": String(image!.bytes.count)])
            message = "Firmware is downloaded and verified. Prepare both earbuds before updating."
        } catch { message = error.localizedDescription; BudsDiagnostics.record("firmwareDownloadFailed", ["error": message]) }
    }
    func startUpdate(_ buds: BLEBuds) {
        guard !working, let image else { return }
        working = true; progress = 0
        updateTask = Task {
            let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
                working = false
                updateTask = nil
            }
            do {
                try await buds.installFirmware(image) { value, status in
                    self.progress = value
                    self.message = status
                }
                message = "Both earbuds are running firmware \(image.versionName). Update complete."
                upToDate = true
            } catch { message = error is CancellationError ? "Update cancelled." : error.localizedDescription }
        }
    }
    func cancel() { updateTask?.cancel(); message = "Cancelling the update…" }

    func reconcileVersion(_ buds: BLEBuds) {
        guard let target = release?.code,
              let current = MMAFirmwareImage.versionCode(buds.firmware),
              let peer = buds.peerFirmware.flatMap(MMAFirmwareImage.versionCode),
              current >= target, peer >= target else { return }
        upToDate = true
        if !working {
            message = "Both earbuds are up to date."
            if progress != nil { progress = 1 }
        }
    }
}

struct FirmwareView: View {
    @ObservedObject var buds: BLEBuds
    @StateObject private var updater = FirmwareUpdater()
    var body: some View {
        List {
            Section("Installed firmware") {
                LabeledContent("Primary earbud", value: buds.firmware.isEmpty ? "Unavailable" : buds.firmware)
                LabeledContent("Other earbud", value: buds.peerFirmware ?? "Unavailable")
            }
            Section {
                Button("Check for updates") { Task { await updater.check(buds) } }.disabled(updater.working)
                if let release = updater.release, !updater.upToDate {
                    LabeledContent("Available", value: release.title)
                    Text(release.changeLog)
                    if !updater.downloaded {
                        Button("Download firmware") { Task { await updater.download() } }.disabled(updater.working)
                    } else {
                        Button("Update earbuds") { updater.startUpdate(buds) }.disabled(updater.working)
                    }
                }
                if updater.working { ProgressView() }
                if let progress = updater.progress { ProgressView(value: progress) }
                if !updater.message.isEmpty { Text(updater.message).font(.subheadline) }
                if buds.updatingFirmware, let progress = updater.progress, progress < 1 {
                    Button("Cancel update", role: .destructive) { updater.cancel() }
                }
            }
            Section("Before updating") {
                Text("Charge both earbuds and the case. Put both earbuds in the case, leave the lid open and keep this screen open until the update finishes. Disconnect the earbuds from other devices for the update.")
                Text("Firmware comes directly from Xiaomi. No Xiaomi app or account is required.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Firmware")
        .navigationBarBackButtonHidden(buds.updatingFirmware)
        .onChange(of: [buds.firmware, buds.peerFirmware ?? ""]) { _, _ in
            updater.reconcileVersion(buds)
        }
    }
}
