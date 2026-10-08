import Foundation
import BudsCore
setbuf(stdout, nil)
let controller = BudsController()
controller.log = { print($0) }
var didSet = false
let argument = CommandLine.arguments.dropFirst().first ?? "status"
let checkingFirmware = argument == "firmware-check"
let checkingGestures = argument == "gestures"
let desired: NoiseMode? = ["anc": .anc, "off": .off, "transparency": .transparency][argument]
let strengthArgument = CommandLine.arguments.dropFirst(2).first
let strength = strengthArgument.flatMap(UInt8.init)
if let strengthArgument {
    guard let desired, let strength, desired.strengthRange?.contains(strength) == true else {
        print("Invalid strength: \(strengthArgument). ANC accepts 0–19; transparency accepts 0–2.")
        exit(2)
    }
}
controller.onNoise = { setting in
    print("STATE mode=\(setting.mode.title) strength=\(setting.strength) firmware=\(controller.firmware) L=\(controller.left?.percent ?? -1) R=\(controller.right?.percent ?? -1)")
    if checkingGestures {
        guard !didSet else { return }
        didSet = true
        Task { @MainActor in
            do {
                try await controller.readEarbudSettings()
                if let settings = controller.earbudSettings {
                    for side in EarbudSide.allCases {
                        for kind in EarbudGesture.allCases {
                            if let value = settings.action(kind, side: side) { print("GESTURE \(side.title) \(kind.title)=\(value)") }
                        }
                        print("NOISE CYCLE \(side.title)=\(settings.noiseMask(side).map(String.init) ?? "unsupported")")
                    }
                    for id: UInt16 in [3, 4, 7, 0x1d, 0x25, 0x29, 0x2f, 0x36, 0x37, 0x68, 6] {
                        print("CONFIG \(String(format: "%04X", id))=\(settings.value(id)?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "unavailable")")
                    }
                    print("IN-EAR DETECTION=\(settings.wearDetection.map(String.init) ?? "unsupported")")
                    print("AUTO ANSWER=\(settings.autoAnswer.map(String.init) ?? "unsupported") MULTIPOINT=\(settings.multipoint.map(String.init) ?? "unsupported")")
                }
                controller.stop(); exit(0)
            } catch { print("FAIL: \(error.localizedDescription)"); controller.stop(); exit(1) }
        }
    } else if checkingFirmware {
        guard !didSet else { return }
        didSet = true
        Task { @MainActor in
            do {
                try await controller.checkFirmwareVersions()
                let release = try await FirmwareService.latest(current: controller.firmware)
                let image = try await FirmwareService.download(release)
                print("OFFICIAL firmware=\(image.versionName) bytes=\(image.bytes.count) primary=\(controller.firmware) peer=\(controller.peerFirmware ?? "unavailable")")
                do {
                    try await controller.checkFirmwareReadiness(image)
                    print("READINESS dual-bank eligible")
                } catch { print("READINESS \(error.localizedDescription)") }
                print("PASS: official discovery/download and read-only check; no firmware installed")
                controller.stop(); exit(0)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                controller.stop(); exit(1)
            }
        }
    } else if let desired, !didSet {
        didSet = true
        DispatchQueue.main.async {
            if let strength { controller.setNoise(NoiseSetting(mode: desired, strength: strength), manualANC: desired == .anc) }
            else { controller.setMode(desired) }
        }
    } else if desired == nil { controller.stop(); exit(0) }
}
controller.onCommandComplete = { success in controller.stop(); exit(success ? 0 : 1) }
controller.start()
RunLoop.current.run(until: Date().addingTimeInterval(checkingFirmware ? 90 : 20))
controller.stop()
print("Timed out")
exit(1)
