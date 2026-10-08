import Foundation

/// Xiaomi's published MMA OTA format, validated against this model's official package.
public struct MMAFirmwareImage: Sendable {
    public let bytes: [UInt8]
    public let version: UInt16
    public var versionName: String { Self.versionName(version) }
    public var identification: [UInt8] { Array(bytes.prefix(14)) }

    public init(download: [UInt8], expectedVersion: UInt16) throws {
        guard download.count >= 14,
              Array(download.prefix(4)) == [0x27, 0x17, 0x50, 0xe3] else {
            throw FirmwareFailure("The firmware does not match this REDMI Buds 8 Pro model.")
        }
        let version = UInt16(download[4]) << 8 | UInt16(download[5])
        guard version == expectedVersion else { throw FirmwareFailure("The firmware version does not match Xiaomi's update information.") }
        let length = Int(Self.number(download[6..<10]))
        guard length > 0, length <= download.count - 14 else { throw FirmwareFailure("The firmware file is incomplete.") }
        // Xiaomi's CDN appends a signing envelope. The MMA image ends at its declared length.
        let image = Array(download.prefix(14 + length))
        guard Self.crc32(image.dropFirst(14)) == Self.number(image[10..<14]) else {
            throw FirmwareFailure("The firmware failed its integrity check.")
        }
        self.bytes = image
        self.version = version
    }

    public func block(offset: Int, length: Int, withCRC: Bool) throws -> [UInt8] {
        guard offset >= 0, length > 0, length <= 65530,
              offset <= bytes.count, length <= bytes.count - offset else {
            throw FirmwareFailure("The earbuds requested a firmware block outside the validated file.")
        }
        let data = Array(bytes[offset..<(offset + length)])
        guard withCRC else { return data }
        let crc = Self.crc32(data)
        return data + [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)]
    }

    public static func versionCode(_ text: String) -> UInt16? {
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "_") }) else { return nil }
        let components = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "_" })
        let parts = components.compactMap { UInt16($0) }
        guard components.count == 4, parts.count == 4, parts.allSatisfy({ $0 <= 15 }) else { return nil }
        return parts.reduce(0) { ($0 << 4) | $1 }
    }
    public static func versionName(_ value: UInt16) -> String {
        "\(value >> 12).\((value >> 8) & 15).\((value >> 4) & 15).\(value & 15)"
    }
    public static func number(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        return crc
    }
    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        return crc ^ 0xffffffff
    }
}

public struct FirmwareFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static func eligibility(_ result: UInt8) -> String? {
        switch result {
        case 3: return nil // Verified dual-bank update; single-bank devices are deliberately excluded.
        case 0: return "This update requires a single-bank restart flow that is not supported yet."
        case 1: return "Charge both earbuds before updating."
        case 2: return "The earbuds rejected this firmware file."
        case 0x10: return "The two earbuds lost their connection to each other. Close the case, wait 10 seconds, then reopen it and try again."
        case 0x11: return "Keep the charging case lid open during the update."
        case 0x12: return "Place both earbuds in the charging case and leave the lid open."
        case 0x13: return "Firmware cannot update in single-earbud mode. Connect both earbuds first."
        case 0x15, 0x1c: return "Disconnect the earbuds from other devices during the update."
        case 0x17, 0x18: return "Stop recording before updating the earbuds."
        case 0x19: return "Stop audio playback before updating the earbuds."
        case 0x1a: return "End the current call before updating the earbuds."
        default: return "The earbuds cannot update right now (\(result))."
        }
    }
}

public struct MMAUpdateBlock: Sendable {
    public let offset: Int
    public let length: Int
    public let delayMilliseconds: Int
    public let requiresCRC: Bool
    public var finished: Bool { offset == 0 && length == 0 }

    public init(response: [UInt8], entering: Bool) throws {
        guard entering ? (response.count == 7 || response.count == 8) : response.count == 9 else {
            throw FirmwareFailure("The earbuds returned an invalid firmware update response.")
        }
        guard response[0] == 0 else {
            throw FirmwareFailure(FirmwareFailure.eligibility(response[0]) ?? "The firmware block was rejected.")
        }
        offset = Int(MMAFirmwareImage.number(response[1..<5]))
        length = Int(MMAFirmwareImage.number(response[5..<7]))
        requiresCRC = entering && response.count == 8 && response[7] == 1
        delayMilliseconds = entering ? 0 : Int(MMAFirmwareImage.number(response[7..<9]))
        guard !entering || length > 0 else { throw FirmwareFailure("The earbuds did not request firmware data.") }
        guard length > 0 || offset == 0 else { throw FirmwareFailure("The earbuds returned an invalid firmware block length.") }
    }
}
