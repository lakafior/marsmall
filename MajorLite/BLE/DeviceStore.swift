import Foundation
import CoreBluetooth
import Observation

/// The whole device state, and the only place that talks to `BLEClient`.
///
/// The Zound characteristics all advertise NOTIFY, but the firmware rejects every
/// attempt to subscribe (ATT 0x0D on the CCCD write) — verified with and without
/// another host connected. So instead of notifications we poll while the app is
/// on screen. Reads are fast and this is a settings screen, not a game.
@MainActor
@Observable
final class DeviceStore {

    let ble = BLEClient()

    // Read-only information
    var model: String?
    var firmware: String?
    var hardware: String?
    var serial: String?
    var manufacturer: String?
    var batteryPercent: Int?
    var nowPlaying: [Int: String] = [:]
    /// Potwierdzone: sledzi pokretlo glosnosci.
    var volume: Int?
    /// Aktywny slot korektora (1 albo 2). Przycisk M w trybie "equalizer"
    /// przelacza wlasnie te wartosc.
    var equaliserSlot: Int?
    /// Preset zajmujacy slot 2. Slot 1 to zawsze fabryczne brzmienie Marshalla.
    var equaliserPreset: MajorV.EqualiserPreset?
    /// Surowy bajt charge_status z GET_CHARGE_INFO. Znaczenia wartosci innych
    /// niz zero jeszcze nie ustalilismy - traktujemy niezerowe jako ladowanie.
    var chargeStatus: UInt8?
    var isCharging: Bool { (chargeStatus ?? 0) != 0 }

    // Editable settings
    var interactionSounds: Bool?
    var batteryPreservation: MajorV.BatteryPreservation?
    var autoOffTimers: [MajorV.AutoOffTimer] = []
    var buttonAction: MajorV.ButtonAction?

    /// Last error shown to the user, e.g. a rejected write.
    var lastError: String?

    /// Raw bytes of everything we have read, keyed "SERVICE/CHARACTERISTIC".
    var rawValues: [String: Data] { ble.rawValues }
    /// Every discovered service + characteristic pair, for the diagnostics screen.
    var entries: [(service: CBUUID, characteristic: CBUUID, properties: CBCharacteristicProperties)] {
        ble.allEntries
    }

    private var pollTask: Task<Void, Never>?

    /// Odpowiedzi RACE, ktore przyszly z urzadzenia, po race_id.
    private var raceInbox: [UInt16: [UInt8]] = [:]

    /// Czy kanal RACE jest otwarty (subskrypcja przeszla).
    private(set) var raceReady = false

    var isConnected: Bool { ble.state == .connected }

    // MARK: - Lifecycle

    func connect() async {
        await ble.connect()
        guard ble.state == .connected else { return }
        await openRaceChannel()
        await refreshAll()
        startPolling()
    }

    // MARK: - Kanal RACE Airohy

    /// Poziom baterii nie jest dostepny przez GATT: standardowe 2A19 zwraca zero,
    /// a 2BED ma flage "brak poziomu". Sluchawki podaja go dopiero na zapytanie
    /// kanalem RACE - tak samo, jak robi to oficjalna aplikacja.
    private func openRaceChannel() async {
        ble.onNotification = { [weak self] uuid, data in
            guard uuid == Race.notifyCharacteristic,
                  let frame = Race.parse(data) else { return }
            self?.raceInbox[frame.id] = frame.payload
        }
        do {
            try await ble.subscribe(Race.notifyCharacteristic, in: Race.service)
            raceReady = true
        } catch {
            raceReady = false
        }
    }

    /// Wysyla komende i czeka na odpowiedz o tym samym race_id.
    ///
    /// Wysylamy wylacznie polecenia odczytu. Ten sam katalog zawiera aktualizacje
    /// firmware, kasowanie pamieci i zapis NVKEY - jedno z nich potrafilo wylaczyc
    /// sluchawki - wiec nic stad nie leci "na probe".
    private func race(_ id: UInt16, _ payload: [UInt8] = [],
                      timeout: Double = 2) async -> [UInt8]? {
        guard raceReady else { return nil }
        raceInbox[id] = nil
        do {
            try await ble.write(Race.packet(id: id, payload: payload),
                                to: Race.writeCharacteristic, in: Race.service)
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = raceInbox.removeValue(forKey: id) { return v }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }

    /// Odpowiedz TWS_GET_BATTERY: [status][agent_or_client][procent].
    private func refreshBatteryViaRace() async {
        guard let p = await race(Race.TWS_GET_BATTERY, [0x00]),
              p.count >= 3, p[0] == 0x00 else { return }
        let percent = Int(p[2])
        if (1...100).contains(percent) { batteryPercent = percent }
    }

    /// Odpowiedz GET_CHARGE_INFO: [status][agent_or_client][charge_status].
    private func refreshChargeViaRace() async {
        guard let p = await race(Race.GET_CHARGE_INFO, [0x00]),
              p.count >= 3, p[0] == 0x00 else { return }
        chargeStatus = p[2]
    }

    func disconnect() {
        stopPolling()
        ble.disconnect()
    }

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.isConnected else { continue }
                await self.refreshDynamic()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Reading

    func refreshAll() async {
        if let d = await ble.read(MajorV.Info.modelNumber, in: MajorV.deviceInfoService) { model = Decode.text(d) }
        if let d = await ble.read(MajorV.Info.firmwareRevision, in: MajorV.deviceInfoService) { firmware = Decode.text(d) }
        if let d = await ble.read(MajorV.Info.hardwareRevision, in: MajorV.deviceInfoService) { hardware = Decode.text(d) }
        if let d = await ble.read(MajorV.Info.serialNumber, in: MajorV.deviceInfoService) { serial = Decode.text(d) }
        if let d = await ble.read(MajorV.Info.manufacturer, in: MajorV.deviceInfoService) { manufacturer = Decode.text(d) }
        await refreshDynamic()
    }

    /// Everything that can change while the app is open.
    func refreshDynamic() async {
        // Najpierw standardowa charakterystyka - na wypadek, gdyby kiedys zaczela
        // dzialac. Jesli zwraca zero (a na Major V zwraca), pytamy kanalem RACE.
        if let d = await ble.read(MajorV.Info.batteryLevel, in: MajorV.batteryService),
           let b = d.first, b > 0 {
            batteryPercent = Int(b)
        } else {
            await refreshBatteryViaRace()
        }
        await refreshChargeViaRace()
        if let d = await ble.read(MajorV.Char.interactionSounds.uuid) {
            interactionSounds = Decode.interactionSounds(d)
        }
        if let d = await ble.read(MajorV.Char.batteryPreservation.uuid) {
            batteryPreservation = Decode.batteryPreservation(d)
        }
        if let d = await ble.read(MajorV.Char.autoOffTimers.uuid) {
            autoOffTimers = Decode.autoOffTimers(d)
        }
        if let d = await ble.read(MajorV.Char.mButtonAction.uuid) {
            buttonAction = Decode.buttonAction(d)
        }
        if let d = await ble.read(MajorV.Char.nowPlaying.uuid) {
            nowPlaying = Decode.nowPlaying(d)
        }
        if let d = await ble.read(MajorV.Char.volume.uuid), let v = d.first {
            volume = Int(v)
        }
        if let d = await ble.read(MajorV.Char.equaliser.uuid),
           let eq = Decode.equaliser(d) {
            equaliserSlot = eq.slot
            equaliserPreset = eq.preset
        }
    }

    /// Czyta KAZDA odczytywalna charakterystyke, takze te, ktorych jeszcze nie
    /// umiemy zdekodowac. Sluzy ekranowi diagnostycznemu - bez tego nieznane
    /// charakterystyki zostaja puste i nie ma jak dojsc, ktora niesie co.
    func readEverything() async {
        for e in ble.allEntries where e.properties.contains(.read) {
            _ = await ble.read(e.characteristic, in: e.service)
        }
    }

    /// Tekstowy zrzut wszystkiego, co widac na urzadzeniu - do skopiowania
    /// i wklejenia. Ten sam uklad co `marshall-recon dump`.
    func diagnosticsReport() -> String {
        var out = ["MajorLite - diagnostics",
                   "device:      \(ble.deviceName ?? "?")",
                   "model:       \(model ?? "?")",
                   "firmware:    \(firmware ?? "?")  hardware: \(hardware ?? "?")",
                   "read:        \(rawValues.count) of \(entries.count) characteristics",
                   ""]

        let grouped = Dictionary(grouping: entries, by: \.service)
        for service in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            out.append("service \(MajorV.label(for: service))")
            let rows = (grouped[service] ?? []).sorted {
                $0.characteristic.uuidString < $1.characteristic.uuidString
            }
            for r in rows {
                let id = MajorV.label(for: r.characteristic).padding(toLength: 10,
                                                                    withPad: " ", startingAt: 0)
                let props = Self.propertyList(r.properties).joined(separator: ",")
                    .padding(toLength: 22, withPad: " ", startingAt: 0)
                let value = rawValues[BLEClient.key(service, r.characteristic)]
                    .map { Hex.describe($0) } ?? "(not read)"
                var line = "  \(id) [\(props)] \(value)"
                if let name = MajorV.friendlyName(for: r.characteristic) {
                    line += "   <- \(name)"
                }
                out.append(line)
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func propertyList(_ p: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out
    }

    /// Ustawia preset w slocie 2.
    func setEqualiserPreset(_ preset: MajorV.EqualiserPreset) async {
        await writeEqualiser(Encode.equaliserPreset(preset)) {
            Decode.equaliser($0)?.preset == preset
        }
    }

    /// Przelacza aktywny slot. Ta sama charakterystyka co preset, inne pole.
    func setEqualiserSlot(_ slot: Int) async {
        guard (1...2).contains(slot) else { return }
        await writeEqualiser(Encode.equaliserSlot(slot)) {
            Decode.equaliser($0)?.slot == slot
        }
    }

    /// Format jest potwierdzony podsluchem, wiec zadnego probowania wariantow -
    /// jeden zapis i weryfikacja odczytem.
    private func writeEqualiser(_ payload: Data,
                                verify: (Data) -> Bool) async {
        lastError = nil
        do {
            try await ble.write(payload, to: MajorV.Char.equaliser.uuid)
        } catch {
            lastError = error.localizedDescription
        }
        if let after = await ble.read(MajorV.Char.equaliser.uuid),
           let eq = Decode.equaliser(after) {
            equaliserSlot = eq.slot
            equaliserPreset = eq.preset
            if !verify(after) && lastError == nil {
                lastError = "The headphones did not apply the change."
            }
        }
    }

    // MARK: - Migawka i porownanie
    //
    // Ta sama metoda roznicowa, ktora rozszyfrowala reszte protokolu: zapisz stan,
    // zmien JEDNO ustawienie w oficjalnej aplikacji, porownaj.

    private(set) var snapshot: [String: Data]?
    private(set) var snapshotTaken: Date?

    func saveSnapshot() async {
        await readEverything()
        snapshot = rawValues
        snapshotTaken = Date()
    }

    /// Zwraca opis kazdej charakterystyki, ktora zmienila sie od migawki.
    func compareWithSnapshot() async -> [String] {
        guard let before = snapshot else { return ["Brak migawki."] }
        await readEverything()
        let after = rawValues

        var out: [String] = []
        for key in Set(before.keys).union(after.keys).sorted() {
            let a = before[key], b = after[key]
            guard a != b else { continue }
            let char = key.split(separator: "/").last.map(String.init) ?? key
            let uuid = CBUUID(string: char)
            let name = MajorV.friendlyName(for: uuid)
            out.append("\(MajorV.label(for: uuid))\(name.map { " (\($0))" } ?? "")")
            out.append("   przed: \(a.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-")")
            out.append("   po:    \(b.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-")")
        }
        return out.isEmpty ? ["Bez zmian."] : out
    }

    // MARK: - Find My Headphones

    /// FIND_ME: `[light][alert][recipient]`. Nic nie zapisuje w urzadzeniu.
    ///
    /// Zmierzone na Major V: dzwiek dziala, parametr swiatla nie robi nic -
    /// dioda nie zmienia koloru. Prawdopodobnie te sluchawki nie maja diody
    /// sterowanej tym kanalem.
    @discardableResult
    func findMe(_ on: Bool) async -> Bool {
        let v: UInt8 = on ? 1 : 0
        guard let p = await race(Race.FIND_ME, [v, v, 0x00]) else { return false }
        return p.first == 0x00
    }

    func findMeState() async -> UInt8? {
        guard let p = await race(Race.FIND_ME_QUERY_STATE), p.count >= 2,
              p[0] == 0x00 else { return nil }
        return p[1]
    }

    // MARK: - Sonda mozliwosci chipu

    /// Odpytuje wylacznie komendy odczytu. GET_MMI_ENUM ma udokumentowana
    /// odpowiedz `[status][dane]`, wiec jest czytnikiem - w odroznieniu od
    /// ENABLE_KEY_EVENT, ktore mimo nazwy okazalo sie wykonywac akcje.
    func probeCapabilities() async -> [String] {
        var out: [String] = []

        if let p = await race(Race.AUDIO_FEATURE_CAPABILITY, [0x00, 0x01]) {
            out.append("AUDIO_FEATURE_CAPABILITY  status=0x\(hex(p.first ?? 0))  \(hexAll(p))")
        } else {
            out.append("AUDIO_FEATURE_CAPABILITY  brak odpowiedzi")
        }

        for module in 0..<UInt16(Race.mmiModules.count) {
            let payload: [UInt8] = [UInt8(module & 0xFF), UInt8(module >> 8)]
            let name = pad(Race.moduleName(Int(module)))
            guard let p = await race(Race.GET_MMI_ENUM, payload, timeout: 1.2),
                  let r = Race.decodeModuleReply(p) else {
                out.append("\(name)  not implemented")
                continue
            }
            let mark = r.ok ? "OK " : "0x\(hex(r.status))"
            let data = r.data.isEmpty ? "-" : hexAll(r.data)
            out.append("\(name)  \(mark)  \(data)")
        }
        return out
    }

    private func hex(_ b: UInt8) -> String { String(format: "%02X", b) }
    private func hexAll(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private func pad(_ s: String) -> String { s.padding(toLength: 18, withPad: " ", startingAt: 0) }

    // MARK: - Writing

    /// Jeden zapis, potem odczyt kontrolny. Zadnego probowania wariantow -
    /// wszystkie formaty sa potwierdzone podsluchem oficjalnej aplikacji.
    private func apply(_ char: MajorV.Char, _ payload: Data,
                       verify: (Data) -> Bool) async -> Bool {
        lastError = nil
        do {
            try await ble.write(payload, to: char.uuid)
        } catch {
            lastError = error.localizedDescription
            await refreshDynamic()
            return false
        }
        guard let after = await ble.read(char.uuid) else { return false }
        if verify(after) { return true }
        lastError = "The headphones did not apply the change."
        await refreshDynamic()
        return false
    }

    func setInteractionSounds(_ on: Bool) async {
        if await apply(.interactionSounds, Encode.interactionSounds(on),
                       verify: { Decode.interactionSounds($0) == on }) {
            interactionSounds = on
        }
    }

    func setBatteryPreservation(_ level: MajorV.BatteryPreservation) async {
        if await apply(.batteryPreservation, Encode.batteryPreservation(level),
                       verify: { Decode.batteryPreservation($0) == level }) {
            batteryPreservation = level
        }
    }

    func setAutoOffTimer(_ timer: MajorV.AutoOffTimer, seconds: UInt16) async {
        if await apply(.autoOffTimers, Encode.autoOffTimer(timer, seconds: seconds),
                       verify: { Decode.autoOffTimers($0).first { $0.id == timer.id }?.seconds == seconds }),
           let i = autoOffTimers.firstIndex(where: { $0.id == timer.id }) {
            autoOffTimers[i].seconds = seconds
        }
    }

    func setButtonAction(_ action: MajorV.ButtonAction) async {
        if await apply(.mButtonAction, Encode.buttonAction(action),
                       verify: { Decode.buttonAction($0) == action }) {
            buttonAction = action
        }
    }
}
