import Foundation
import CoreBluetooth

/// Minimal async wrapper over CoreBluetooth.
///
/// Runs entirely on the main queue — CoreBluetooth is happy with that and it keeps
/// the whole app free of cross-thread concerns. This is a small app talking to one
/// device; there is nothing here worth a background queue.
@MainActor
@Observable
final class BLEClient: NSObject {

    enum State: Equatable {
        case idle
        case unauthorised
        case poweredOff
        case scanning
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var deviceName: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Pary serwis + charakterystyka. NIE slownik po UUID: to urzadzenie wystawia
    /// te same UUID-y charakterystyk w kilku serwisach (np. 2A26 w 180A i w FE2C),
    /// wiec slownik po samym UUID gubi instancje i potrafi zwrocic nie te wartosc.
    private var entries: [(service: CBUUID, ch: CBCharacteristic)] = []

    private var seen: [UUID: CBPeripheral] = [:]

    // Continuations for the async wrappers. Each is resumed exactly once.
    private var powerOnWaiters: [CheckedContinuation<CBManagerState, Never>] = []
    private var connectWaiter: CheckedContinuation<Bool, Never>?
    private var discoveryWaiter: CheckedContinuation<Void, Never>?
    private var pendingServices: Set<CBUUID> = []

    /// Wolane dla kazdej notyfikacji, na ktora nikt nie czekal jako na odczyt.
    var onNotification: ((CBUUID, Data) -> Void)?

    private var readContinuations: [ObjectIdentifier: CheckedContinuation<Data?, Error>] = [:]
    private var notifyContinuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var writeContinuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    /// Raw value of every characteristic we have read, keyed "SERVICE/CHARACTERISTIC".
    private(set) var rawValues: [String: Data] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Waiting for the radio

    /// CoreBluetooth reports `.unknown` until it has finished starting up, which
    /// takes a moment after launch. Connecting before that always failed and looked
    /// to the user like "Bluetooth is off" — hence this wait.
    private func waitForPowerOn(timeout: Double = 5) async -> CBManagerState {
        if central.state != .unknown && central.state != .resetting { return central.state }

        return await withTaskGroup(of: CBManagerState?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { c in self.powerOnWaiters.append(c) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? self.central.state
        }
    }

    // MARK: - Connecting

    /// Finds the headphones and connects.
    ///
    /// Identification is by content, not by name: Major V uses BLE private addresses
    /// and usually advertises without a local name, so the name is only known after
    /// connecting. A candidate counts as ours only if it exposes the Zound service —
    /// otherwise we would happily attach to any nearby accessory that reports a
    /// battery level and then show its numbers.
    func connect() async {
        let radio = await waitForPowerOn()
        guard radio == .poweredOn else {
            state = radio == .unauthorized ? .unauthorised : .poweredOff
            return
        }
        state = .scanning

        // Devices already connected to iOS do not advertise, so ask for them directly.
        var candidates = central.retrieveConnectedPeripherals(withServices: [
            MajorV.zoundService, MajorV.batteryService, MajorV.deviceInfoService,
        ])
        // Try the plausibly-named ones first; the rest are still worth probing.
        candidates.sort { ($0.name ?? "").localizedCaseInsensitiveContains("major")
                       && !($1.name ?? "").localizedCaseInsensitiveContains("major") }

        if await attachBest(from: candidates) { return }

        // Nothing connected matched — scan the air.
        seen.removeAll()
        central.scanForPeripherals(withServices: nil, options: nil)
        try? await Task.sleep(for: .seconds(6))
        central.stopScan()

        let scanned = seen.values.sorted {
            ($0.name ?? "").localizedCaseInsensitiveContains("major")
            && !($1.name ?? "").localizedCaseInsensitiveContains("major")
        }
        if await attachBest(from: scanned) { return }

        state = .failed("""
        Major V not found. Switch the headphones on and pair them with this iPhone \
        in Settings › Bluetooth — without pairing the headphones refuse every read.
        """)
    }

    /// Major V pokazuje sie w iOS dwa razy - jako "MAJOR V" (klasyczne) i
    /// "MAJOR V [LE]". Trafienie na wpis bez kanalu Airohy oznacza brak baterii
    /// i sondy, wiec przechodzimy calą listę i wybieramy ten z kompletem serwisow.
    /// Wpis z samym Zoundem bierzemy dopiero, gdy nie ma nic lepszego.
    private func attachBest(from list: [CBPeripheral]) async -> Bool {
        var fallback: CBPeripheral?
        for p in list {
            guard await attach(p) else { continue }
            if hasAirohaChannel { return true }
            fallback = p
            central.cancelPeripheralConnection(p)
            entries.removeAll()
        }
        guard let fallback else { return false }
        return await attach(fallback)
    }

    /// Czy podlaczony peryferal wystawia kanal RACE Airohy.
    var hasAirohaChannel: Bool {
        entries.contains { $0.ch.uuid == Race.notifyCharacteristic }
    }

    /// Connects, discovers everything, and keeps the peripheral only if it really
    /// is a Major V. Returns false (and disconnects) otherwise.
    private func attach(_ p: CBPeripheral) async -> Bool {
        state = .connecting
        entries.removeAll()
        peripheral = p
        p.delegate = self

        let connected = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { c in
                    self.connectWaiter = c
                    self.central.connect(p, options: nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
                return false
            }
            let r = await group.next() ?? false
            group.cancelAll()
            return r
        }
        guard connected else { central.cancelPeripheralConnection(p); return false }

        await discoverEverything(on: p)

        // The Zound service is what makes this our device.
        guard entries.contains(where: {
            $0.ch.uuid.uuidString.uppercased().hasSuffix("1337-1DEA-FEED-C0FFEE70C0DE")
        }) else {
            central.cancelPeripheralConnection(p)
            entries.removeAll()
            return false
        }

        deviceName = p.name
        state = .connected
        return true
    }

    /// Waits until **every** discovered service has reported its characteristics.
    ///
    /// The previous version returned as soon as the first service came back, so the
    /// initial reads ran against a half-built table and quietly returned nothing.
    private func discoverEverything(on p: CBPeripheral) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.discoveryWaiter = c
                    // Bez filtra: iOS buforuje baze GATT sparowanego urzadzenia
                    // i filtrowane odkrywanie potrafi pominac serwis, ktorego
                    // akurat nie ma w cache - tak gubil sie kanal Airohy.
                    p.discoverServices(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
            }
            await group.next()
            group.cancelAll()
        }
        discoveryWaiter = nil
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        entries.removeAll()
        rawValues.removeAll()
        state = .idle
    }

    /// Wszystkie wykryte pary serwis + charakterystyka, do ekranu diagnostycznego.
    var allEntries: [(service: CBUUID, characteristic: CBUUID, properties: CBCharacteristicProperties)] {
        entries.map { ($0.service, $0.ch.uuid, $0.ch.properties) }
    }

    nonisolated static func key(_ service: CBUUID, _ characteristic: CBUUID) -> String {
        "\(service.uuidString.uppercased())/\(characteristic.uuidString.uppercased())"
    }

    // MARK: - Reading and writing

    var discoveredCharacteristics: [CBUUID] { entries.map(\.ch.uuid) }

    /// Znajduje charakterystyke. `service` zawezá wyszukiwanie do konkretnego
    /// serwisu - podawaj go wszedzie tam, gdzie UUID moze sie powtarzac.
    private func find(_ uuid: CBUUID, in service: CBUUID?) -> (CBUUID, CBCharacteristic)? {
        if let service,
           let e = entries.first(where: { $0.service == service && $0.ch.uuid == uuid }) {
            return (e.service, e.ch)
        }
        if let e = entries.first(where: { $0.ch.uuid == uuid }) { return (e.service, e.ch) }
        return nil
    }

    func read(_ uuid: CBUUID, in service: CBUUID? = nil) async -> Data? {
        guard let (svc, ch) = find(uuid, in: service), let p = peripheral,
              ch.properties.contains(.read) else { return nil }
        let value = try? await withCheckedThrowingContinuation { c in
            readContinuations[ObjectIdentifier(ch)] = c
            p.readValue(for: ch)
        }
        if let value { rawValues[Self.key(svc, uuid)] = value }
        return value
    }

    func write(_ data: Data, to uuid: CBUUID, in service: CBUUID? = nil) async throws {
        guard let (_, ch) = find(uuid, in: service), let p = peripheral else {
            throw BLEFailure.notConnected
        }
        guard ch.properties.contains(.write) else {
            p.writeValue(data, for: ch, type: .withoutResponse)
            return
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeContinuations[ObjectIdentifier(ch)] = c
            p.writeValue(data, for: ch, type: .withResponse)
        }
    }

    /// Wlacza notyfikacje. Charakterystyki Zounda to odrzucaja (firmware zwraca
    /// ATT 0x0D), ale kanal Airohy subskrybuje sie bez problemu.
    func subscribe(_ uuid: CBUUID, in service: CBUUID? = nil) async throws {
        guard let (_, ch) = find(uuid, in: service), let p = peripheral else {
            throw BLEFailure.notConnected
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            notifyContinuations[ObjectIdentifier(ch)] = c
            p.setNotifyValue(true, for: ch)
        }
    }

    enum BLEFailure: LocalizedError {
        case notConnected
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected."
            case .rejected(let m): m
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEClient: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            let waiters = powerOnWaiters
            powerOnWaiters.removeAll()
            for w in waiters { w.resume(returning: c.state) }
            switch c.state {
            case .unauthorized: state = .unauthorised
            case .poweredOff: state = .poweredOff
            default: break
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated { seen[p.identifier] = p }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            connectWaiter?.resume(returning: true)
            connectWaiter = nil
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            connectWaiter?.resume(returning: false)
            connectWaiter = nil
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            entries.removeAll()
            connectWaiter?.resume(returning: false); connectWaiter = nil
            discoveryWaiter?.resume(); discoveryWaiter = nil
            pendingServices.removeAll()
            for (_, cont) in readContinuations { cont.resume(returning: nil) }
            readContinuations.removeAll()
            for (_, cont) in writeContinuations { cont.resume(throwing: BLEFailure.notConnected) }
            writeContinuations.removeAll()
            for (_, cont) in notifyContinuations { cont.resume(throwing: BLEFailure.notConnected) }
            notifyContinuations.removeAll()
            if state == .connected { state = .idle }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEClient: CBPeripheralDelegate {

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = p.services ?? []
            guard !services.isEmpty else {
                discoveryWaiter?.resume(); discoveryWaiter = nil
                return
            }
            pendingServices = Set(services.map(\.uuid))
            for s in services { p.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            // Wykrywanie moze przebiec ponownie (auto-connect, potem wznowienie).
            // Bez czyszczenia te same pary dopisywalyby sie po raz drugi.
            entries.removeAll { $0.service == s.uuid }
            for ch in s.characteristics ?? [] { entries.append((service: s.uuid, ch: ch)) }
            pendingServices.remove(s.uuid)
            if pendingServices.isEmpty {
                discoveryWaiter?.resume()
                discoveryWaiter = nil
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let c = readContinuations.removeValue(forKey: ObjectIdentifier(ch)) {
                if let e = error { c.resume(throwing: e) } else { c.resume(returning: ch.value) }
                return
            }
            // Nikt nie czekal na odczyt - to notyfikacja z urzadzenia.
            if error == nil, let v = ch.value { onNotification?(ch.uuid, v) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let c = notifyContinuations.removeValue(forKey: ObjectIdentifier(ch)) else { return }
            if let e = error {
                c.resume(throwing: BLEFailure.rejected(e.localizedDescription))
            } else {
                c.resume()
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let c = writeContinuations.removeValue(forKey: ObjectIdentifier(ch)) else { return }
            if let e = error {
                c.resume(throwing: BLEFailure.rejected(e.localizedDescription))
            } else {
                c.resume()
            }
        }
    }
}
