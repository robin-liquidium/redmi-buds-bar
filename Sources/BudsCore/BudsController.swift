import Foundation
import Combine
import IOBluetooth

/// All transport callbacks and published state live on the main run loop.
public final class BudsController: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    @Published public private(set) var status = "Looking for your buds…"
    @Published public private(set) var connected = false
    @Published public private(set) var bluetoothConnected = false
    @Published public private(set) var controlConnectionTimedOut = false
    @Published public private(set) var noise: NoiseSetting?
    @Published public private(set) var left: Battery?
    @Published public private(set) var right: Battery?
    @Published public private(set) var caseBattery: Battery?
    @Published public private(set) var firmware = ""
    @Published public private(set) var peerFirmware: String?
    @Published public private(set) var productID: UInt16?
    @Published public private(set) var changing = false
    @Published public private(set) var updatingFirmware = false
    @Published public private(set) var earbudSettings: EarbudSettings?
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
    private var idleTimeout: Timer?
    private var connecting = false
    private var ancStrength: UInt8 = 19 // Initial value verified on this model; updated from actual reads.
    private var transparencyStrength: UInt8 = 0
    private var refreshTicks = 0
    private var connectionRetryTicks = 0
    private var stopped = false
    private var queue: [(opcode: UInt8, payload: [UInt8], timeout: TimeInterval, completion: (Packet?) -> Void)] = []
    private var pending: (opcode: UInt8, sequence: UInt8, completion: (Packet?) -> Void)?
    private var connectionWaiters: [CheckedContinuation<Void, Error>] = []
    private var frames = MMAFrameQueue()
    private var writingChunk: NSMutableData?
    private let pairedDevices: () -> [IOBluetoothDevice]

    public override convenience init() {
        self.init(pairedDevices: { IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] })
    }
    init(pairedDevices: @escaping () -> [IOBluetoothDevice]) {
        self.pairedDevices = pairedDevices
        super.init()
    }
    public func start() {
        stopped = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let wasBluetoothConnected = self.bluetoothConnected
            self.updateBluetoothConnection()
            guard !self.updatingFirmware else { return }
            if (self.connected || self.connecting), self.device?.isConnected() != true {
                self.disconnect("Buds disconnected"); return
            }
            guard !self.connecting else { return }
            if self.connected {
                self.refreshTicks += 1
                if self.refreshTicks >= 15 { self.refreshTicks = 0; self.refresh() }
            } else if !self.connecting {
                self.connectionRetryTicks += 1
                // Connect immediately on detection, but space failed attempts six seconds apart.
                if (!wasBluetoothConnected && self.bluetoothConnected) || self.connectionRetryTicks >= 3 {
                    self.connectionRetryTicks = 0
                    self.connect()
                }
            }
        }
        timer?.tolerance = 0.2
        connect()
    }
    public func stop() {
        guard !updatingFirmware else { return }
        stopped = true
        timer?.invalidate(); timer = nil
        disconnect("Disconnected")
        bluetoothConnected = false
    }
    public func reconnect() {
        guard !updatingFirmware else { return }
        // Closing an opening channel does not reliably cancel it in bluetoothd.
        // Keep its delegate so a late success can finish the original attempt.
        if connecting, channel != nil, device?.isConnected() == true { return }
        disconnect("Reconnecting…")
        stopped = false
        connect()
    }
    private func matchesBuds(_ device: IOBluetoothDevice) -> Bool {
        if (device.name ?? "").localizedCaseInsensitiveContains("REDMI Buds 8 Pro") { return true }
        guard let verified = UserDefaults.standard.string(forKey: "verifiedBudsAddress"), let address = device.addressString else { return false }
        return address == verified
    }
    @discardableResult
    private func updateBluetoothConnection() -> IOBluetoothDevice? {
        let buds = pairedDevices().first(where: {
            matchesBuds($0) && $0.isConnected()
        })
        if bluetoothConnected != (buds != nil) { bluetoothConnected = buds != nil }
        return buds
    }
    private func connect() {
        guard !stopped, !connecting, channel == nil else { return }
        guard let buds = updateBluetoothConnection() else { status = "Connect REDMI Buds 8 Pro in Bluetooth settings"; return }
        device = buds
        connecting = true
        lastError = nil
        status = "Connecting to your buds…"
        let result = buds.performSDPQuery(self)
        if result != kIOReturnSuccess { disconnect("Service discovery failed (\(result))"); return }
        queryTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.channel == nil { self.disconnect("Bluetooth service discovery timed out"); return }
            // A timeout is not an RFCOMM open-completion event. Discarding the
            // channel here can leave an orphaned DLCI and make every retry fail.
            // Keep it until a callback or physical disconnect; a force-close
            // after another grace period cannot safely clear that daemon state.
            self.queryTimeout = nil
            self.controlConnectionTimedOut = true
            self.connected = false
            self.status = "Waiting for earbud controls"
            self.lastError = "If controls stay unavailable, restart your earbuds using their charging case, then reconnect them to this Mac."
            self.log?("Control channel opening timed out; retaining pending channel until completion or Bluetooth disconnect")
            self.failRequests("The earbuds' control connection timed out. Restart the earbuds and reconnect.")
        }
    }
    @objc public func sdpQueryComplete(_ queriedDevice: IOBluetoothDevice!, status result: IOReturn) {
        guard connecting, !stopped, queriedDevice == device, channel == nil else { return }
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
        guard let openedChannel else { return }
        guard openedChannel == channel else { openedChannel.close(); return }
        // An extra completion for the current, already-open channel must not close it.
        guard !stopped, connecting else { return }
        queryTimeout?.invalidate(); queryTimeout = nil
        guard result == kIOReturnSuccess else { disconnect("Control connection failed (\(result))"); return }
        connecting = false
        controlConnectionTimedOut = false
        lastError = nil
        connected = true
        status = "Reading your buds…"
        let waiters = connectionWaiters; connectionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if queue.isEmpty { if !updatingFirmware { refresh() } }
        else { processQueue() }
    }
    public func rfcommChannelClosed(_ closedChannel: IOBluetoothRFCOMMChannel!) {
        guard closedChannel == channel else { return }
        disconnect("Buds disconnected")
    }
    private func disconnect(_ message: String) {
        connecting = false; connected = false
        controlConnectionTimedOut = false
        queryTimeout?.invalidate(); queryTimeout = nil
        idleTimeout?.invalidate(); idleTimeout = nil
        timeout?.invalidate(); timeout = nil
        decoder = PacketDecoder()
        frames = MMAFrameQueue()
        let oldChannel = channel
        channel = nil
        oldChannel?.setDelegate(nil)
        oldChannel?.close()
        writingChunk = nil
        noise = nil; left = nil; right = nil; caseBattery = nil
        firmware = ""; peerFirmware = nil; productID = nil
        status = message
        log?(message)
        failRequests(message)
    }
    private func failRequests(_ message: String) {
        let failedPending = pending; pending = nil
        let failedQueue = queue; queue.removeAll()
        let failedConnections = connectionWaiters; connectionWaiters.removeAll()
        failedConnections.forEach { $0.resume(throwing: FirmwareFailure(message)) }
        failedPending?.completion(nil)
        failedQueue.forEach { $0.completion(nil) }
        if changing { finishChange(false, error: message) }
    }
    private func send(_ bytes: [UInt8]) -> Bool {
        guard let channel, channel.isOpen() else { return false }
        if updatingFirmware { log?("TX firmware frame: opcode=\(String(format: "%02X", bytes[4])) bytes=\(bytes.count) mtu=\(channel.getMTU())") }
        else { log?("TX " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")) }
        frames.append(bytes)
        return drainWrites()
    }
    private func drainWrites() -> Bool {
        guard writingChunk == nil else { return true }
        guard let channel, channel.isOpen(), channel.getMTU() > 0 else { return false }
        guard let bytes = frames.nextChunk(maximum: Int(channel.getMTU())) else { return true }
        let chunk = NSMutableData(data: Data(bytes))
        writingChunk = chunk // Keep the asynchronous write buffer alive through its callback.
        let result = channel.writeAsync(chunk.mutableBytes, length: UInt16(chunk.length), refcon: nil)
        if result != kIOReturnSuccess {
            writingChunk = nil
            frames.completed(success: false)
        }
        return result == kIOReturnSuccess
    }
    public func rfcommChannelWriteComplete(_ sender: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status result: IOReturn) {
        guard sender == channel, writingChunk != nil else { return }
        writingChunk = nil
        frames.completed(success: result == kIOReturnSuccess)
        if result != kIOReturnSuccess || !drainWrites() { disconnect("Bluetooth write failed (\(result))") }
    }
    private func request(_ opcode: UInt8, _ payload: [UInt8], timeout: TimeInterval = 3, completion: @escaping (Packet?) -> Void) {
        guard connected else { completion(nil); return }
        queue.append((opcode, payload, timeout, completion))
        processQueue()
    }
    private func processQueue() {
        guard pending == nil, connected else { return }
        if queue.isEmpty {
            guard !changing, !updatingFirmware, channel != nil else { return }
            idleTimeout?.invalidate()
            idleTimeout = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self, self.pending == nil, self.queue.isEmpty, !self.changing, !self.updatingFirmware else { return }
                let idleChannel = self.channel
                self.channel = nil
                self.decoder = PacketDecoder()
                self.frames = MMAFrameQueue()
                idleChannel?.setDelegate(nil)
                idleChannel?.close()
                self.writingChunk = nil
                self.log?("Released idle control channel; audio remains connected")
            }
            return
        }
        idleTimeout?.invalidate(); idleTimeout = nil
        guard let channel, channel.isOpen() else { connect(); return }
        let item = queue.removeFirst()
        sequence &+= 1
        pending = (item.opcode, sequence, item.completion)
        timeout = Timer.scheduledTimer(withTimeInterval: item.timeout, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pending else { return }
            self.pending = nil; self.timeout = nil
            self.log?("Request timed out: \(pending.opcode)")
            pending.completion(nil)
            self.processQueue()
        }
        if !send(Packet.encode(opcode: item.opcode, sequence: sequence, payload: item.payload)) {
            disconnect("Bluetooth write failed")
        }
    }
    public func rfcommChannelData(_ sender: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard sender == channel, let pointer, length > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: length))
        if !updatingFirmware { log?("RX " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")) }
        for packet in decoder.feed(bytes) {
            if updatingFirmware { log?("RX firmware reply: opcode=\(String(format: "%02X", packet.opcode)) status=\(packet.status.map(String.init) ?? "request") bytes=\(packet.payload.count)") }
            if packet.isRequest {
                if packet.needsReply {
                    if !send(Packet.encode(opcode: packet.opcode, sequence: packet.sequence, payload: [], response: true)) {
                        disconnect("Bluetooth acknowledgment failed")
                        return
                    }
                }
                // Broadcasts can be retransmitted after a later change. Query authoritative state.
                if packet.opcode == 0xf4 || packet.opcode == 0x0e {
                    if !changing && !updatingFirmware && pending == nil && queue.isEmpty { refreshNoise() }
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
        guard connected, !connecting, !changing, !updatingFirmware, pending == nil, queue.isEmpty else { return }
        request(0x02, [0xff,0xff,0xff,0xff]) { [weak self] packet in
            guard let self, let packet else { return }
            for item in parseTLVs(packet.payload, idWidth: 1) {
                if item.id == 7, item.value.count == 3 {
                    self.left = Battery(item.value[0]); self.right = Battery(item.value[1]); self.caseBattery = Battery(item.value[2])
                } else if item.id == 1, item.value.count >= 2 {
                    let a = item.value[0], b = item.value[1]
                    self.firmware = "\(a >> 4).\(a & 15).\(b >> 4).\(b & 15)"
                    self.peerFirmware = item.value.count >= 4 ? MMAFirmwareImage.versionName(UInt16(item.value[2]) << 8 | UInt16(item.value[3])) : nil
                } else if item.id == 3, item.value.count == 4 {
                    self.productID = UInt16(item.value[2]) << 8 | UInt16(item.value[3])
                    if item.value == [0x27, 0x17, 0x50, 0xe3], let address = self.device?.addressString {
                        UserDefaults.standard.set(address, forKey: "verifiedBudsAddress")
                    }
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

    @MainActor private func ensureControlConnection() async throws {
        if connected, channel?.isOpen() == true { return }
        guard !stopped else { throw FirmwareFailure("Open the earbuds controls before changing settings.") }
        guard !controlConnectionTimedOut else {
            throw FirmwareFailure("The earbuds' control connection is still pending. Restart your earbuds using their charging case, then reconnect them to this Mac.")
        }
        if updateBluetoothConnection() == nil {
            guard let paired = pairedDevices().first(where: {
                matchesBuds($0)
            }), paired.openConnection() == kIOReturnSuccess else {
                throw FirmwareFailure("Connect REDMI Buds 8 Pro to this Mac in Bluetooth settings.")
            }
        }
        guard updateBluetoothConnection() != nil else {
            throw FirmwareFailure("The earbuds have not connected to this Mac yet. Try again once Bluetooth settings shows Connected.")
        }
        try await withCheckedThrowingContinuation { continuation in
            connectionWaiters.append(continuation)
            connect()
        }
    }

    @MainActor private func controlRequest(_ opcode: UInt8, _ payload: [UInt8], timeout: TimeInterval = 4) async throws -> Packet {
        guard connected, channel?.isOpen() == true else { throw FirmwareFailure("The earbuds' control connection is unavailable.") }
        return try await withCheckedThrowingContinuation { continuation in
            request(opcode, payload, timeout: timeout) { packet in
                if let packet { continuation.resume(returning: packet) }
                else { continuation.resume(throwing: FirmwareFailure("The earbuds did not complete control command \(String(format: "%02X", opcode)).")) }
            }
        }
    }

    @MainActor public func readEarbudSettings() async throws {
        try await settingsOperation(nil, action: nil)
    }
    @MainActor public func editEarbudSetting(_ edit: EarbudEdit) async throws {
        try await settingsOperation(edit, action: nil)
    }
    @MainActor public func performEarbudAction(_ action: EarbudAction) async throws -> String {
        try await settingsOperation(nil, action: action)
        return earbudActionResult ?? "Done"
    }
    @Published public private(set) var earbudActionResult: String?
    @MainActor private func settingsOperation(_ edit: EarbudEdit?, action: EarbudAction?) async throws {
        guard !changing, !updatingFirmware else { throw FirmwareFailure("Wait for the current earbud operation to finish.") }
        changing = true; lastError = nil
        idleTimeout?.invalidate(); idleTimeout = nil
        defer { changing = false; processQueue() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while pending != nil || !queue.isEmpty {
                guard ContinuousClock.now < deadline else { throw FirmwareFailure("The earbuds' controls are busy. Try again.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await ensureControlConnection()
            try await readFirmwareVersions() // Confirm this model before offering its gesture actions.
            if let action {
                earbudActionResult = nil
                switch action {
                case .fitTest:
                    _ = try await controlRequest(0xf2, [3, 0, 5, 1])
                    try await Task.sleep(for: .seconds(5))
                    for _ in 0..<10 {
                        if let result = EarTipFit.results(try await controlRequest(0xf3, [0, 6]).payload) { earbudActionResult = result; return }
                        try await Task.sleep(for: .seconds(1))
                    }
                    throw FirmwareFailure("The fit test did not return a result. Wear both earbuds and try again.")
                case let .find(side):
                    guard [UInt8(1), 2, 3].contains(side), EarTipFit.mayFind(try await controlRequest(0xf3, [0, 12]).payload) else {
                        throw FirmwareFailure("Take both earbuds out of your ears before playing the find sound.")
                    }
                    _ = try await controlRequest(0xf2, [4, 0, 9, 1, side])
                    earbudActionResult = "Find sound requested. Tap Stop sound when you have found your earbuds."
                case .stopFinding:
                    _ = try await controlRequest(0xf2, [4, 0, 9, 0, 3])
                    earbudActionResult = "Stop sound acknowledged."
                }
                return
            }
            let before = try await queryEarbudSettings()
            earbudSettings = before
            if let edit {
                let change = try before.change(edit)
                try Task.checkCancellation()
                _ = try await controlRequest(change.opcode, change.payload)
                let actual = try await queryEarbudSettings()
                earbudSettings = actual
                guard actual.confirms(change) else { throw FirmwareFailure("The earbuds did not confirm the setting change. Their current settings are shown.") }
                log?("Earbud setting verified: config=\(change.id)")
            }
        } catch { lastError = error.localizedDescription; throw error }
    }

    @MainActor private func queryEarbudSettings() async throws -> EarbudSettings {
        var payload: [UInt8] = []
        for offset in stride(from: 0, to: EarbudSettings.query.count, by: 2) {
            let query = Array(EarbudSettings.query[offset..<offset + 2])
            payload += try await controlRequest(0xf3, query).payload
            log?("Read earbud config \(query[1])")
        }
        return try EarbudSettings(payload: payload, runInfo: try await controlRequest(0x09, EarbudSettings.wearQuery).payload)
    }
    @MainActor private func beginFirmwareOperation() async throws {
        guard !updatingFirmware, !changing else { throw FirmwareFailure("Wait for the current earbud operation to finish.") }
        updatingFirmware = true
        idleTimeout?.invalidate(); idleTimeout = nil
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while pending != nil || !queue.isEmpty {
                guard ContinuousClock.now < deadline else { throw FirmwareFailure("The earbuds' controls are busy. Try again.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await ensureControlConnection()
        } catch { endFirmwareOperation(); throw error }
    }
    private func endFirmwareOperation() {
        updatingFirmware = false
        if connected, noise == nil { refresh() }
        else { processQueue() }
    }

    @MainActor private func readFirmwareVersions() async throws {
        let fields = parseTLVs(try await controlRequest(0x02, [0xff, 0xff, 0xff, 0xff]).payload, idWidth: 1)
        guard fields.first(where: { $0.id == 3 })?.value == [0x27, 0x17, 0x50, 0xe3],
              let versions = fields.first(where: { $0.id == 1 })?.value, versions.count == 4 else {
            throw FirmwareFailure("These settings require the Chinese REDMI Buds 8 Pro model (2717/50E3), with both earbuds connected.")
        }
        productID = 0x50e3
        if let address = device?.addressString { UserDefaults.standard.set(address, forKey: "verifiedBudsAddress") }
        firmware = MMAFirmwareImage.versionName(UInt16(versions[0]) << 8 | UInt16(versions[1]))
        peerFirmware = MMAFirmwareImage.versionName(UInt16(versions[2]) << 8 | UInt16(versions[3]))
        if let batteries = fields.first(where: { $0.id == 7 })?.value, batteries.count == 3 {
            left = Battery(batteries[0]); right = Battery(batteries[1]); caseBattery = Battery(batteries[2])
        }
        log?("Firmware readback: primary=\(firmware) peer=\(peerFirmware ?? "unavailable")")
    }

    @MainActor public func checkFirmwareVersions() async throws {
        try await beginFirmwareOperation()
        defer { endFirmwareOperation() }
        try await readFirmwareVersions()
    }
    @MainActor private func firmwareEligibility(_ image: MMAFirmwareImage) async throws {
        try await readFirmwareVersions()
        guard let current = MMAFirmwareImage.versionCode(firmware), current >> 12 == image.version >> 12, current <= image.version,
              let peer = peerFirmware.flatMap(MMAFirmwareImage.versionCode), peer >> 12 == image.version >> 12, peer <= image.version else {
            throw FirmwareFailure("The firmware does not match both earbuds' hardware and software versions.")
        }
        let identifier = try await controlRequest(0xe1, []).payload
        guard identifier == [0, 0, 0, 0, 0, 14] else { throw FirmwareFailure("This model's firmware identification layout is not supported.") }
        let reply = try await controlRequest(0xe2, image.identification).payload
        guard reply.count == 1 else { throw FirmwareFailure("The earbuds returned an invalid update-readiness response.") }
        log?("Firmware eligibility: result=\(reply[0]) target=\(image.versionName)")
        if let problem = FirmwareFailure.eligibility(reply[0]) { throw FirmwareFailure(problem) }
    }
    @MainActor public func checkFirmwareReadiness(_ image: MMAFirmwareImage) async throws {
        try await beginFirmwareOperation()
        defer { endFirmwareOperation() }
        try await firmwareEligibility(image)
    }

    /// Installation is invoked only by the Mac app's explicit Update earbuds action.
    @MainActor public func installFirmware(_ image: MMAFirmwareImage, progress: (Double, String) -> Void) async throws {
        try await beginFirmwareOperation()
        defer { endFirmwareOperation() }
        var entered = false
        do {
            try await firmwareEligibility(image)
            try Task.checkCancellation()
            progress(0, "Preparing the earbuds…")
            entered = true
            var block = try MMAUpdateBlock(response: try await controlRequest(0xe3, [], timeout: 30).payload, entering: true)
            let withCRC = block.requiresCRC
            var previousOffset = -1
            while !block.finished {
                try Task.checkCancellation()
                guard block.offset > previousOffset else { throw FirmwareFailure("The firmware transfer stopped making progress.") }
                let payload = try image.block(offset: block.offset, length: block.length, withCRC: withCRC)
                if block.delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(block.delayMilliseconds)) }
                progress(Double(block.offset) / Double(image.bytes.count), "Updating. Keep both earbuds in the open case.")
                log?("Firmware block: offset=\(block.offset) length=\(block.length)")
                previousOffset = block.offset
                block = try MMAUpdateBlock(response: try await controlRequest(0xe5, payload, timeout: 12).payload, entering: false)
            }
            try Task.checkCancellation()
            if block.delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(block.delayMilliseconds)) }
            progress(1, "Verifying the firmware…")
            guard try await controlRequest(0xe6, [], timeout: 30).payload == [0] else {
                throw FirmwareFailure("The earbuds did not verify the firmware.")
            }
            entered = false
            log?("Firmware transfer verified: \(image.versionName)")
            progress(1, "Restarting and checking both earbuds…")
            do { _ = try await controlRequest(0x03, [0], timeout: 5) }
            catch { log?("Firmware reboot acknowledgment: \(error.localizedDescription)") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(5))
                do {
                    try await ensureControlConnection()
                    try await readFirmwareVersions()
                    if firmware == image.versionName, peerFirmware == image.versionName {
                        log?("Firmware update complete: both earbuds \(image.versionName)")
                        lastError = nil; status = "Connected"
                        return
                    }
                } catch { log?("Waiting for updated earbuds: \(error.localizedDescription)") }
            }
            throw FirmwareFailure("Firmware transfer was verified, but both new versions could not be confirmed yet. Reconnect and check the versions before trying another update.")
        } catch {
            if entered, connected, channel?.isOpen() == true {
                do { log?("Firmware exit confirmed: \(try await controlRequest(0xe4, [], timeout: 8).payload == [0])") }
                catch { log?("Could not confirm firmware exit: \(error.localizedDescription)") }
            }
            lastError = error.localizedDescription
            log?("Firmware operation ended: \(error.localizedDescription)")
            throw error
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
        guard connected, !connecting, noise != nil, !changing, !updatingFirmware else { return }
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
