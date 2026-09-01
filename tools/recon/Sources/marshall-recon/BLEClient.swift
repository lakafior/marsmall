import Foundation
@preconcurrency import CoreBluetooth

/// Peryferal znaleziony podczas skanu.
struct FoundPeripheral {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var advertisedServices: [CBUUID]
    var isConnectable: Bool
    /// Identyfikator producenta z Bluetooth SIG (pierwsze 2 bajty manufacturer data).
    /// 0x004C = Apple. Pomaga odsiac cudze iPhone'y i zegarki.
    var manufacturerID: UInt16?
    var manufacturerBytes: Int
    var identifier: UUID { peripheral.identifier }

    /// Czy warto to sondowac szukajac Marshalla.
    var looksLikeCandidate: Bool {
        if manufacturerID == 0x004C { return false }   // Apple - to nie sluchawki Marshalla
        return true
    }
}

enum BLEError: LocalizedError {
    case notPoweredOn(CBManagerState)
    case notFound(String)
    case connectFailed(String)
    case disconnected
    case timedOut(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPoweredOn(let s):
            switch s {
            case .unauthorized:
                return """
                Brak zgody na Bluetooth. macOS przypisuje ja aplikacji nadrzednej (Terminal / iTerm).
                Ustawienia systemowe -> Prywatnosc i ochrona -> Bluetooth -> wlacz dla swojego terminala,
                potem uruchom terminal ponownie.
                """
            case .poweredOff: return "Bluetooth jest wylaczony."
            case .unsupported: return "Ten Mac nie wspiera Bluetooth LE."
            default: return "Bluetooth niedostepny (stan: \(s.rawValue))."
            }
        case .notFound(let what):     return "Nie znaleziono: \(what)"
        case .connectFailed(let m):   return "Polaczenie nieudane: \(m)"
        case .disconnected:           return "Urzadzenie sie rozlaczylo."
        case .timedOut(let what):     return "Timeout: \(what)"
        case .operationFailed(let m): return m
        }
    }
}

/// Cienka warstwa async/await nad CoreBluetooth.
///
/// Wszystkie mutacje stanu ida przez prywatna kolejke `q` - ta sama, na ktorej
/// CoreBluetooth wola delegata. Dzieki temu nie ma wyscigow bez zadnych lockow.
///
/// Ta klasa jest jedynym miejscem, ktore trzeba bedzie przeniesc do iOS.
/// CoreBluetooth ma identyczne API na obu platformach - roznica to tylko
/// uprawnienia w Info.plist i tryb pracy w tle.
final class BLEClient: NSObject, @unchecked Sendable {

    private let q = DispatchQueue(label: "pl.marshall.recon.ble")
    private var central: CBCentralManager!

    // Kontynuacje oczekujacych operacji. Kazda jest resumowana dokladnie raz.
    private var stateCont: CheckedContinuation<CBManagerState, Never>?
    private var connectCont: CheckedContinuation<Void, Error>?
    private var servicesCont: CheckedContinuation<[CBService], Error>?
    private var charsCont: [CBUUID: CheckedContinuation<[CBCharacteristic], Error>] = [:]
    private var readConts: [ObjectIdentifier: CheckedContinuation<Data?, Error>] = [:]
    private var writeConts: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var notifyConts: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var descConts: [ObjectIdentifier: CheckedContinuation<[CBDescriptor], Error>] = [:]

    private var found: [UUID: FoundPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var disconnectCont: CheckedContinuation<Void, Error>?

    /// Wolane przy kazdej notyfikacji z subskrybowanej charakterystyki.
    /// To jest kanal, ktorym przyjdzie `actionButtonEvent`.
    var onNotify: ((CBCharacteristic, Data, Date) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: q)
    }

    // MARK: - Cykl zycia

    /// Czeka az adapter bedzie gotowy. Rzuca, jesli sie nie da.
    ///
    /// Timeout jest istotny: gdy macOS pokazuje pytanie o zgode na Bluetooth,
    /// stan zostaje `.unknown` dopoki uzytkownik nie kliknie. Bez limitu
    /// proces wisialby w nieskonczonosc.
    func waitUntilReady(timeout: Double = 20) async throws {
        let state: CBManagerState = try await withTimeout(timeout, what: "inicjalizacja Bluetooth (czy nie czeka pytanie o zgode?)") {
            await withCheckedContinuation { (c: CheckedContinuation<CBManagerState, Never>) in
                self.q.async {
                    if self.central.state != .unknown && self.central.state != .resetting {
                        c.resume(returning: self.central.state)
                    } else {
                        self.stateCont = c
                    }
                }
            }
        }
        guard state == .poweredOn else { throw BLEError.notPoweredOn(state) }
    }

    /// Skanuje przez zadany czas i zwraca to, co znalazl, posortowane po sile sygnalu.
    ///
    /// Skanujemy bez filtra serwisow, bo sluchawki czesto NIE reklamuja swojego
    /// wlasnego UUID-a w pakiecie rozgloszeniowym - trzeba je znalezc po nazwie.
    func scan(seconds: Double) async -> [FoundPeripheral] {
        q.async {
            self.found.removeAll()
            self.central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return await withCheckedContinuation { c in
            q.async {
                self.central.stopScan()
                c.resume(returning: self.found.values.sorted { $0.rssi > $1.rssi })
            }
        }
    }

    /// Peryferale juz polaczone z SYSTEMEM (np. sluchawki sparowane z Makiem jako
    /// urzadzenie audio). Takie urzadzenia zwykle NIE pojawiaja sie w skanie -
    /// skoro sa polaczone, przestaja sie rozglaszac. To osobne API CoreBluetooth
    /// i bez niego mozna ich w ogole nie znalezc.
    func alreadyConnected() async -> [FoundPeripheral] {
        await withCheckedContinuation { c in
            q.async {
                let list = self.central.retrieveConnectedPeripherals(withServices: [
                    Zound.service, Zound.batteryService, Zound.deviceInformationService,
                ])
                c.resume(returning: list.map {
                    FoundPeripheral(peripheral: $0, name: $0.name ?? "(bez nazwy)",
                                    rssi: 0, advertisedServices: [], isConnectable: true,
                                    manufacturerID: nil, manufacturerBytes: 0)
                })
            }
        }
    }

    func connect(_ p: CBPeripheral, timeout: Double = 15) async throws {
        p.delegate = self
        try await withTimeout(timeout, what: "polaczenie z \(p.name ?? "urzadzeniem")") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.q.async {
                    self.connectCont = c
                    self.connectedPeripheral = p
                    self.central.connect(p, options: nil)
                }
            }
        }
    }

    func disconnect() {
        q.async {
            if let p = self.connectedPeripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    /// Rozlacza i czeka na potwierdzenie. Sondowanie laczy sie z wieloma
    /// urzadzeniami po kolei - bez czekania nastepne polaczenie deptalo by poprzednie.
    func disconnectAndWait(timeout: Double = 5) async {
        guard connectedPeripheral != nil else { return }
        _ = try? await withTimeout(timeout, what: "rozlaczenie") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.q.async {
                    guard let p = self.connectedPeripheral else { c.resume(); return }
                    self.disconnectCont = c
                    self.central.cancelPeripheralConnection(p)
                }
            }
        }
    }

    // MARK: - Odkrywanie

    /// Odkrywa WSZYSTKIE serwisy (nie tylko Zoundowy) - chcemy zobaczyc pelny obraz.
    func discoverServices(timeout: Double = 15) async throws -> [CBService] {
        guard let p = connectedPeripheral else { throw BLEError.disconnected }
        return try await withTimeout(timeout, what: "odkrywanie serwisow") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[CBService], Error>) in
                self.q.async {
                    self.servicesCont = c
                    p.discoverServices(nil)
                }
            }
        }
    }

    func discoverCharacteristics(for service: CBService, timeout: Double = 15) async throws -> [CBCharacteristic] {
        guard let p = connectedPeripheral else { throw BLEError.disconnected }
        return try await withTimeout(timeout, what: "odkrywanie charakterystyk \(service.uuid)") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[CBCharacteristic], Error>) in
                self.q.async {
                    self.charsCont[service.uuid] = c
                    p.discoverCharacteristics(nil, for: service)
                }
            }
        }
    }

    // MARK: - Operacje na charakterystykach

    /// Odczyt zwracajacy TRESC BLEDU zamiast go polykac.
    ///
    /// To jest istotne: "Insufficient Authentication" (trzeba sparowac),
    /// "Read Not Permitted" (charakterystyka tylko do zapisu) i timeout
    /// wymagaja zupelnie roznych reakcji. Bez tresci bledu strzelamy na slepo.
    func readResult(_ ch: CBCharacteristic, timeout: Double = 8) async -> Result<Data?, Error> {
        guard let p = connectedPeripheral else { return .failure(BLEError.disconnected) }
        let key = ObjectIdentifier(ch)
        do {
            let v = try await withTimeout(timeout, what: "odczyt \(ch.uuid)") {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
                    self.q.async {
                        self.readConts[key] = c
                        p.readValue(for: ch)
                    }
                }
            }
            return .success(v)
        } catch {
            // Posprzataj osierocona kontynuacje po timeoucie.
            q.async { self.readConts.removeValue(forKey: key) }
            return .failure(error)
        }
    }

    /// Wygodny skrot tam, gdzie tresc bledu nie jest potrzebna.
    func read(_ ch: CBCharacteristic, timeout: Double = 8) async -> Data? {
        if case .success(let v) = await readResult(ch, timeout: timeout) { return v }
        return nil
    }

    func write(_ ch: CBCharacteristic, data: Data, withResponse: Bool, timeout: Double = 8) async throws {
        guard let p = connectedPeripheral else { throw BLEError.disconnected }
        guard withResponse else {
            // Bez odpowiedzi nie ma na co czekac.
            q.async { p.writeValue(data, for: ch, type: .withoutResponse) }
            return
        }
        let key = ObjectIdentifier(ch)
        try await withTimeout(timeout, what: "zapis \(ch.uuid)") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.q.async {
                    self.writeConts[key] = c
                    p.writeValue(data, for: ch, type: .withResponse)
                }
            }
        }
    }

    /// Odkrywa deskryptory charakterystyki. Diagnostyka: jesli charakterystyka
    /// deklaruje NOTIFY, ale nie ma deskryptora CCCD (0x2902) albo ma go
    /// niestandardowego, subskrypcja bedzie odrzucana.
    func discoverDescriptors(for ch: CBCharacteristic, timeout: Double = 8) async -> [CBDescriptor] {
        guard let p = connectedPeripheral else { return [] }
        let key = ObjectIdentifier(ch)
        let r = try? await withTimeout(timeout, what: "deskryptory \(ch.uuid)") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[CBDescriptor], Error>) in
                self.q.async {
                    self.descConts[key] = c
                    p.discoverDescriptors(for: ch)
                }
            }
        }
        return r ?? []
    }

    /// Zapis do wskazanej charakterystyki, z automatycznym wyborem trybu.
    func write(_ data: Data, to ch: CBCharacteristic) async throws {
        try await write(ch, data: data, withResponse: ch.properties.contains(.write))
    }

    /// Wlacza notyfikacje. Kazde przychodzace zdarzenie leci do `onNotify`.
    func subscribe(_ ch: CBCharacteristic, timeout: Double = 8) async throws {
        guard let p = connectedPeripheral else { throw BLEError.disconnected }
        let key = ObjectIdentifier(ch)
        try await withTimeout(timeout, what: "subskrypcja \(ch.uuid)") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.q.async {
                    self.notifyConts[key] = c
                    p.setNotifyValue(true, for: ch)
                }
            }
        }
    }

    // MARK: - Pomocnicze

    private func withTimeout<T: Sendable>(
        _ seconds: Double, what: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BLEError.timedOut(what)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        stateCont?.resume(returning: c.state)
        stateCont = nil
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi RSSI: NSNumber) {
        let name = (d[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "(bez nazwy)"
        let services = (d[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let connectable = (d[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data
        var mfgID: UInt16?
        if let m = mfg, m.count >= 2 { mfgID = UInt16(m[m.startIndex]) | (UInt16(m[m.startIndex + 1]) << 8) }
        found[p.identifier] = FoundPeripheral(
            peripheral: p, name: name, rssi: RSSI.intValue,
            advertisedServices: services, isConnectable: connectable,
            manufacturerID: mfgID, manufacturerBytes: mfg?.count ?? 0
        )
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connectCont?.resume(); connectCont = nil
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connectCont?.resume(throwing: BLEError.connectFailed(error?.localizedDescription ?? "nieznany blad"))
        connectCont = nil
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // Obudz wszystko, co czeka - inaczej zawisniemy do timeoutu.
        connectCont?.resume(throwing: BLEError.disconnected); connectCont = nil
        servicesCont?.resume(throwing: BLEError.disconnected); servicesCont = nil
        for (_, c) in charsCont { c.resume(throwing: BLEError.disconnected) };   charsCont.removeAll()
        for (_, c) in readConts { c.resume(throwing: BLEError.disconnected) };   readConts.removeAll()
        for (_, c) in writeConts { c.resume(throwing: BLEError.disconnected) };  writeConts.removeAll()
        for (_, c) in notifyConts { c.resume(throwing: BLEError.disconnected) }; notifyConts.removeAll()
        for (_, c) in descConts { c.resume(throwing: BLEError.disconnected) };     descConts.removeAll()
        connectedPeripheral = nil
        disconnectCont?.resume(); disconnectCont = nil
    }
}

// MARK: - CBPeripheralDelegate

extension BLEClient: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            servicesCont?.resume(throwing: BLEError.operationFailed(e.localizedDescription))
        } else {
            servicesCont?.resume(returning: p.services ?? [])
        }
        servicesCont = nil
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let c = charsCont.removeValue(forKey: s.uuid) else { return }
        if let e = error {
            c.resume(throwing: BLEError.operationFailed(e.localizedDescription))
        } else {
            c.resume(returning: s.characteristics ?? [])
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let key = ObjectIdentifier(ch)
        if let c = readConts.removeValue(forKey: key) {
            // To byla odpowiedz na nasz jawny odczyt.
            if let e = error {
                c.resume(throwing: BLEError.operationFailed(e.localizedDescription))
            } else {
                c.resume(returning: ch.value)
            }
            return
        }
        // Nikt nie czekal na odczyt -> to jest notyfikacja z urzadzenia.
        if error == nil, let v = ch.value {
            onNotify?(ch, v, Date())
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard let c = writeConts.removeValue(forKey: ObjectIdentifier(ch)) else { return }
        if let e = error {
            c.resume(throwing: BLEError.operationFailed(e.localizedDescription))
        } else {
            c.resume()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {
        guard let c = descConts.removeValue(forKey: ObjectIdentifier(ch)) else { return }
        if let e = error {
            c.resume(throwing: BLEError.operationFailed(e.localizedDescription))
        } else {
            c.resume(returning: ch.descriptors ?? [])
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard let c = notifyConts.removeValue(forKey: ObjectIdentifier(ch)) else { return }
        if let e = error {
            c.resume(throwing: BLEError.operationFailed(e.localizedDescription))
        } else {
            c.resume()
        }
    }
}
