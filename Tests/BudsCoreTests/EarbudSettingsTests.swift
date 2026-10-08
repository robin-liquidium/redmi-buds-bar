import XCTest
@testable import BudsCore

final class EarbudSettingsTests: XCTestCase {
    private func tlv(_ id: UInt16, _ data: [UInt8]) -> [UInt8] { [UInt8(data.count + 2), UInt8(id >> 8), UInt8(id & 255)] + data }
    private let gestures: [UInt8] = [4, 8, 8, 1, 8, 8, 2, 8, 8, 3, 8, 8, 5, 11, 11, 99, 7, 9]
    private func settings(_ extra: [UInt8] = [], runInfo: [UInt8] = []) throws -> EarbudSettings {
        try EarbudSettings(payload: tlv(2, gestures) + tlv(10, [7, 6]) + tlv(3, [0]) + tlv(4, [1]) + tlv(7, [10]) + extra, runInfo: runInfo)
    }
    func testEditingOneSidePreservesOtherSideAndUnknownGestures() throws {
        let before = try settings()
        let change = try before.change(.assignment(.doubleTap, .left, .playPause))
        XCTAssertEqual(change.payload, [5, 0, 2, 1, 1, 255])
        var expected = gestures; expected[4] = 1
        XCTAssertTrue(try EarbudSettings(payload: tlv(2, expected)).confirms(change))
        expected[5] = 3
        XCTAssertFalse(try EarbudSettings(payload: tlv(2, expected)).confirms(change))
        expected[5] = 8; expected[17] = 8
        XCTAssertFalse(try EarbudSettings(payload: tlv(2, expected)).confirms(change))
    }
    func testReadbackAllowsRecordReordering() throws {
        let change = try settings().change(.assignment(.singleTap, .right, .next))
        var expected = gestures; expected[2] = 3
        let reordered = stride(from: 0, to: expected.count, by: 3).reversed().flatMap { Array(expected[$0..<$0+3]) }
        XCTAssertTrue(try EarbudSettings(payload: tlv(2, reordered)).confirms(change))
    }
    func testUnsupportedActionsAndMissingFieldsRejectWrites() throws {
        let before = try settings()
        XCTAssertThrowsError(try before.change(.assignment(.swipe, .left, .voiceAssistant)))
        XCTAssertThrowsError(try before.change(.noiseCycle(.left, 2)))
        XCTAssertThrowsError(try before.change(.toggle(.adaptiveSound, true)))
        XCTAssertThrowsError(try before.change(.wearDetection(false)))
        XCTAssertThrowsError(try EarbudSettings(payload: tlv(2, [255])))
    }
    func testTruncatedAndDuplicateRecordsAreRejected() throws {
        XCTAssertThrowsError(try EarbudSettings(payload: tlv(2, gestures) + [4, 0, 3]))
        XCTAssertThrowsError(try EarbudSettings(payload: tlv(2, [1, 8, 8, 1, 1, 3])))
        XCTAssertThrowsError(try EarbudSettings(payload: tlv(2, gestures) + tlv(2, gestures)))
    }
    func testNoiseCycleAndWearDetectionEncoding() throws {
        let before = try settings(runInfo: [2, 10, 0])
        XCTAssertEqual(try before.change(.noiseCycle(.right, 3)).payload, [4, 0, 10, 255, 3])
        let change = try before.change(.wearDetection(false))
        XCTAssertEqual(change.opcode, 8)
        XCTAssertEqual(change.payload, [2, 6, 1])
        XCTAssertTrue(try settings(runInfo: [2, 10, 1]).confirms(change))
        XCTAssertFalse(before.confirms(change))
    }
    func testSpatialChangesPreservePreferenceAndOtherBits() throws {
        let before = try settings(tlv(0x1d, [3]))
        XCTAssertEqual(try before.change(.spatial(.headTracking)).payload, [3, 0, 0x1d, 11])
        XCTAssertEqual(try settings(tlv(0x1d, [11])).change(.spatialPreference(0)).payload, [3, 0, 0x1d, 9])
        XCTAssertNil(try settings(tlv(0x1d, [255])).spatialMode)
    }
    func testEqualizerKeepsAllOtherFrequenciesAndSignedGains() throws {
        let eq: [UInt8] = [1, 10, 10, 138, 1, 0, 2, 0, 100, 131, 3, 232, 2]
        let before = try settings(tlv(0x37, eq))
        let change = try before.change(.equalizerBand(1000, -5))
        XCTAssertEqual(change.payload, [15, 0, 0x37, 1, 10, 1, 1, 1, 0, 2, 0, 100, 131, 3, 232, 133])
        var confirmed = eq; confirmed[12] = 133
        XCTAssertTrue(try settings(tlv(0x37, confirmed)).confirms(change))
        confirmed[9] = 0
        XCTAssertFalse(try settings(tlv(0x37, confirmed)).confirms(change))
        XCTAssertThrowsError(try before.change(.equalizerBand(500, 0)))
        XCTAssertThrowsError(try before.change(.equalizerBand(100, 11)))
    }
    func testFitAndFindRequireValidDeviceStatus() {
        XCTAssertEqual(EarTipFit.results(tlv(6, [1, 2])), "Left: Good seal · Right: Adjust ear tip")
        XCTAssertNil(EarTipFit.results(tlv(6, [0, 0])))
        XCTAssertFalse(EarTipFit.mayFind(tlv(12, [12])))
        XCTAssertFalse(EarTipFit.mayFind(tlv(12, [255])))
        XCTAssertFalse(EarTipFit.mayFind([]))
        XCTAssertTrue(EarTipFit.mayFind(tlv(12, [0])))
    }
    func testEQEditingRequiresCustomPreset() throws {
        let data: [UInt8] = [1, 10, 6, 6, 0, 0, 1, 3, 232, 0]
        let defaults = try EarbudSettings(payload: tlv(2, gestures) + tlv(7, [0]) + tlv(0x37, data))
        XCTAssertThrowsError(try defaults.change(.equalizerBand(1000, 2)))
    }
    func testModelEqualizerReplyHasTenBandsAndSixDBLimit() throws {
        let data: [UInt8] = [1, 10, 6, 6, 0, 0, 10, 0, 62, 0, 0, 125, 0, 0, 250, 0, 1, 244, 0, 3, 232, 0, 7, 208, 0, 15, 160, 0, 31, 64, 0, 46, 224, 0, 62, 128, 0]
        let before = try settings(tlv(0x37, data))
        XCTAssertEqual(before.equalizer?.bands.count, 10)
        XCTAssertEqual(before.equalizer?.bound, 6)
        XCTAssertThrowsError(try before.change(.equalizerBand(1000, 7)))
        let change = try before.change(.equalizerBand(1000, -6))
        var actual = data; actual[21] = 134
        XCTAssertTrue(try settings(tlv(0x37, actual)).confirms(change))
    }
}
