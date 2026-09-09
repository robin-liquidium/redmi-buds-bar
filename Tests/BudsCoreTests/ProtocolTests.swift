import XCTest
@testable import BudsCore

final class ProtocolTests: XCTestCase {
    private func hex(_ string: String) -> [UInt8] { string.split(separator: " ").map { UInt8($0, radix: 16)! } }
    func testCapturedNoiseReadbackInEveryFragmentSize() {
        let raw = hex("fe dc ba 00 f3 00 07 00 02 04 00 0b 01 13 ef")
        for size in 1...raw.count {
            var decoder = PacketDecoder()
            var packets: [Packet] = []
            for start in stride(from: 0, to: raw.count, by: size) {
                packets += decoder.feed(Array(raw[start..<min(start + size, raw.count)]))
            }
            XCTAssertEqual(packets.count, 1)
            XCTAssertEqual(packets.first?.status, 0)
            XCTAssertEqual(parseNoise(packets[0].payload), NoiseSetting(mode: .anc, strength: 19))
        }
    }
    func testCapturedCoalescedBroadcastsAndResponse() {
        var decoder = PacketDecoder()
        let packets = decoder.feed(hex("fe dc ba c7 0e 00 04 01 02 04 02 ef fe dc ba c7 0e 00 04 02 02 04 02 ef fe dc ba 00 f2 00 02 00 02 ef"))
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets[0].isRequest)
        XCTAssertTrue(packets[0].needsReply)
        XCTAssertEqual(packets[0].sequence, 1)
        XCTAssertEqual(packets[2].status, 0)
        XCTAssertEqual(packets[2].payload, [])
    }
    func testStrengthReadbacksAndSupportedPresets() {
        for strength: UInt8 in [0, 9, 19] {
            let raw: [UInt8] = [0xfe,0xdc,0xba,0,0xf3,0,7,0,2,4,0,11,1,strength,0xef]
            var decoder = PacketDecoder()
            XCTAssertEqual(parseNoise(decoder.feed(raw)[0].payload), NoiseSetting(mode: .anc, strength: strength))
        }
        XCTAssertNil(NoiseMode.off.strengthRange)
        XCTAssertFalse(NoiseMode.anc.strengthRange!.contains(255))
        XCTAssertFalse(NoiseMode.transparency.strengthRange!.contains(3))
        for strength: UInt8 in [0, 1, 2] {
            XCTAssertEqual(parseNoise([4,0,11,2,strength])?.strength, strength)
        }
        XCTAssertEqual(parseTLVs([3,0,0x25,1], idWidth: 2).first?.value, [1])
        XCTAssertEqual(parseTLVs([3,0,0x25,0], idWidth: 2).first?.value, [0])
    }
    func testCapturedCommands() {
        XCTAssertEqual(Packet.encode(opcode: 0xf2, sequence: 2, payload: [4,0,11,2,0]), hex("fe dc ba c0 f2 00 06 02 04 00 0b 02 00 ef"))
        XCTAssertEqual(Packet.encode(opcode: 0xf3, sequence: 22, payload: [0,11]), hex("fe dc ba c0 f3 00 03 16 00 0b ef"))
    }
    func testNoiseModesAndUnsupportedValues() {
        for mode in NoiseMode.allCases {
            XCTAssertEqual(parseNoise([4,0,11,mode.rawValue,0])?.mode, mode)
        }
        XCTAssertNil(parseNoise([3,0,11,255]))
        XCTAssertNil(parseNoise([4,0,11,255,0]))
        XCTAssertNil(parseNoise([4,0,11,1]))
    }
    func testMalformedFramesResynchronize() {
        var decoder = PacketDecoder()
        let valid = hex("fe dc ba 00 f2 00 02 00 02 ef")
        let malformed = hex("aa bb fe dc ba 00 f2 ff ff 00 00 fe dc ba 00 f2 00 01 00 ef")
        XCTAssertEqual(decoder.feed(malformed + valid).count, 1)
        var brokenTrailer = valid
        brokenTrailer[brokenTrailer.count - 1] = 0
        XCTAssertEqual(decoder.feed(brokenTrailer + valid).count, 1)
    }
    func testCapturedBatteriesAndTLVBounds() {
        let items = parseTLVs(hex("05 01 12 36 12 36 05 03 27 17 50 e3 04 07 64 64 ff"), idWidth: 1)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[2].value.compactMap { Battery($0) }.map(\.percent), [100,100])
        XCTAssertNil(Battery(255))
        XCTAssertNil(Battery(127))
        XCTAssertEqual(Battery(0)?.percent, 0)
        XCTAssertTrue(Battery(228)!.charging)
        XCTAssertEqual(parseTLVs([2,0,11], idWidth: 2).first?.value, [])
        XCTAssertTrue(parseTLVs([10,0,11], idWidth: 2).isEmpty)
        XCTAssertTrue(parseTLVs([0], idWidth: 2).isEmpty)
    }
}
