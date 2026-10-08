import Foundation
import CoreBluetooth
import Combine
import OSLog

/// Xiaomi MMA over the AF07/AF08 GATT channel, verified on REDMI Buds 8 Pro.
/// Audio pairing remains managed by iOS.
@MainActor
final class BLEBuds: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = BLEBuds()
    @Published private(set) var status = "Connect your buds" {
        didSet { if status != oldValue { BudsDiagnostics.record("status", ["value": status]) } }
    }
    @Published private(set) var connected = false
    @Published private(set) var changing = false
    @Published private(set) var refreshingManually = false
    @Published private(set) var updatingFirmware = false
    @Published private(set) var noise: NoiseSetting?
    @Published private(set) var left: Battery?
    @Published private(set) var right: Battery?
    @Published private(set) var caseBattery: Battery?
    @Published private(set) var firmware = ""
    @Published private(set) var peerFirmware: String?
    @Published private(set) var error: String? {
        didSet { if error != oldValue { BudsDiagnostics.record("error", ["value": error ?? "cleared"]) } }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var reader: CBCharacteristic?
    private var decoder = PacketDecoder()
    private var sequence: UInt8 = 0
    private var ancStrength: UInt8 = 19
    private var transparencyStrength: UInt8 = 0
    private var refreshing = false
    private var quietConnection = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var openingControls = false
    private var initializing = false
    private var connectionGeneration = 0
    private var pending: (opcode: UInt8, sequence: UInt8, continuation: CheckedContinuation<Packet, Error>)?
    private var commandTimeout: Timer?
    private var connectionTimeout: Timer?
    private var scanTimeout: Timer?
    private var idleTimeout: Timer?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var acknowledgments: [Data] = []
    private var queuedCommand: (data: Data, opcode: UInt8, sequence: UInt8, offset: Int)?
    private var failedPeripherals: Set<UUID> = []
    private var unverifiedRestored: [CBPeripheral] = []
    private let logger = Logger(subsystem: "build.robin.RedmiBuds", category: "Bluetooth")
    private let preferences = UserDefaults(suiteName: "group.build.robin.RedmiBuds") ?? .standard
    private let controlCacheKey = "budsAuthenticatedPeripheral"
    private var releasingIdleConnection = false
    private var ownsConnection = false
    var canControl: Bool { connected || preferences.string(forKey: controlCacheKey) != nil }

    override init() {
        super.init()
        if Bundle.main.bundleIdentifier == "build.robin.RedmiBuds" {
            preferences.removeObject(forKey: "budsUpdatingFirmware")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct CommandTimeout: LocalizedError {
        var errorDescription: String? { "The buds did not answer. Reconnect and try again." }
    }

    private func connectionStatus(_ value: String) {
        if quietConnection { BudsDiagnostics.record("connectionStatus", ["value": value]) }
        else { status = value }
    }

    func connect(quietly: Bool = false) async throws {
        quietConnection = quietly
        if preferences.bool(forKey: "budsUpdatingFirmware"), !updatingFirmware {
            throw Failure(message: "A firmware update is in progress. Open Redmi Buds to check it.")
        }
        idleTimeout?.invalidate(); idleTimeout = nil
        // Preserve the authenticated identity when moving its cache into the App Group.
        if preferences.string(forKey: controlCacheKey) == nil,
           let verified = UserDefaults.standard.string(forKey: controlCacheKey) {
            preferences.set(verified, forKey: controlCacheKey)
            BudsDiagnostics.record("cacheMigrated")
        }
        BudsDiagnostics.record("connect", ["connected": String(connected), "saved": preferences.string(forKey: controlCacheKey) ?? "none", "peripheralState": peripheral.map { String($0.state.rawValue) } ?? "none"])
        if connected { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if waiters.isEmpty { failedPeripherals.removeAll() }
            waiters.append(continuation)
            if central == nil {
                central = CBCentralManager(delegate: self, queue: .main, options: [
                    CBCentralManagerOptionRestoreIdentifierKey: "build.robin.RedmiBuds.bluetooth"
                ])
            } else if central?.state == .poweredOn {
                findBuds()
            } else if central?.state == .unauthorized {
                finishConnection(.failure(Failure(message: "Allow Bluetooth for Redmi Buds in Settings.")))
                return
            }
            if connectionTimeout == nil {
                connectionTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        let device = self.peripheral
                        let verified = device.map { self.preferences.string(forKey: self.controlCacheKey) == $0.identifier.uuidString } ?? false
                        BudsDiagnostics.record("connectionTimeout", ["verified": String(verified), "peripheral": device?.identifier.uuidString ?? "none"])
                        // A verified identity stays valid while the buds sleep. Let CoreBluetooth
                        // finish its pending reconnect even after this caller stops waiting.
                        if !verified { self.peripheral = nil }
                        self.central?.stopScan()
                        self.scanTimeout?.invalidate(); self.scanTimeout = nil
                        if let device, !verified { self.central?.cancelPeripheralConnection(device) }
                        self.disconnected(verified ? "Waiting for your buds’ control connection. Try Reconnect when the buds are awake." : "Could not open the buds’ controls. Check that REDMI Buds 8 Pro is connected in iPhone Bluetooth settings, then tap Reconnect.")
                    }
                }
            }
        }
    }

    private func findBuds() {
        guard let central, central.state == .poweredOn, !connected else { return }
        BudsDiagnostics.record("discoveryStarted")
        connectionStatus("Looking for your buds…")
        error = nil
        if let peripheral {
            if peripheral.state == .connected, ownsConnection { discover(peripheral) }
            else if peripheral.state == .disconnected || peripheral.state == .connected { central.connect(peripheral) }
        } else if let saved = preferences.string(forKey: controlCacheKey), let id = UUID(uuidString: saved),
                  !failedPeripherals.contains(id), let savedBuds = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(savedBuds)
        }
        central.scanForPeripherals(withServices: nil)
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.central?.stopScan() }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BudsDiagnostics.record("bluetoothState", ["state": String(central.state.rawValue), "authorization": String(CBCentralManager.authorization.rawValue), "os": ProcessInfo.processInfo.operatingSystemVersionString])
        switch central.state {
        case .poweredOn:
            failedPeripherals.removeAll()
            unverifiedRestored.forEach { central.cancelPeripheralConnection($0) }
            unverifiedRestored.removeAll()
            findBuds()
        case .unauthorized: finishConnection(.failure(Failure(message: "Allow Bluetooth for Redmi Buds in Settings.")))
        case .poweredOff: disconnected("Turn on Bluetooth in Settings.")
        case .unsupported: disconnected("Bluetooth is unavailable on this device.")
        default: status = "Waiting for Bluetooth…"
        }
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let devices = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        BudsDiagnostics.record("restored", ["peripherals": devices.map { $0.identifier.uuidString + ":" + String($0.state.rawValue) }.joined(separator: ",")])
        let verified = preferences.string(forKey: controlCacheKey)
        unverifiedRestored = devices.filter { $0.identifier.uuidString != verified }
        if let restored = devices.first(where: { $0.identifier.uuidString == verified }) {
            peripheral = restored
            restored.delegate = self
            ownsConnection = restored.state == .connected
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        // This model's private MMA endpoint remains available outside LE Audio pairing mode.
        // Authentication and VID/PID reads verify it before any noise setting is written.
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        guard !connected, !failedPeripherals.contains(device.identifier),
              manufacturer?.starts(with: [0x8f, 0x03, 0x16, 0x01, 0x37, 0xa0]) == true else { return }
        BudsDiagnostics.record("candidate", ["peripheral": device.identifier.uuidString, "rssi": rssi.stringValue, "services": services.map(\.uuidString).joined(separator: ",")])
        // Both buds advertise the same name. Finish one attempt before choosing another.
        if let peripheral, peripheral.identifier != device.identifier { return }
        if peripheral?.identifier != device.identifier || device.state == .disconnected { attach(device) }
    }
    private func attach(_ device: CBPeripheral) {
        BudsDiagnostics.record("attach", ["peripheral": device.identifier.uuidString, "state": String(device.state.rawValue)])
        logger.debug("Connecting peripheral \(device.identifier.uuidString, privacy: .private), state \(device.state.rawValue)")
        peripheral = device
        device.delegate = self
        ownsConnection = false
        // A system-connected peripheral may belong to another app/central manager.
        // Establish this manager's local connection before using its characteristics.
        central?.connect(device)
    }
    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        BudsDiagnostics.record("didConnect", ["peripheral": device.identifier.uuidString, "selected": String(device == peripheral)])
        guard device == peripheral else { return }
        ownsConnection = true
        discover(device)
    }
    private func discover(_ device: CBPeripheral) {
        guard !openingControls else { return }
        openingControls = true
        BudsDiagnostics.record("servicesRequested", ["peripheral": device.identifier.uuidString])
        connectionStatus("Connecting controls…")
        device.discoverServices([CBUUID(string: "AF00")])
    }
    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        BudsDiagnostics.record("services", ["peripheral": device.identifier.uuidString, "services": device.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "none", "error": error?.localizedDescription ?? "none"])
        guard device == peripheral else { return }
        guard error == nil, let service = device.services?.first(where: { $0.uuid == CBUUID(string: "AF00") }) else {
            reject(device, "Could not find noise controls. Reconnect your buds."); return
        }
        device.discoverCharacteristics([CBUUID(string: "AF07"), CBUUID(string: "AF08")], for: service)
    }
    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        BudsDiagnostics.record("characteristics", ["peripheral": device.identifier.uuidString, "values": service.characteristics?.map { $0.uuid.uuidString + ":" + String($0.properties.rawValue) }.joined(separator: ",") ?? "none", "error": error?.localizedDescription ?? "none"])
        guard device == peripheral else { return }
        writer = service.characteristics?.first { $0.uuid == CBUUID(string: "AF07") }
        reader = service.characteristics?.first { $0.uuid == CBUUID(string: "AF08") }
        guard error == nil, let writer, writer.properties.contains(.writeWithoutResponse),
              let reader, reader.properties.contains(.notify) else {
            reject(device, "This pair does not expose the supported noise controls."); return
        }
        device.setNotifyValue(true, for: reader)
    }
    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        BudsDiagnostics.record("notificationState", ["peripheral": device.identifier.uuidString, "characteristic": characteristic.uuid.uuidString, "enabled": String(characteristic.isNotifying), "error": error?.localizedDescription ?? "none"])
        guard device == peripheral, characteristic == reader else { return }
        guard error == nil, characteristic.isNotifying else {
            reject(device, "Could not open noise controls. Reconnect your buds."); return
        }
        guard !initializing else { return }
        initializing = true
        let generation = connectionGeneration
        Task {
            do {
                connectionStatus("Authenticating controls…")
                var challenge = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
                let reply: Packet
                do { reply = try await request(0x50, [1] + challenge) }
                catch is CommandTimeout {
                    // A second host may be finishing a control transaction. Retry only
                    // the read-only challenge, with a new nonce, after it can release.
                    BudsDiagnostics.record("authenticationRetry")
                    try await Task.sleep(for: .milliseconds(2500))
                    challenge = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
                    reply = try await request(0x50, [1] + challenge)
                }
                guard let expected = MMAAuthentication.response(to: challenge), reply.payload == [1] + expected else {
                    throw Failure(message: "The buds’ authentication response did not match.")
                }
                let confirmation = try await request(0x51, [1, 0])
                guard confirmation.payload == [1] else { throw Failure(message: "The buds did not confirm authentication.") }
                BudsDiagnostics.record("authenticated")
                try await readDeviceInfo()
                _ = try await readNoise()
                guard generation == connectionGeneration else { return }
                connected = true
                preferences.set(device.identifier.uuidString, forKey: controlCacheKey)
                central?.stopScan()
                scanTimeout?.invalidate(); scanTimeout = nil
                openingControls = false; initializing = false
                connectionStatus("Connected")
                BudsDiagnostics.record("ready", ["peripheral": device.identifier.uuidString])
                self.error = nil
                finishConnection(.success(()))
                releaseWhenIdle()
            } catch { if generation == connectionGeneration { reject(device, error.localizedDescription) } }
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        BudsDiagnostics.record("connectionFailed", ["peripheral": device.identifier.uuidString, "domain": (error as NSError?)?.domain ?? "none", "code": (error as NSError?).map { String($0.code) } ?? "none", "error": error?.localizedDescription ?? "none"])
        guard device == peripheral else { return }
        logger.error("Connection failed: \(error?.localizedDescription ?? "Unknown Bluetooth error", privacy: .public)")
        if let failure = error as? CBError, failure.code == .peerRemovedPairingInformation {
            peripheral = nil
            central.stopScan()
            scanTimeout?.invalidate(); scanTimeout = nil
            disconnected("In iPhone Settings → Bluetooth, forget the disconnected Redmi entry. Audio and controls can have separate entries. Then reconnect here and tap Pair if prompted.")
            status = "Control pairing needs refreshing"
            return
        }
        reject(device, "Could not connect. Open the buds’ case and try again.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        BudsDiagnostics.record("didDisconnect", ["peripheral": device.identifier.uuidString, "selected": String(device == peripheral), "error": error?.localizedDescription ?? "none"])
        guard device == peripheral else { return }
        if releasingIdleConnection {
            releasingIdleConnection = false
            ownsConnection = false
            connectionGeneration += 1
            connected = false
            openingControls = false; initializing = false
            writer = nil; reader = nil
            decoder = PacketDecoder()
            acknowledgments.removeAll()
            queuedCommand = nil
            connectionStatus("Ready")
            quietConnection = false
            BudsDiagnostics.record("idleReleased")
            if !waiters.isEmpty { findBuds() }
            return
        }
        disconnected("Buds disconnected")
        // CoreBluetooth waits for a new advertisement without polling or changing the audio route.
        if central.state == .poweredOn { central.connect(device) }
    }
    private func reject(_ device: CBPeripheral, _ message: String) {
        BudsDiagnostics.record("rejected", ["peripheral": device.identifier.uuidString, "reason": message])
        failedPeripherals.insert(device.identifier)
        peripheral = nil
        central?.cancelPeripheralConnection(device)
        disconnected(message, finishAttempt: false)
        // Continue discovery for the other advertised identity, without cancelling it mid-connect.
        if central?.state == .poweredOn { findBuds() }
    }
    private func disconnected(_ message: String, finishAttempt: Bool = true) {
        quietConnection = false
        idleTimeout?.invalidate(); idleTimeout = nil
        releasingIdleConnection = false
        ownsConnection = false
        connectionGeneration += 1
        openingControls = false; initializing = false
        connected = false
        noise = nil
        left = nil; right = nil; caseBattery = nil
        NoiseControlState.save(nil)
        writer = nil; reader = nil
        decoder = PacketDecoder()
        acknowledgments.removeAll()
        failPending(Failure(message: message))
        status = message
        error = message
        if finishAttempt { finishConnection(.failure(Failure(message: message))) }
    }
    private func finishConnection(_ result: Result<Void, Error>) {
        connectionTimeout?.invalidate(); connectionTimeout = nil
        let current = waiters; waiters.removeAll()
        if case .failure(let failure) = result { error = failure.localizedDescription; status = failure.localizedDescription }
        current.forEach { $0.resume(with: result) }
    }

    private func request(_ opcode: UInt8, _ payload: [UInt8], timeout: TimeInterval = 4) async throws -> Packet {
        guard payload.count < 65535 else { throw Failure(message: "The command is too large.") }
        guard pending == nil, let peripheral, peripheral.state == .connected, writer != nil else {
            throw Failure(message: "Controls are busy or disconnected. Try again.")
        }
        sequence &+= 1
        var bytes = Packet.encode(opcode: opcode, sequence: sequence, payload: payload)
        bytes[3] = 0xc0
        BudsDiagnostics.record("commandQueued", ["peripheral": peripheral.identifier.uuidString, "opcode": String(format: "%02X", opcode), "sequence": String(sequence), "payloadBytes": String(payload.count)])
        return try await withCheckedThrowingContinuation { continuation in
            pending = (opcode, sequence, continuation)
            let commandSequence = sequence
            commandTimeout = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.pending?.sequence == commandSequence else { return }
                    BudsDiagnostics.record("commandTimeout", ["opcode": String(format: "%02X", opcode), "sequence": String(commandSequence)])
                    self.failPending(CommandTimeout())
                }
            }
            queuedCommand = (Data(bytes), opcode, sequence, 0)
            drainAcknowledgments()
        }
    }
    private func failPending(_ failure: Error) {
        queuedCommand = nil
        commandTimeout?.invalidate(); commandTimeout = nil
        let command = pending; pending = nil
        command?.continuation.resume(throwing: failure)
    }
    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { BudsDiagnostics.record("notificationError", ["peripheral": device.identifier.uuidString, "error": error.localizedDescription]) }
        guard device == peripheral, characteristic == reader, error == nil, let value = characteristic.value else { return }
        for packet in decoder.feed(Array(value)) {
            BudsDiagnostics.record("packetReceived", ["peripheral": device.identifier.uuidString, "type": String(format: "%02X", packet.type), "opcode": String(format: "%02X", packet.opcode), "sequence": String(packet.sequence), "status": packet.status.map { String($0) } ?? "request", "payloadBytes": String(packet.payload.count)])
            if packet.isRequest {
                if packet.needsReply {
                    let payload: [UInt8]
                    if packet.opcode == 0x50, packet.payload.count == 17,
                       let result = MMAAuthentication.response(to: Array(packet.payload.dropFirst())) {
                        payload = [1] + result
                    } else if packet.opcode == 0x51, packet.payload == [1, 0] {
                        payload = [1]
                    } else { payload = [] }
                    var reply = Packet.encode(opcode: packet.opcode, sequence: packet.sequence, payload: payload, response: true)
                    reply[3] = 0x00
                    acknowledgments.append(Data(reply))
                    drainAcknowledgments()
                }
                if [0xf4, 0x0e].contains(packet.opcode), connected, !changing, !refreshing, !updatingFirmware, pending == nil {
                    Task { await refresh(silently: true) }
                }
            } else if let pending, packet.sequence == pending.sequence, packet.opcode == pending.opcode {
                self.pending = nil
                commandTimeout?.invalidate(); commandTimeout = nil
                if packet.status == 0 { pending.continuation.resume(returning: packet) }
                else { pending.continuation.resume(throwing: Failure(message: "The buds rejected this command (\(packet.status ?? 255)).")) }
            }
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { drainAcknowledgments() }
    private func drainAcknowledgments() {
        guard let peripheral, let writer else { return }
        // Never insert a peer acknowledgment in the middle of a fragmented MMA frame.
        if queuedCommand == nil || queuedCommand?.offset == 0 {
            while peripheral.canSendWriteWithoutResponse, !acknowledgments.isEmpty {
                peripheral.writeValue(acknowledgments.removeFirst(), for: writer, type: .withoutResponse)
            }
        }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard maximum > 0 else { return }
        while peripheral.canSendWriteWithoutResponse, var command = queuedCommand {
            let end = min(command.offset + maximum, command.data.count)
            peripheral.writeValue(command.data.subdata(in: command.offset..<end), for: writer, type: .withoutResponse)
            command.offset = end
            if end == command.data.count {
                queuedCommand = nil
                BudsDiagnostics.record("commandSent", ["peripheral": peripheral.identifier.uuidString, "opcode": String(format: "%02X", command.opcode), "sequence": String(command.sequence), "frameBytes": String(command.data.count), "maximumWrite": String(maximum)])
            } else { queuedCommand = command }
        }
        if queuedCommand == nil {
            while peripheral.canSendWriteWithoutResponse, !acknowledgments.isEmpty {
                peripheral.writeValue(acknowledgments.removeFirst(), for: writer, type: .withoutResponse)
            }
        }
    }
    private func readDeviceInfo() async throws {
        let reply = try await request(0x02, [0xff, 0xff, 0xff, 0xff])
        let fields = parseTLVs(reply.payload, idWidth: 1)
        guard let product = fields.first(where: { $0.id == 3 })?.value, product.count == 4,
              UInt16(product[0]) << 8 | UInt16(product[1]) == 0x2717,
              UInt16(product[2]) << 8 | UInt16(product[3]) == 0x50e3 else {
            throw Failure(message: "This firmware or model is not supported yet.")
        }
        peerFirmware = nil
        for field in fields {
            if field.id == 7, field.value.count == 3 {
                left = Battery(field.value[0]); right = Battery(field.value[1]); caseBattery = Battery(field.value[2])
            }
            if field.id == 1, field.value.count >= 2 {
                let a = field.value[0], b = field.value[1]
                firmware = "\(a >> 4).\(a & 15).\(b >> 4).\(b & 15)"
                peerFirmware = field.value.count >= 4 ? MMAFirmwareImage.versionName(UInt16(field.value[2]) << 8 | UInt16(field.value[3])) : nil
            }
        }
        BudsDiagnostics.record("deviceInfo", ["firmware": firmware, "peerFirmware": peerFirmware ?? "unavailable", "left": left.map { String($0.percent) } ?? "unavailable", "right": right.map { String($0.percent) } ?? "unavailable", "case": caseBattery.map { String($0.percent) } ?? "unavailable", "leftCharging": left.map { String($0.charging) } ?? "unavailable", "rightCharging": right.map { String($0.charging) } ?? "unavailable"])
    }
    @discardableResult
    private func readNoise() async throws -> NoiseSetting {
        let reply = try await request(0xf3, [0, 0x0b])
        guard let actual = parseNoise(reply.payload), actual.mode == .off || actual.mode.strengthRange?.contains(actual.strength) == true else {
            throw Failure(message: "Could not read the current noise mode.")
        }
        noise = actual
        BudsDiagnostics.record("noiseReadback", ["mode": actual.mode.title, "strength": String(actual.strength)])
        NoiseControlState.save(actual.mode)
        if actual.mode == .anc { ancStrength = actual.strength }
        if actual.mode == .transparency { transparencyStrength = actual.strength }
        return actual
    }

    private func beginFirmwareOperation() async throws {
        guard !updatingFirmware else { throw Failure(message: "A firmware operation is already in progress.") }
        try await connect()
        if refreshing { await withCheckedContinuation { refreshWaiters.append($0) } }
        guard !updatingFirmware, !changing, pending == nil else { throw Failure(message: "Wait for the current command to finish.") }
        updatingFirmware = true
        preferences.set(true, forKey: "budsUpdatingFirmware")
        idleTimeout?.invalidate(); idleTimeout = nil
    }
    private func finishFirmwareOperation() {
        updatingFirmware = false
        preferences.removeObject(forKey: "budsUpdatingFirmware")
        releaseWhenIdle()
    }
    private func firmwareEligibility(_ image: MMAFirmwareImage) async throws {
        try await readDeviceInfo()
        guard let current = MMAFirmwareImage.versionCode(firmware), current >> 12 == image.version >> 12,
              current <= image.version,
              let peer = peerFirmware.flatMap(MMAFirmwareImage.versionCode), peer >> 12 == image.version >> 12, peer <= image.version else {
            throw FirmwareFailure("The firmware does not match both earbuds' hardware and software versions.")
        }
        let offset = try await request(0xe1, []).payload
        guard offset.count == 6, MMAFirmwareImage.number(offset[0..<4]) == 0,
              MMAFirmwareImage.number(offset[4..<6]) == 14 else {
            throw FirmwareFailure("This model's firmware identification layout is not supported.")
        }
        let eligibility = try await request(0xe2, image.identification).payload
        guard eligibility.count == 1 else { throw FirmwareFailure("The earbuds returned an invalid update-readiness response.") }
        BudsDiagnostics.record("firmwareEligibility", ["result": String(eligibility[0]), "version": image.versionName])
        if let problem = FirmwareFailure.eligibility(eligibility[0]) { throw FirmwareFailure(problem) }
    }
    /// Compatibility/readiness queries only; never enters update mode or writes firmware.
    func checkFirmwareReadiness(_ image: MMAFirmwareImage) async throws {
        try await beginFirmwareOperation()
        defer { finishFirmwareOperation() }
        try await firmwareEligibility(image)
    }
    /// Called only by the app's explicit Update action, after official download validation.
    func installFirmware(_ image: MMAFirmwareImage, progress: (Double, String) -> Void) async throws {
        try await beginFirmwareOperation()
        defer { finishFirmwareOperation() }
        var entered = false
        do {
            try await firmwareEligibility(image)
            try Task.checkCancellation()
            progress(0, "Preparing the earbuds…")
            entered = true
            let start = try await request(0xe3, [], timeout: 30)
            var block = try MMAUpdateBlock(response: start.payload, entering: true)
            let withCRC = block.requiresCRC
            var previousOffset = -1
            while !block.finished {
                try Task.checkCancellation()
                guard block.offset > previousOffset else { throw FirmwareFailure("The firmware transfer stopped making progress.") }
                let payload = try image.block(offset: block.offset, length: block.length, withCRC: withCRC)
                if block.delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(block.delayMilliseconds)) }
                progress(Double(block.offset) / Double(image.bytes.count), "Updating. Keep both earbuds in the open case.")
                BudsDiagnostics.record("firmwareBlock", ["offset": String(block.offset), "length": String(block.length)])
                previousOffset = block.offset
                block = try MMAUpdateBlock(response: try await request(0xe5, payload, timeout: 12).payload, entering: false)
            }
            try Task.checkCancellation()
            if block.delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(block.delayMilliseconds)) }
            progress(1, "Verifying the firmware…")
            let verification = try await request(0xe6, [], timeout: 30).payload
            guard verification == [0] else { throw FirmwareFailure("The earbuds did not verify the firmware (\(verification.first.map(String.init) ?? "missing response")).") }
            entered = false
            BudsDiagnostics.record("firmwareVerified", ["version": image.versionName])
            progress(1, "Restarting and checking both earbuds…")
            // Some firmware disconnects before its reboot acknowledgment. Version readback,
            // rather than that acknowledgment, is the final success criterion.
            do { _ = try await request(0x03, [0], timeout: 5) }
            catch { BudsDiagnostics.record("firmwareRebootReply", ["error": error.localizedDescription]) }
            // The first verified update took ~80 seconds to restart both buds.
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            var attempt = 0
            while ContinuousClock.now < deadline {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt == 1 ? 2 : 5))
                do {
                    try await connect()
                    try await readDeviceInfo()
                    if firmware == image.versionName, peerFirmware == image.versionName {
                        BudsDiagnostics.record("firmwareUpdateSucceeded", ["version": image.versionName])
                        error = nil
                        status = "Connected"
                        return
                    }
                } catch { BudsDiagnostics.record("firmwareVersionCheck", ["attempt": String(attempt), "error": error.localizedDescription]) }
            }
            throw FirmwareFailure("Firmware transfer was verified, but both earbuds' new versions could not be confirmed. Reopen the case, reconnect and check the firmware versions before trying another update.")
        } catch {
            BudsDiagnostics.record("firmwareUpdateFailed", ["enteredUpdateMode": String(entered), "error": error.localizedDescription])
            if entered, connected, pending == nil {
                do {
                    let cancellation = try await request(0xe4, [], timeout: 8)
                    BudsDiagnostics.record("firmwareExit", ["confirmed": String(cancellation.payload == [0])])
                } catch { BudsDiagnostics.record("firmwareExitFailed", ["error": error.localizedDescription]) }
            }
            self.error = error.localizedDescription
            throw error
        }
    }
    func refresh(silently: Bool = false) async {
        if refreshing {
            if !silently {
                refreshingManually = true
                await withCheckedContinuation { refreshWaiters.append($0) }
            }
            return
        }
        guard !changing, !updatingFirmware, pending == nil else { return }
        refreshing = true
        refreshingManually = !silently
        defer {
            refreshing = false
            refreshingManually = false
            let waiting = refreshWaiters; refreshWaiters.removeAll()
            waiting.forEach { $0.resume() }
            releaseWhenIdle()
        }
        do {
            let needsConnection = !connected
            try await connect(quietly: silently && noise != nil && error == nil)
            try Task.checkCancellation()
            // A new connection already reads device information and noise state.
            if !needsConnection { try await readDeviceInfo(); _ = try await readNoise() }
            error = nil
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func setMode(_ mode: NoiseMode, strength: UInt8? = nil) async throws {
        try await changeMode(mode, strength: strength)
    }
    func cycleMode() async throws {
        try await changeMode(nil)
    }
    // A cycle reads the current device state inside the same serialized change as the write.
    private func changeMode(_ selectedMode: NoiseMode?, strength: UInt8? = nil) async throws {
        guard !updatingFirmware else { throw Failure(message: "Wait for the firmware update to finish before changing noise mode.") }
        BudsDiagnostics.record("modeRequested", ["mode": selectedMode?.title ?? "cycle", "strength": strength.map { String($0) } ?? "remembered"])
        try await connect()
        if refreshing { await withCheckedContinuation { refreshWaiters.append($0) } }
        guard !changing, !updatingFirmware, pending == nil else { throw Failure(message: "A change is already in progress. Try again.") }
        changing = true; error = nil
        defer { changing = false; releaseWhenIdle() }
        do {
            let mode: NoiseMode
            if let selectedMode { mode = selectedMode }
            else {
                switch try await readNoise().mode {
                case .anc: mode = .transparency
                case .transparency: mode = .off
                case .off: mode = .anc
                }
            }
            if let strength, let range = mode.strengthRange, !range.contains(strength) { throw Failure(message: "Unsupported strength.") }
            if mode == .anc, strength != nil {
                let smart = try await request(0xf3, [0, 0x25])
                guard let value = parseTLVs(smart.payload, idWidth: 2).first(where: { $0.id == 0x25 })?.value,
                      value == [0] || value == [1] else { throw Failure(message: "Could not read smart noise cancelling.") }
                if value == [1] {
                    _ = try await request(0xf2, [3, 0, 0x25, 0])
                    let check = try await request(0xf3, [0, 0x25])
                    guard parseTLVs(check.payload, idWidth: 2).first(where: { $0.id == 0x25 })?.value == [0] else {
                        throw Failure(message: "The buds did not confirm manual noise cancelling.")
                    }
                }
            }
            let requested = NoiseSetting(mode: mode, strength: mode == .off ? 0 : strength ?? (mode == .anc ? ancStrength : transparencyStrength))
            _ = try await request(0xf2, [4, 0, 0x0b, requested.mode.rawValue, requested.strength])
            let actual = try await readNoise()
            guard actual == requested else { throw Failure(message: "The buds did not confirm the requested setting.") }
            status = "Connected"
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
    private func releaseWhenIdle() {
        guard connected, !changing, !refreshing, !updatingFirmware, pending == nil else { return }
        idleTimeout?.invalidate()
        idleTimeout = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connected, !self.changing, !self.refreshing, !self.updatingFirmware, self.pending == nil,
                      let device = self.peripheral else { return }
                self.releasingIdleConnection = true
                self.connected = false
                self.central?.cancelPeripheralConnection(device)
                BudsDiagnostics.record("idleReleaseRequested")
            }
        }
    }
}
