import Foundation
import CryptoKit

public enum FirmwareService {
    public struct Release: Decodable, Sendable {
        public let version: String
        public let url: URL
        public let md5: String
        public let changeLog: String
        public var code: UInt16? { MMAFirmwareImage.versionCode(version) }
        public var title: String { code.map(MMAFirmwareImage.versionName) ?? version }
    }
    private struct Response: Decodable {
        let code: Int
        let message: String
        let result: Release?
    }
    // Anonymous app-client header published in Xiaomi's distributed app, not a user token.
    private static let guestHeader = "auth_key=rwelJuWBFJxmbMKD"
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }
    public static func latest(current: String) async throws -> Release {
        let service = session()
        defer { service.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://cn.tws.wear.mi.com/twswear/device/latest_ver?locale=en_US")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(guestHeader, forHTTPHeaderField: "Cookie")
        let json = try JSONSerialization.data(withJSONObject: ["model": "miwear.headphone.p76c", "platform": "android", "app_level": "1.38.0", "fw_ver": current, "channel": "prod"])
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: String(decoding: json, as: UTF8.self))]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await service.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FirmwareFailure("Xiaomi's update service could not be reached. Try again later.") }
        let envelope = try JSONDecoder().decode(Response.self, from: data)
        guard envelope.code == 0, let release = envelope.result, release.code != nil,
              release.url.scheme == "https", release.url.host == "iot-ota-cdn.io.mi.com",
              release.md5.count == 32, release.md5.allSatisfy({ $0.isHexDigit }) else {
            throw FirmwareFailure("Xiaomi did not return a supported firmware package for this model.")
        }
        return release
    }
    public static func download(_ release: Release) async throws -> MMAFirmwareImage {
        let service = session()
        defer { service.finishTasksAndInvalidate() }
        let (data, response) = try await service.data(from: release.url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "iot-ota-cdn.io.mi.com",
              data.count <= 32 * 1024 * 1024, let version = release.code else {
            throw FirmwareFailure("The firmware download failed its source or size check.")
        }
        let image = try await Task.detached(priority: .userInitiated) {
            let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == release.md5.lowercased() else { throw FirmwareFailure("The downloaded firmware does not match Xiaomi's checksum.") }
            return try MMAFirmwareImage(download: Array(data), expectedVersion: version)
        }.value
        return image
    }
}
