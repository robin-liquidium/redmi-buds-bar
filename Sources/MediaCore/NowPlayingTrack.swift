import Foundation

public struct NowPlayingTrack: Decodable, Equatable {
    public let bundleIdentifier: String
    public let parentApplicationBundleIdentifier: String?
    public let title: String
    public let artist: String?
    public let album: String?
    public let playing: Bool
    public let durationMicros: Double?
    public let elapsedTimeMicros: Double?
    public let timestampEpochMicros: Double?
    public let playbackRate: Double?
    public internal(set) var artworkData: String?
    public let prohibitsSkip: Bool?

    public var sourceBundleIdentifier: String {
        if let parentApplicationBundleIdentifier, !parentApplicationBundleIdentifier.isEmpty {
            return parentApplicationBundleIdentifier
        }
        return bundleIdentifier
    }

    public var duration: TimeInterval { max(0, (durationMicros ?? 0) / 1_000_000) }

    public func elapsed(at date: Date) -> TimeInterval {
        var seconds = (elapsedTimeMicros ?? 0) / 1_000_000
        if playing, let timestampEpochMicros {
            seconds += max(0, date.timeIntervalSince1970 - timestampEpochMicros / 1_000_000) * (playbackRate ?? 1)
        }
        return max(0, duration > 0 ? min(seconds, duration) : seconds)
    }
}

/// The adapter sends newline-delimited JSON, with artwork usually sent only once.
public struct MediaStreamDecoder {
    private var buffer = Data()
    private var payload: [String: Any] = [:]
    private var artworkData: String?
    public init() {}

    public mutating func append(_ data: Data) throws -> [NowPlayingTrack?] {
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        var updates: [NowPlayingTrack?] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  message["type"] as? String == "data",
                  let diff = message["diff"] as? Bool,
                  let incoming = message["payload"] as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            if !diff { payload = [:]; artworkData = nil }
            for (key, value) in incoming {
                // Artwork can be large; retain it without re-encoding it on each playback event.
                if key == "artworkData" { artworkData = value as? String }
                else if value is NSNull { payload.removeValue(forKey: key) }
                else { payload[key] = value }
            }
            guard payload["bundleIdentifier"] is String, payload["title"] is String,
                  payload["playing"] is Bool else {
                updates.append(nil)
                continue
            }
            var track = try JSONDecoder().decode(NowPlayingTrack.self, from: JSONSerialization.data(withJSONObject: payload))
            track.artworkData = artworkData
            updates.append(track)
        }
        return updates
    }
}
