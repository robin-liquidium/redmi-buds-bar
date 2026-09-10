import XCTest
@testable import MediaCore

final class MediaStreamTests: XCTestCase {
    private let snapshot = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","title":"Example track","artist":"Example artist","playing":true,"durationMicros":240000000,"elapsedTimeMicros":30000000,"timestampEpochMicros":1000000000,"playbackRate":1,"artworkData":"YWJj"}}"# + "\n"

    func testFragmentedSnapshotAndCombinedDiffs() throws {
        var decoder = MediaStreamDecoder()
        let bytes = Data(snapshot.utf8)
        for byte in bytes.dropLast() { XCTAssertTrue(try decoder.append(Data([byte])).isEmpty) }
        let first = try XCTUnwrap(try decoder.append(Data(bytes.suffix(1))).first!)
        XCTAssertEqual(first.title, "Example track")
        let changes = #"{"type":"data","diff":true,"payload":{"playing":false}}"# + "\n"
            + #"{"type":"data","diff":true,"payload":{"artist":null}}"# + "\n"
        let updates = try decoder.append(Data(changes.utf8))
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0]?.playing, false)
        XCTAssertEqual(updates[0]?.artworkData, "YWJj")
        XCTAssertNil(updates[1]?.artist)
        XCTAssertEqual(updates[1]?.title, "Example track")
    }

    func testNewSourceDoesNotInheritOldArtwork() throws {
        var decoder = MediaStreamDecoder()
        _ = try decoder.append(Data(snapshot.utf8))
        let change = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","title":"Video","playing":false}}"# + "\n"
        let track = try XCTUnwrap(try decoder.append(Data(change.utf8)).first!)
        XCTAssertNil(track.artworkData)
        XCTAssertNil(track.artist)
        XCTAssertEqual(track.sourceBundleIdentifier, "com.apple.Safari")
    }

    func testEmptySnapshotClearsNowPlaying() throws {
        var decoder = MediaStreamDecoder()
        _ = try decoder.append(Data(snapshot.utf8))
        let updates = try decoder.append(Data((#"{"type":"data","diff":false,"payload":{}}"# + "\n").utf8))
        XCTAssertEqual(updates.count, 1)
        XCTAssertNil(updates[0])
    }

    func testArtworkRemovalAndReplacement() throws {
        var decoder = MediaStreamDecoder()
        _ = try decoder.append(Data(snapshot.utf8))
        let removal = #"{"type":"data","diff":true,"payload":{"artworkData":null}}"# + "\n"
        XCTAssertNil(try decoder.append(Data(removal.utf8))[0]?.artworkData)
        let replacement = #"{"type":"data","diff":true,"payload":{"artworkData":"ZGVm"}}"# + "\n"
        XCTAssertEqual(try decoder.append(Data(replacement.utf8))[0]?.artworkData, "ZGVm")
        let pause = #"{"type":"data","diff":true,"payload":{"playing":false}}"# + "\n"
        XCTAssertEqual(try decoder.append(Data(pause.utf8))[0]?.artworkData, "ZGVm")
    }

    func testPlaybackClockInterpolatesAndClamps() throws {
        var decoder = MediaStreamDecoder()
        let track = try XCTUnwrap(try decoder.append(Data(snapshot.utf8)).first!)
        XCTAssertEqual(track.elapsed(at: Date(timeIntervalSince1970: 1010)), 40)
        XCTAssertEqual(track.elapsed(at: Date(timeIntervalSince1970: 900)), 30)
        XCTAssertEqual(track.elapsed(at: Date(timeIntervalSince1970: 2000)), 240)
        let pause = #"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTimeMicros":40000000}}"# + "\n"
        let paused = try XCTUnwrap(try decoder.append(Data(pause.utf8)).first!)
        XCTAssertEqual(paused.elapsed(at: Date(timeIntervalSince1970: 2000)), 40)
    }

    func testMissingTimelineAndRemovedRequiredField() throws {
        var decoder = MediaStreamDecoder()
        let update = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Radio","playing":true}}"# + "\n"
        let track = try XCTUnwrap(try decoder.append(Data(update.utf8)).first!)
        XCTAssertEqual(track.duration, 0)
        XCTAssertEqual(track.elapsed(at: .now), 0)
        let removal = #"{"type":"data","diff":true,"payload":{"bundleIdentifier":null}}"# + "\n"
        XCTAssertNil(try decoder.append(Data(removal.utf8))[0])
    }

    func testMalformedAndUnboundedOutputFail() throws {
        var malformed = MediaStreamDecoder()
        XCTAssertThrowsError(try malformed.append(Data("not JSON\n".utf8)))
        var oversized = MediaStreamDecoder()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: 8 * 1024 * 1024 + 1)))
    }
}
