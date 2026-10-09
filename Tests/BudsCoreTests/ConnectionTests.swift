import XCTest
import IOBluetooth
@testable import BudsCore

private final class TestChannel: IOBluetoothRFCOMMChannel {
    var open = false
    var closes = 0
    override func isOpen() -> Bool { open }
    override func close() -> IOReturn { closes += 1; open = false; return kIOReturnSuccess }
    override func setDelegate(_ delegate: Any!) -> IOReturn { kIOReturnSuccess }
    override func getMTU() -> BluetoothRFCOMMMTU { 990 }
    override func writeAsync(_ data: UnsafeMutableRawPointer!, length: UInt16, refcon: UnsafeMutableRawPointer!) -> IOReturn { kIOReturnSuccess }
}

private final class TestService: IOBluetoothSDPServiceRecord {
    override func getRFCOMMChannelID(_ channelID: UnsafeMutablePointer<BluetoothRFCOMMChannelID>!) -> IOReturn {
        channelID.pointee = 28
        return kIOReturnSuccess
    }
}

private final class TestDevice: IOBluetoothDevice {
    var online = true
    var queries = 0
    var opens = 0
    let testChannel = TestChannel()
    let service = TestService()
    override var name: String! { "REDMI Buds 8 Pro" }
    override func isConnected() -> Bool { online }
    override func performSDPQuery(_ target: Any!) -> IOReturn { queries += 1; return kIOReturnSuccess }
    override func getServiceRecord(for uuid: IOBluetoothSDPUUID!) -> IOBluetoothSDPServiceRecord! { service }
    override func openRFCOMMChannelAsync(_ channel: AutoreleasingUnsafeMutablePointer<IOBluetoothRFCOMMChannel?>!, withChannelID channelID: BluetoothRFCOMMChannelID, delegate: Any!) -> IOReturn {
        opens += 1
        channel.pointee = testChannel
        return kIOReturnSuccess
    }
}

final class ConnectionTests: XCTestCase {
    func testOpeningTimeoutKeepsOneAttemptAndAcceptsLateSuccess() {
        let device = TestDevice()
        let controller = BudsController(pairedDevices: { [device] })
        controller.start()
        defer { controller.stop() }
        controller.sdpQueryComplete(device, status: kIOReturnSuccess)
        // A duplicate discovery callback must not overwrite the pending channel.
        controller.sdpQueryComplete(device, status: kIOReturnSuccess)
        XCTAssertEqual(device.opens, 1)
        var settingsFailure: String?
        Task { @MainActor in
            do { try await controller.readEarbudSettings() }
            catch { settingsFailure = error.localizedDescription }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(10.2))
        XCTAssertTrue(controller.controlConnectionTimedOut)
        XCTAssertFalse(controller.connected)
        XCTAssertEqual(device.testChannel.closes, 0)
        XCTAssertNotNil(controller.lastError)
        XCTAssertNotNil(settingsFailure)
        XCTAssertFalse(controller.changing)
        controller.reconnect()
        controller.refresh()
        XCTAssertEqual(device.queries, 1)
        XCTAssertEqual(device.opens, 1)
        device.testChannel.open = true
        controller.rfcommChannelOpenComplete(device.testChannel, status: kIOReturnSuccess)
        XCTAssertTrue(controller.connected)
        XCTAssertFalse(controller.controlConnectionTimedOut)
        XCTAssertNil(controller.lastError)
        controller.rfcommChannelOpenComplete(device.testChannel, status: kIOReturnSuccess)
        XCTAssertEqual(device.testChannel.closes, 0)
    }

    func testPhysicalDisconnectClearsAnOpeningAttemptAndAllowsReconnect() {
        let device = TestDevice()
        let controller = BudsController(pairedDevices: { [device] })
        controller.start()
        defer { controller.stop() }
        controller.sdpQueryComplete(device, status: kIOReturnSuccess)
        device.online = false
        RunLoop.current.run(until: Date().addingTimeInterval(2.3))
        XCTAssertFalse(controller.bluetoothConnected)
        XCTAssertEqual(device.testChannel.closes, 1)
        device.online = true
        controller.reconnect()
        XCTAssertEqual(device.queries, 2)
        controller.sdpQueryComplete(device, status: kIOReturnSuccess)
        XCTAssertEqual(device.opens, 2)
    }
}
