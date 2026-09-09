import Foundation

public enum NoiseMode: UInt8, CaseIterable, Codable {
    case off = 0, anc = 1, transparency = 2
    public var title: String {
        switch self { case .off: return "Off"; case .anc: return "Noise cancelling"; case .transparency: return "Transparency" }
    }
    /// Buds 8 Pro has 20 manual ANC levels and three transparency presets.
    public var strengthRange: ClosedRange<UInt8>? {
        switch self { case .off: return nil; case .anc: return 0...19; case .transparency: return 0...2 }
    }
    public func strengthLabel(_ value: UInt8) -> String {
        switch self {
        case .off: return ""
        case .anc: return "Level \(Int(value) + 1) of 20"
        case .transparency:
            switch value { case 0: return "Regular"; case 1: return "Voice"; case 2: return "Ambient"; default: return "Unknown" }
        }
    }
    public var symbol: String {
        switch self { case .off: return "speaker.wave.2"; case .anc: return "waveform"; case .transparency: return "ear" }
    }
}

public struct NoiseSetting: Equatable, Codable {
    public let mode: NoiseMode
    public let strength: UInt8
    public init(mode: NoiseMode, strength: UInt8) { self.mode = mode; self.strength = strength }
}

public struct Battery: Equatable, Codable {
    public let percent: Int
    public let charging: Bool
    public init?(_ byte: UInt8) {
        guard byte != 0xff, byte & 0x7f <= 100 else { return nil }
        percent = Int(byte & 0x7f)
        charging = byte & 0x80 != 0
    }
}

public struct Packet: Equatable {
    public let type: UInt8
    public let opcode: UInt8
    public let sequence: UInt8
    public let status: UInt8?
    public let payload: [UInt8]
    public var isRequest: Bool { type & 0x80 != 0 }
    public var needsReply: Bool { type & 0x40 != 0 }

    public static func encode(opcode: UInt8, sequence: UInt8, payload: [UInt8], response: Bool = false) -> [UInt8] {
        let body = (response ? [UInt8(0), sequence] : [sequence]) + payload
        return [0xfe, 0xdc, 0xba, response ? 0x00 : 0xc0, opcode, UInt8(body.count >> 8), UInt8(body.count & 255)] + body + [0xef]
    }
}

/// RFCOMM is a byte stream: a callback may contain part of a packet or several packets.
public struct PacketDecoder {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func feed(_ bytes: [UInt8]) -> [Packet] {
        buffer += bytes
        var packets: [Packet] = []
        while buffer.count >= 3 {
            guard Array(buffer.prefix(3)) == [0xfe, 0xdc, 0xba] else { buffer.removeFirst(); continue }
            guard buffer.count >= 7 else { break }
            let isRequest = buffer[3] & 0x80 != 0
            let length = Int(buffer[5]) << 8 | Int(buffer[6])
            guard length >= (isRequest ? 1 : 2), length <= 4096 else { buffer.removeFirst(); continue }
            let total = length + 8
            guard buffer.count >= total else { break }
            guard buffer[total - 1] == 0xef else { buffer.removeFirst(); continue }
            let sequenceIndex = isRequest ? 7 : 8
            packets.append(Packet(type: buffer[3], opcode: buffer[4], sequence: buffer[sequenceIndex], status: isRequest ? nil : buffer[7], payload: Array(buffer[(sequenceIndex + 1)..<(total - 1)])))
            buffer.removeFirst(total)
        }
        return packets
    }
}

/// Each Xiaomi TLV's length includes its identifier, but excludes the length byte itself.
public func parseTLVs(_ bytes: [UInt8], idWidth: Int) -> [(id: UInt16, value: [UInt8])] {
    guard idWidth == 1 || idWidth == 2 else { return [] }
    var result: [(UInt16, [UInt8])] = []
    var offset = 0
    while offset < bytes.count {
        let length = Int(bytes[offset])
        guard length >= idWidth, offset + length < bytes.count else { break }
        let id = idWidth == 1 ? UInt16(bytes[offset + 1]) : UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset + 2])
        result.append((id, Array(bytes[(offset + 1 + idWidth)..<(offset + length + 1)])))
        offset += length + 1
    }
    return result
}

public func parseNoise(_ bytes: [UInt8]) -> NoiseSetting? {
    guard let item = parseTLVs(bytes, idWidth: 2).first(where: { $0.id == 0x0b }), item.value.count == 2,
          let mode = NoiseMode(rawValue: item.value[0]) else { return nil }
    return NoiseSetting(mode: mode, strength: item.value[1])
}
