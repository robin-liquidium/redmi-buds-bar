import Foundation
import BudsCore
setbuf(stdout, nil)
let controller = BudsController()
controller.log = { print($0) }
var didSet = false
let argument = CommandLine.arguments.dropFirst().first ?? "status"
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
    if let desired, !didSet {
        didSet = true
        DispatchQueue.main.async {
            if let strength { controller.setNoise(NoiseSetting(mode: desired, strength: strength), manualANC: desired == .anc) }
            else { controller.setMode(desired) }
        }
    } else if desired == nil { controller.stop(); exit(0) }
}
controller.onCommandComplete = { success in controller.stop(); exit(success ? 0 : 1) }
controller.start()
RunLoop.current.run(until: Date().addingTimeInterval(20))
controller.stop()
print("Timed out")
exit(1)
