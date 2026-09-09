import Foundation
import Combine
import IOBluetooth

/// All transport callbacks and published state live on the main run loop.
public final class BudsController: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    @Published public private(set) var status = "Looking for your buds…"
    @Published public private(set) var connected = false
    @Published public private(set) var noise: NoiseSetting?
    @Published public private(set) var left: Battery?
    @Published public private(set) var right: Battery?
    @Published public private(set) var caseBattery: Battery?
    @Published public private(set) var firmware = ""
    @Published public private(set) var productID: UInt16?
    @Published public private(set) var changing = false
    @Published public private(set) var lastError: String?
    public var log: ((String) -> Void)?
    public var onNoise: ((NoiseSetting) -> Void)?
    public var onCommandComplete: ((Bool) -> Void)?

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var decoder = PacketDecoder()
    private var sequence: UInt8 = 0
    private var timer: Timer?
    private var timeout: Timer?
    private var queryTimeout: Timer?
    private var connecting = false
    private var ancStrength: UInt8 = 19 // Initial value verified on this model; updated from actual reads.
    private var transparencyStrength: UInt8 = 0
    private var refreshTicks = 0
    private var stopped = false
    private var queue: [(opcode: UInt8, payload: [UInt8], completion: (Packet?) -> Void)] = []
    private var pending: (opcode: UInt8, sequence: UInt8, completion: (Packet?) -> Void)?

    public override init() { super.init() }
    public func start() {
        stopped = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.connected {
                if self.device?.isConnected() != true { self.disconnect("Buds disconnected"); return }
                self.refreshTicks += 1
                if self.refreshTicks >= 6 { self.refreshTicks = 0; self.refresh() }
            } else if !self.connecting { self.connect() }
        }
        connect()
    }
    public func stop() {
        stopped = true
        timer?.invalidate(); timer = nil
        disconnect("Disconnected")
    }
    public func reconnect() {
        disconnect("Reconnecting…")
        stopped = false
        connect()
    }
    private func connect() {
        guard !stopped, !connecting, !connected else { return }
        guard let buds = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: {
            ($0.name ?? "").localizedCaseInsensitiveContains("REDMI Buds 8 Pro") && $0.isConnected()
        }) else { status = "Connect REDMI Buds 8 Pro in Bluetooth settings"; return }
        device = buds
        connecting = true
        lastError = nil
        status = "Connecting to your buds…"
        let result = buds.performSDPQuery(self)
        if result != kIOReturnSuccess { disconnect("Service discovery failed (\(result))"); return }
        queryTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.disconnect("Bluetooth connection timed out")
        }
    }
    @objc public func sdpQueryComplete(_ queriedDevice: IOBluetoothDevice!, status result: IOReturn) {
        guard connecting, !stopped, queriedDevice == device else { return }
        guard result == kIOReturnSuccess else { disconnect("Service discovery failed (\(result))"); return }
        // Resolve Xiaomi's actual advertised channel. Never assume another model's channel number.
        let uuidBytes: [UInt8] = [0x00,0x00,0xfd,0x2d,0x00,0x00,0x10,0x00,0x80,0x00,0x00,0x80,0x5f,0x9b,0x34,0xfb]
        let uuid = uuidBytes.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: $0.count) }
        guard let service = queriedDevice.getServiceRecord(for: uuid) else { disconnect("Xiaomi control service unavailable"); return }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess, channelID > 0 else { disconnect("Xiaomi control channel unavailable"); return }
        log?("Opening MIWEAR RFCOMM channel \(channelID)")
        let result = queriedDevice.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        if result != kIOReturnSuccess { disconnect("Could not open control channel (\(result))") }
    }
    public func rfcommChannelOpenComplete(_ openedChannel: IOBluetoothRFCOMMChannel!, status result: IOReturn) {
        guard !stopped, connecting, openedChannel == channel else { openedChannel?.close(); return }
        queryTimeout?.invalidate(); queryTimeout = nil
        guard result == kIOReturnSuccess else { disconnect("Control connection failed (\(result))"); return }
        connecting = false
        connected = true
        status = "Reading your buds…"
        refresh()
    }
    public func rfcommChannelClosed(_ closedChannel: IOBluetoothRFCOMMChannel!) {
        guard closedChannel == channel else { return }
        disconnect("Buds disconnected")
    }
    private func disconnect(_ message: String) {
        connecting = false; connected = false
        queryTimeout?.invalidate(); queryTimeout = nil
        timeout?.invalidate(); timeout = nil
        queue.removeAll(); pending = nil
        decoder = PacketDecoder()
        let oldChannel = channel
        channel = nil
        oldChannel?.setDelegate(nil)
        oldChannel?.close()
        noise = nil; left = nil; right = nil; caseBattery = nil
        firmware = ""; productID = nil
        status = message
        log?(message)
        if changing { finishChange(false, error: message) }
    }
    private func send(_ bytes: [UInt8]) -> Bool {
        guard let channel, channel.isOpen() else { return false }
        log?("TX " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
        var buffer = bytes
        let result = buffer.withUnsafeMutableBytes { channel.writeSync($0.baseAddress!, length: UInt16($0.count)) }
        return result == kIOReturnSuccess
    }
    private func request(_ opcode: UInt8, _ payload: [UInt8], completion: @escaping (Packet?) -> Void) {
        guard connected else { completion(nil); return }
        queue.append((opcode, payload, completion))
        processQueue()
    }
    private func processQueue() {
        guard pending == nil, !queue.isEmpty, connected else { return }
        let item = queue.removeFirst()
        sequence &+= 1
        pending = (item.opcode, sequence, item.completion)
        timeout = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pending else { return }
            self.pending = nil; self.timeout = nil
            self.log?("Request timed out: \(pending.opcode)")
            pending.completion(nil)
            self.processQueue()
        }
        if !send(Packet.encode(opcode: item.opcode, sequence: sequence, payload: item.payload)) {
            timeout?.invalidate(); timeout = nil
            pending = nil
            item.completion(nil)
            disconnect("Bluetooth write failed")
        }
    }
    public func rfcommChannelData(_ sender: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard sender == channel, let pointer, length > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: length))
        log?("RX " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
        for packet in decoder.feed(bytes) {
            if packet.isRequest {
                if packet.needsReply {
                    _ = send(Packet.encode(opcode: packet.opcode, sequence: packet.sequence, payload: [], response: true))
                }
                // Broadcasts can be retransmitted after a later change. Query authoritative state.
                if packet.opcode == 0xf4 || packet.opcode == 0x0e {
                    if !changing && pending == nil && queue.isEmpty { refreshNoise() }
                }
                continue
            }
            guard let pending, packet.sequence == pending.sequence, packet.opcode == pending.opcode else { continue }
            self.pending = nil
            timeout?.invalidate(); timeout = nil
            pending.completion(packet.status == 0 ? packet : nil)
            processQueue()
        }
    }
    public func refresh() {
        guard connected, !changing, pending == nil, queue.isEmpty else { return }
        request(0x02, [0xff,0xff,0xff,0xff]) { [weak self] packet in
            guard let self, let packet else { return }
            for item in parseTLVs(packet.payload, idWidth: 1) {
                if item.id == 7, item.value.count == 3 {
                    self.left = Battery(item.value[0]); self.right = Battery(item.value[1]); self.caseBattery = Battery(item.value[2])
                } else if item.id == 1, item.value.count >= 2 {
                    let a = item.value[0], b = item.value[1]
                    self.firmware = "\(a >> 4).\(a & 15).\(b >> 4).\(b & 15)"
                } else if item.id == 3, item.value.count == 4 {
                    self.productID = UInt16(item.value[2]) << 8 | UInt16(item.value[3])
                }
            }
        }
        refreshNoise()
    }
    private func refreshNoise(completion: ((NoiseSetting?) -> Void)? = nil) {
        request(0xf3, [0x00,0x0b]) { [weak self] packet in
            guard let self else { return }
            let setting = packet.flatMap { parseNoise($0.payload) }
            if let setting {
                self.noise = setting
                if setting.mode == .anc { self.ancStrength = setting.strength }
                if setting.mode == .transparency { self.transparencyStrength = setting.strength }
                self.status = "Connected"
                self.onNoise?(setting)
            } else if !self.changing {
                self.noise = nil
                self.lastError = "Could not read noise control. Try reconnecting."
                self.status = "Noise control unavailable"
            }
            completion?(setting)
        }
    }
    public func setMode(_ mode: NoiseMode) {
        setNoise(NoiseSetting(mode: mode, strength: mode == .anc ? ancStrength : mode == .transparency ? transparencyStrength : 0))
    }
    public func setStrength(_ strength: UInt8, for mode: NoiseMode) {
        guard noise?.mode == mode, let range = mode.strengthRange, range.contains(strength) else { return }
        setNoise(NoiseSetting(mode: mode, strength: strength), manualANC: mode == .anc)
    }
    public func setNoise(_ setting: NoiseSetting, manualANC: Bool = false) {
        guard connected, noise != nil, !changing else { return }
        changing = true; lastError = nil
        if manualANC {
            // Xiaomi's adaptive mode overrides manual strength. Read it before changing anything.
            request(0xf3, [0, 0x25]) { [weak self] response in
                guard let self else { return }
                guard let value = response.flatMap({ parseTLVs($0.payload, idWidth: 2).first { $0.id == 0x25 }?.value }),
                      value == [0] || value == [1] else {
                    self.finishChange(false, error: "Could not check smart ANC. Try again."); return
                }
                if value == [0] { self.writeNoise(setting); return }
                self.request(0xf2, [3, 0, 0x25, 0]) { [weak self] ack in
                    guard let self else { return }
                    guard ack != nil else { self.finishChange(false, error: "Could not turn off smart ANC."); return }
                    self.request(0xf3, [0, 0x25]) { [weak self] reply in
                        guard let self else { return }
                        guard reply.flatMap({ parseTLVs($0.payload, idWidth: 2).first { $0.id == 0x25 }?.value }) == [0] else {
                            self.finishChange(false, error: "Buds did not confirm manual ANC."); return
                        }
                        self.writeNoise(setting)
                    }
                }
            }
        } else { writeNoise(setting) }
    }
    private func writeNoise(_ setting: NoiseSetting) {
        request(0xf2, [0x04,0x00,0x0b,setting.mode.rawValue,setting.strength]) { [weak self] response in
            guard let self else { return }
            guard response != nil else { self.finishChange(false, error: "Buds did not acknowledge the change. Refresh and try again."); self.refreshNoise(); return }
            self.refreshNoise { [weak self] actual in
                guard let self else { return }
                self.finishChange(actual == setting, error: actual == setting ? nil : "Buds did not confirm the requested mode. Try again.")
            }
        }
    }
    private func finishChange(_ success: Bool, error: String?) {
        changing = false; lastError = error
        log?(success ? "Mode verified by readback" : error ?? "Change failed")
        onCommandComplete?(success)
    }
}
