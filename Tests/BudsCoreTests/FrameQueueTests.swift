import XCTest
@testable import BudsCore

final class FrameQueueTests: XCTestCase {
    func testPeerReplyNeverInterruptsFirmwareFrame() {
        let data = [UInt8](repeating: 0x42, count: 4100)
        let firmware = Packet.encode(opcode: 0xe5, sequence: 9, payload: data)
        let reply = Packet.encode(opcode: 0x0e, sequence: 10, payload: [], response: true)
        for mtu in [1, 127, 990, 4096] {
            var queue = MMAFrameQueue()
            var wire: [UInt8] = []
            queue.append(firmware)
            let first = queue.nextChunk(maximum: mtu)!
            XCTAssertLessThanOrEqual(first.count, mtu)
            queue.append(reply) // Peer requested an acknowledgment during the OTA frame.
            XCTAssertNil(queue.nextChunk(maximum: mtu)) // Only one SDK write may be in flight.
            wire += first
            queue.completed(success: true)
            while let chunk = queue.nextChunk(maximum: mtu) {
                XCTAssertLessThanOrEqual(chunk.count, mtu)
                wire += chunk
                queue.completed(success: true)
            }
            XCTAssertEqual(wire, firmware + reply)
            var decoder = PacketDecoder()
            XCTAssertEqual(decoder.feed(wire).map(\.opcode), [0xe5, 0x0e])
        }
    }
    func testWriteFailureDiscardsThePartialFrameAndQueuedReplies() {
        var queue = MMAFrameQueue()
        queue.append([1, 2, 3, 4]); queue.append([5, 6])
        XCTAssertNil(queue.nextChunk(maximum: 0))
        XCTAssertEqual(queue.nextChunk(maximum: 2), [1, 2])
        queue.completed(success: false)
        XCTAssertNil(queue.nextChunk(maximum: 2))
        queue.append([7, 8])
        XCTAssertEqual(queue.nextChunk(maximum: 2), [7, 8])
        queue.completed(success: true)
        XCTAssertNil(queue.nextChunk(maximum: 2))
    }
}
