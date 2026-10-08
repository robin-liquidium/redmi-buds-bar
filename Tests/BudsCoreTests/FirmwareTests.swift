import XCTest
@testable import BudsCore

final class FirmwareTests: XCTestCase {
    func testCapturedUpdateResponsesAndFailureReasons() throws {
        let start = try MMAUpdateBlock(response: [0, 0, 0, 0, 10, 0x10, 0, 1], entering: true)
        XCTAssertEqual(start.offset, 10)
        XCTAssertEqual(start.length, 4096)
        XCTAssertTrue(start.requiresCRC)
        // This is the actual failed E5 response from the official Xiaomi update attempt.
        XCTAssertThrowsError(try MMAUpdateBlock(response: [0x10, 0, 0, 0, 0, 0, 0, 0, 50], entering: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("connection to each other"))
        }
        XCTAssertTrue(FirmwareFailure.eligibility(0x12)!.contains("both earbuds"))
        XCTAssertNotNil(FirmwareFailure.eligibility(0))
        XCTAssertNil(FirmwareFailure.eligibility(3))
        let end = try MMAUpdateBlock(response: [0, 0, 0, 0, 0, 0, 0, 0, 50], entering: false)
        XCTAssertTrue(end.finished)
        XCTAssertEqual(end.delayMilliseconds, 50)
        XCTAssertThrowsError(try MMAUpdateBlock(response: [0], entering: false))
    }

    func testFirmwareIntegrityAndModelBoundaries() throws {
        let payload = Array("123456789".utf8)
        XCTAssertEqual(MMAFirmwareImage.crc32(payload), 0xcbf43926)
        let header: [UInt8] = [0x27, 0x17, 0x50, 0xe3, 0x12, 0x37, 0, 0, 0, 9, 0xcb, 0xf4, 0x39, 0x26]
        let image = try MMAFirmwareImage(download: header + payload + [0xde, 0xad], expectedVersion: 0x1237)
        XCTAssertEqual(image.bytes, header + payload)
        XCTAssertEqual(image.versionName, "1.2.3.7")
        XCTAssertEqual(try image.block(offset: 14, length: 9, withCRC: true), payload + [0xcb, 0xf4, 0x39, 0x26])
        XCTAssertThrowsError(try image.block(offset: 22, length: 2, withCRC: true))
        XCTAssertThrowsError(try image.block(offset: -1, length: 1, withCRC: false))
        XCTAssertThrowsError(try MMAFirmwareImage(download: header + payload, expectedVersion: 0x1238))
        var wrongModel = header + payload
        wrongModel[3] = 0xe5
        XCTAssertThrowsError(try MMAFirmwareImage(download: wrongModel, expectedVersion: 0x1237))
        var damaged = header + payload
        damaged[20] ^= 1
        XCTAssertThrowsError(try MMAFirmwareImage(download: damaged, expectedVersion: 0x1237))
        XCTAssertThrowsError(try MMAFirmwareImage(download: Array((header + payload).dropLast()), expectedVersion: 0x1237))
    }

    func testServerVersionNormalizationAndLargeOTAPacket() {
        XCTAssertEqual(MMAFirmwareImage.versionCode("1.2.3_0007"), 0x1237)
        for invalid in ["1.2.3", "1.2.3.16", "1..2.3.7", "1.2.bad.3.7", "1.2.999999999999999999999999.3.7"] {
            XCTAssertNil(MMAFirmwareImage.versionCode(invalid))
        }
        let data = [UInt8](repeating: 0x42, count: 4100)
        let frame = Packet.encode(opcode: 0xe5, sequence: 29, payload: data)
        var decoder = PacketDecoder()
        XCTAssertTrue(decoder.feed(Array(frame.prefix(512))).isEmpty)
        let received = decoder.feed(Array(frame.dropFirst(512)))
        XCTAssertEqual(received.first?.payload, data)
        XCTAssertEqual(received.first?.opcode, 0xe5)
    }
}
