import Foundation

public enum EarbudSide: Int, CaseIterable {
    case left, right
    public var title: String { self == .left ? "Left earbud" : "Right earbud" }
}

public enum EarbudGesture: UInt8, CaseIterable {
    case singleTap = 4, doubleTap = 1, tripleTap = 2, hold = 3, swipe = 5
    public var title: String {
        switch self {
        case .singleTap: return "Single tap"
        case .doubleTap: return "Double tap"
        case .tripleTap: return "Triple tap"
        case .hold: return "Press and hold"
        case .swipe: return "Swipe"
        }
    }
    // Xiaomi's p76c model catalog, not a generic profile's feature guesses.
    public var actions: [GestureAction] {
        switch self {
        case .singleTap, .doubleTap, .tripleTap: return [.none, .playPause, .previous, .next, .volumeUp, .volumeDown]
        case .hold: return [.none, .voiceAssistant, .noiseControl]
        case .swipe: return [.none, .swipeVolume]
        }
    }
}

public enum GestureAction: UInt8 {
    case voiceAssistant = 0, playPause = 1, previous = 2, next = 3
    case volumeUp = 4, volumeDown = 5, noiseControl = 6, none = 8, swipeVolume = 11
    public var title: String {
        switch self {
        case .voiceAssistant: return "Voice assistant"
        case .playPause: return "Play / pause"
        case .previous: return "Previous track"
        case .next: return "Next track"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .noiseControl: return "Cycle noise modes"
        case .none: return "None"
        case .swipeVolume: return "Up: volume up · Down: volume down"
        }
    }
}

public enum EarbudEdit {
    case assignment(EarbudGesture, EarbudSide, GestureAction)
    case noiseCycle(EarbudSide, UInt8)
    case autoAnswer(Bool)
    case multipoint(Bool)
    case toggle(EarbudToggle, Bool)
    case wearDetection(Bool)
    case spatial(SpatialMode)
    case spatialPreference(UInt8)
    case scene(UInt8)
    case audioEngine(UInt8)
    case equalizerPreset(UInt8)
    case equalizerBand(Int, Int)
}

public struct EarbudSettings: Equatable {
    public static let query: [UInt8] = [2, 10, 3, 4, 7, 0x1d, 0x25, 0x29, 0x2f, 0x36, 0x37, 0x68, 6].flatMap { [0, $0] }
    public static let wearQuery: [UInt8] = [0, 0, 4, 0]
    private let values: [UInt16: [UInt8]]
    public let wearDetection: Bool?
    public init(payload: [UInt8], runInfo: [UInt8] = []) throws {
        var offset = 0
        while offset < payload.count {
            let length = Int(payload[offset])
            guard length >= 2, offset + length < payload.count else { throw FirmwareFailure("The earbuds returned incomplete settings.") }
            offset += length + 1
        }
        let wear = parseTLVs(runInfo, idWidth: 1).first(where: { $0.id == 10 })?.value
        wearDetection = wear == [0] ? true : wear == [1] ? false : nil
        let fields = parseTLVs(payload, idWidth: 2)
        var values: [UInt16: [UInt8]] = [:]
        for field in fields {
            guard values[field.id] == nil else { throw FirmwareFailure("The earbuds returned duplicate settings.") }
            values[field.id] = field.value
        }
        guard let gestures = values[2], !gestures.isEmpty, gestures != [0xff], gestures.count.isMultiple(of: 3) else {
            throw FirmwareFailure("The earbuds did not return supported gesture settings.")
        }
        var kinds = Set<UInt8>()
        for offset in stride(from: 0, to: gestures.count, by: 3) {
            guard kinds.insert(gestures[offset]).inserted else { throw FirmwareFailure("The earbuds returned duplicate gestures.") }
        }
        self.values = values
    }
    public func action(_ kind: EarbudGesture, side: EarbudSide) -> UInt8? {
        guard let data = values[2], let offset = stride(from: 0, to: data.count, by: 3).first(where: { data[$0] == kind.rawValue }) else { return nil }
        let value = data[offset + 1 + side.rawValue]
        return value == 0xff ? nil : value
    }
    public func noiseMask(_ side: EarbudSide) -> UInt8? {
        guard let data = values[10], data.count == 2, data[side.rawValue] != 0xff else { return nil }
        return data[side.rawValue]
    }
    public func boolean(_ id: UInt16) -> Bool? {
        guard let data = values[id], data == [0] || data == [1] else { return nil }
        return data[0] == 1
    }
    public func value(_ id: UInt16) -> [UInt8]? { values[id] }
    public var spatialByte: UInt8? {
        guard let data = values[0x1d], data.count == 1, data[0] & 0xe0 == 0, (data[0] >> 1) & 3 <= 1 else { return nil }
        return data[0]
    }
    public var spatialMode: SpatialMode? {
        guard let byte = spatialByte else { return nil }
        if byte & 0x10 != 0 { return nil }
        if byte & 1 == 0 { return .off }
        return byte & 8 != 0 ? .headTracking : .fixed
    }
    public var equalizer: EarbudEqualizer? { values[0x37].flatMap(EarbudEqualizer.init) }
    public var autoAnswer: Bool? { boolean(3) }
    public var multipoint: Bool? { boolean(4) }
    public func change(_ edit: EarbudEdit) throws -> EarbudChange {
        let id: UInt16
        let data: [UInt8]
        var expected: [UInt8]
        var opcode: UInt8 = 0xf2
        switch edit {
        case let .assignment(kind, side, action):
            guard self.action(kind, side: side) != nil, kind.actions.contains(action), let current = values[2],
                  let offset = stride(from: 0, to: current.count, by: 3).first(where: { current[$0] == kind.rawValue }) else {
                throw FirmwareFailure("That gesture or action is not supported by these earbuds.")
            }
            id = 2; expected = current; expected[offset + 1 + side.rawValue] = action.rawValue
            data = [kind.rawValue, side == .left ? action.rawValue : 0xff, side == .right ? action.rawValue : 0xff]
        case let .noiseCycle(side, mask):
            guard noiseMask(side) != nil, [UInt8(3), 5, 6, 7].contains(mask), let current = values[10] else {
                throw FirmwareFailure("Choose at least two supported noise modes.")
            }
            id = 10; expected = current; expected[side.rawValue] = mask
            data = side == .left ? [mask, 0xff] : [0xff, mask]
        case let .autoAnswer(enabled):
            guard autoAnswer != nil else { throw FirmwareFailure("Automatic call answering is not supported.") }
            id = 3; data = [enabled ? 1 : 0]; expected = data
        case let .multipoint(enabled):
            guard multipoint != nil else { throw FirmwareFailure("Dual-device connection is not supported.") }
            id = 4; data = [enabled ? 1 : 0]; expected = data
        case let .toggle(toggle, enabled):
            guard boolean(toggle.rawValue) != nil else { throw FirmwareFailure("This setting is unavailable on these earbuds.") }
            id = toggle.rawValue; data = [enabled ? 1 : 0]; expected = data
        case let .wearDetection(enabled):
            guard wearDetection != nil else { throw FirmwareFailure("In-ear detection is unavailable.") }
            id = 6; data = [enabled ? 0 : 1]; expected = data; opcode = 0x08
        case let .spatial(mode):
            guard let byte = spatialByte else { throw FirmwareFailure("Dimensional audio is unavailable.") }
            id = 0x1d; data = [(byte & 6) | mode.bits]; expected = data
        case let .spatialPreference(preference):
            guard let byte = spatialByte, preference <= 1 else { throw FirmwareFailure("That audio preference is unavailable.") }
            id = 0x1d; data = [(byte & ~6) | (preference << 1)]; expected = data
        case let .scene(scene):
            guard let current = values[0x36], current.count == 1 || current.count == 2, current.first == 0 || current.first == 1,
                  scene <= 5 else { throw FirmwareFailure("That audio scene is unavailable.") }
            id = 0x36; data = scene == 0 ? [0] : [1, scene]; expected = data
        case let .audioEngine(engine):
            guard let current = values[0x68], current.count == 1, current[0] <= 1, engine <= 1 else { throw FirmwareFailure("That dimensional audio engine is unavailable.") }
            id = 0x68; data = [engine]; expected = data
        case let .equalizerPreset(preset):
            guard let current = values[7], current.count == 1, current != [0xff], [UInt8(0), 5, 1, 6, 10].contains(preset) else {
                throw FirmwareFailure("That equalizer preset is unavailable.")
            }
            id = 7; data = [preset]; expected = data
        case let .equalizerBand(frequency, gain):
            guard let eq = equalizer, let index = eq.bands.firstIndex(where: { $0.frequency == frequency }), (-eq.bound...eq.bound).contains(gain) else {
                throw FirmwareFailure("That equalizer band or gain is unavailable.")
            }
            id = 0x37
            var bands = eq.bands; bands[index].gain = gain
            data = [1, 10, 1, 1, 1, 0, UInt8(bands.count)] + bands.flatMap { [UInt8($0.frequency >> 8), UInt8($0.frequency & 255), UInt8($0.gain < 0 ? 128 - $0.gain : $0.gain)] }
            expected = data; expected[2] = UInt8(eq.bound); expected[3] = UInt8(128 + eq.bound)

        }
        if opcode == 0x08 { return EarbudChange(id: id, opcode: opcode, payload: [2, 6] + data, expected: expected) }
        return EarbudChange(id: id, opcode: opcode, payload: [UInt8(data.count + 2), UInt8(id >> 8), UInt8(id & 255)] + data, expected: expected)
    }
    public func confirms(_ change: EarbudChange) -> Bool {
        if change.opcode == 0x08 { return wearDetection == (change.expected == [0]) }
        guard let actual = values[change.id] else { return false }
        if change.id == 0x36, change.expected == [0] { return actual.first == 0 }
        if change.id == 0x37 {
            guard let eq = EarbudEqualizer(actual), let desired = EarbudEqualizer(change.expected) else { return false }
            return eq.mode == 10 && eq.bands == desired.bands
        }
        if change.id != 2 { return actual == change.expected }
        // Firmware may reorder gesture records; all assignments, including the other side, must match.
        func sortedRecords(_ data: [UInt8]) -> [[UInt8]] {
            stride(from: 0, to: data.count, by: 3).map { Array(data[$0..<($0 + 3)]) }.sorted { $0[0] < $1[0] }
        }
        return sortedRecords(actual) == sortedRecords(change.expected)
    }
}

public struct EarbudChange {
    public let id: UInt16
    public let opcode: UInt8
    public let payload: [UInt8]
    fileprivate let expected: [UInt8]
}

public enum EarbudToggle: UInt16, CaseIterable {
    case smartANC = 0x25, adaptiveSound = 0x29, lowLatency = 0x2f
    public var title: String {
        switch self {
        case .smartANC: return "Adaptive noise cancelling"
        case .adaptiveSound: return "Adaptive sound"
        case .lowLatency: return "Low latency"
        }
    }
}
public enum SpatialMode: UInt8, CaseIterable {
    case off, fixed, headTracking
    public var bits: UInt8 { [0, 1, 9][Int(rawValue)] }
    public var title: String { ["Off", "Fixed", "Head tracking"][Int(rawValue)] }
}
public struct EqualizerBand: Equatable {
    public let frequency: Int
    public var gain: Int
}
public struct EarbudEqualizer {
    public let mode: UInt8
    public let bound: Int
    public let bands: [EqualizerBand]
    public init?(_ data: [UInt8]) {
        guard data.count >= 7, data[0] == 1 else { return nil }
        let start = 6 + Int(data[5])
        guard start < data.count else { return nil }
        let count = Int(data[start])
        guard count > 0, count <= 20, data.count == start + 1 + count * 3 else { return nil }
        mode = data[1]; bound = data[2] == 0 ? 10 : Int(data[2])
        guard bound > 0, bound <= 20 else { return nil }
        var parsed: [EqualizerBand] = []
        for offset in stride(from: start + 1, to: data.count, by: 3) {
            let frequency = Int(data[offset]) << 8 | Int(data[offset + 1])
            let byte = Int(data[offset + 2]); let gain = byte < 128 ? byte : 128 - byte
            guard frequency > 0, frequency <= 24000, abs(gain) <= bound, !parsed.contains(where: { $0.frequency == frequency }) else { return nil }
            parsed.append(EqualizerBand(frequency: frequency, gain: gain))
        }
        bands = parsed
    }
}

public enum EarbudAction { case fitTest, find(UInt8), stopFinding }
public enum EarTipFit {
    public static func results(_ payload: [UInt8]) -> String? {
        guard let data = parseTLVs(payload, idWidth: 2).first(where: { $0.id == 6 })?.value, data.count == 2 else { return nil }
        if data.contains(9) { return "Put both earbuds in your ears before running the fit test." }
        guard data.allSatisfy({ $0 == 1 || $0 == 2 }) else { return nil }
        return "Left: \(data[0] == 1 ? "Good seal" : "Adjust ear tip") · Right: \(data[1] == 1 ? "Good seal" : "Adjust ear tip")"
    }
    public static func mayFind(_ payload: [UInt8]) -> Bool {
        guard let data = parseTLVs(payload, idWidth: 2).first(where: { $0.id == 12 })?.value, data.count == 1, data[0] != 0xff else { return false }
        return data[0] & 12 == 0
    }
}
