import Foundation
import WidgetKit

/// Shared, confirmed state for the Control Center label; never used to choose the next mode.
enum NoiseControlState {
    static let kind = "build.robin.RedmiBuds.cycle"
    static let group = "group.build.robin.RedmiBuds"
    private static let key = "confirmedNoiseMode"
    static func load() -> NoiseMode? {
        guard let value = UserDefaults(suiteName: group)?.object(forKey: key) as? Int,
              let byte = UInt8(exactly: value) else { return nil }
        return NoiseMode(rawValue: byte)
    }
    static func save(_ mode: NoiseMode?) {
        guard load() != mode, let defaults = UserDefaults(suiteName: group) else { return }
        if let mode { defaults.set(Int(mode.rawValue), forKey: key) }
        else { defaults.removeObject(forKey: key) }
        ControlCenter.shared.reloadControls(ofKind: kind)
    }
}
