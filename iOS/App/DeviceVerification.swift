#if DEBUG
import Foundation

/// Explicit device check using the exact controller used by the app and App Intents.
/// Launch with --verify-noise; restores the initial mode, and never runs in release builds.
@MainActor enum DeviceVerification {
    static func run(_ buds: BLEBuds) async {
        var lines: [String] = ["Started: \(Date().ISO8601Format())"]
        var original: NoiseSetting?
        var succeeded = false
        do {
            try await buds.connect()
            original = buds.noise
            lines.append("Connected: firmware=\(buds.firmware), left=\(buds.left?.percent ?? -1), right=\(buds.right?.percent ?? -1)")
            if ProcessInfo.processInfo.arguments.contains("--verify-settings") {
                try await buds.readEarbudSettings()
                if let settings = buds.earbudSettings {
                    for side in EarbudSide.allCases {
                        for kind in EarbudGesture.allCases {
                            lines.append("GESTURE \(side.title) \(kind.title)=\(settings.action(kind, side: side).map(String.init) ?? "unavailable")")
                        }
                        lines.append("NOISE CYCLE \(side.title)=\(settings.noiseMask(side).map(String.init) ?? "unavailable")")
                    }
                    for id: UInt16 in [3, 4, 7, 0x1d, 0x25, 0x29, 0x2f, 0x36, 0x37, 0x68, 6] {
                        lines.append("CONFIG \(String(format: "%04X", id))=\(settings.value(id)?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "unavailable")")
                    }
                    lines.append("IN-EAR DETECTION=\(settings.wearDetection.map(String.init) ?? "unavailable")")
                }
                lines.append("PASS: read-only settings; no settings written")
                write(lines)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-firmware-readiness") {
                let release = try await FirmwareService.latest(current: buds.firmware)
                let image = try await FirmwareService.download(release)
                lines.append("Official download verified: version=\(image.versionName), bytes=\(image.bytes.count)")
                lines.append("Other earbud firmware: \(buds.peerFirmware ?? "unavailable")")
                do {
                    try await buds.checkFirmwareReadiness(image)
                    lines.append("Dual-bank update readiness confirmed")
                } catch { lines.append("Readiness: \(error.localizedDescription)") }
                lines.append("READ-ONLY CHECK COMPLETE; no firmware written")
                write(lines)
                return
            }
            guard original != nil else { throw BLEBuds.Failure(message: "No initial noise state") }
            if ProcessInfo.processInfo.arguments.contains("--verify-connection") {
                lines.append("Read current mode: \(original!.mode.title)")
                lines.append("PASS")
                write(lines)
                return
            }
            for choice in [NoiseChoice.transparency, .off, .anc] {
                // Execute the actual system-facing action, rather than a second command path.
                _ = try await SetNoiseModeIntent(choice).perform()
                guard buds.noise?.mode == choice.mode else { throw BLEBuds.Failure(message: "Wrong readback for \(choice)") }
                lines.append("Verified \(choice.rawValue): strength=\(buds.noise!.strength)")
            }
            for expected in [NoiseMode.transparency, .off, .anc] {
                _ = try await CycleNoiseModeIntent().perform()
                guard buds.noise?.mode == expected, NoiseControlState.load() == expected else {
                    throw BLEBuds.Failure(message: "Wrong cycle readback or shared icon state")
                }
                lines.append("Verified cycle and icon state: \(expected.title)")
            }
            succeeded = true
        } catch { lines.append("FAILED: \(error.localizedDescription)") }
        if ProcessInfo.processInfo.arguments.contains("--verify-settings") {
            lines.append("FAIL: read-only settings check; no settings written")
            write(lines)
            return
        }
        if let original {
            do {
                try await buds.setMode(original.mode, strength: original.mode == .off ? nil : original.strength)
                guard buds.noise == original else { throw BLEBuds.Failure(message: "Restored mode does not match initial state") }
                lines.append("Restored initial mode and strength")
            } catch { succeeded = false; lines.append("RESTORE FAILED: \(error.localizedDescription)") }
        }
        lines.append(succeeded ? "PASS" : "FAIL")
        write(lines)
    }
    private static func write(_ lines: [String]) {
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("device-verification.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
