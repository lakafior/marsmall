import Foundation
import CoreBluetooth

// ============================================================================
//  marshall-recon
//
//  Narzedzie rozpoznawcze do sluchawek Marshall Major V (kryptonim "plant")
//  i innych urzadzen Zounda na tym samym protokole GATT.
//
//  Cel: ustalic ktora charakterystyka odpowiada ktorej funkcji i jaki ma format
//  danych, zanim napiszemy wlasciwa aplikacje.
// ============================================================================

// MARK: - Parsowanie argumentow (bez zaleznosci zewnetrznych)

struct Args {
    let command: String
    let positional: [String]
    private let flags: [String: String]
    private let bools: Set<String>

    init(_ argv: [String]) {
        var rest = Array(argv.dropFirst())
        command = rest.first ?? "help"
        if !rest.isEmpty { rest.removeFirst() }

        var pos: [String] = [], f: [String: String] = [:], b: Set<String> = []
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < rest.count && !rest[i + 1].hasPrefix("--") {
                    f[key] = rest[i + 1]; i += 2
                } else {
                    b.insert(key); i += 1
                }
            } else {
                pos.append(a); i += 1
            }
        }
        positional = pos; flags = f; bools = b
    }

    func string(_ k: String) -> String? { flags[k] }
    func double(_ k: String, default d: Double) -> Double { flags[k].flatMap(Double.init) ?? d }
    func bool(_ k: String) -> Bool { bools.contains(k) }
}

// MARK: - Wspolne: znajdz i polacz

/// Skanuje i wybiera urzadzenie po fragmencie nazwy. Domyslnie szuka Marshalla.
func findDevice(_ client: BLEClient, args: Args) async throws -> FoundPeripheral {
    let needle = (args.string("name") ?? "marshall").lowercased()
    let seconds = args.double("seconds", default: 8)

    func note(_ t: String) { FileHandle.standardError.write((t + "\n").data(using: .utf8)!) }

    note("Skanuje \(Int(seconds))s...")
    var all = await client.scan(seconds: seconds)

    // Sluchawki polaczone z Makiem jako audio nie rozglaszaja sie, wiec nie ma ich
    // w skanie. Trzeba je pobrac osobnym API - inaczej wygladaja na nieobecne.
    for p in await client.alreadyConnected()
    where !all.contains(where: { $0.identifier == p.identifier }) {
        all.append(p)
    }

    // 1. Jawnie podany identyfikator.
    if let id = args.string("id") {
        if let hit = all.first(where: { $0.identifier.uuidString.lowercased() == id.lowercased() }) {
            return hit
        }
        note("""
        Nie ma urzadzenia o id \(id).

        Major V uzywa losowych adresow prywatnych BLE: po wylaczeniu i wlaczeniu
        dostaje nowy adres, a niezbondowany Mac nie potrafi go rozwiazac i widzi
        je jako nowe urzadzenie. Stary identyfikator sie zdezaktualizowal.
        Sprobuje rozpoznac sluchawki po zawartosci.
        """)
    }

    // 2. Nazwa z rozgloszenia - dziala tylko, gdy urzadzenie ja wysyla.
    if let hit = all.first(where: { $0.name.lowercased().contains(needle) }) { return hit }

    // 3. Rozpoznanie po zawartosci: laczymy sie z kandydatami i sprawdzamy,
    //    czy wystawiaja serwis Zounda albo czy po polaczeniu podaja nasza nazwe.
    //    To jedyny sposob odporny na rotacje adresu.
    if !args.bool("no-probe") {
        let candidates = all
            .filter { $0.looksLikeCandidate && $0.isConnectable && $0.rssi >= -80 }
            .sorted { $0.rssi > $1.rssi }
        note("Rozpoznaje po zawartosci - sonduje \(candidates.count) kandydatow...")

        for c in candidates {
            guard (try? await client.connect(c.peripheral, timeout: 8)) != nil else { continue }
            let services = (try? await client.discoverServices(timeout: 8)) ?? []
            let nameNow = c.peripheral.name ?? c.name
            let isOurs = services.contains {
                $0.uuid == Zound.zoundServiceOnMajorV || $0.uuid == Zound.service || $0.uuid == Zound.airohaService
            } || nameNow.lowercased().contains(needle)
            await client.disconnectAndWait()

            if isOurs {
                note("Rozpoznano: \(nameNow)  [\(c.identifier)]")
                var hit = c; hit.name = nameNow
                return hit
            }
        }
    }

    var msg = "urzadzenie z \"\(needle)\" w nazwie ani zadne wystawiajace serwis Zounda.\n\nWidzialem:\n"
    for p in all.prefix(20) { msg += "  \(p.rssi) dBm  \(p.name)  [\(p.identifier)]\n" }
    msg += """

    Po kolei:
      1. sluchawki wlaczone? Major V ma auto-off, moglo je uspic
      2. Bluetooth w iPhonie wylaczony? Po wlaczeniu sluchawki wracaja do telefonu
         i przestaja sie rozglaszac
      3. tryb parowania: podwojne nacisniecie pokretla, LED wolno pulsuje na niebiesko

    Trwale rozwiazanie: sparuj sluchawki z Makiem (Ustawienia -> Bluetooth).
    Bonding sprawia, ze macOS rozwiazuje ich losowy adres i widzi je stabilnie
    - a przy okazji jest prawdopodobnie potrzebny do odczytu charakterystyk Zounda.
    """
    throw BLEError.notFound(msg)
}

/// Laczy sie i odkrywa cala strukture GATT.
func connectAndDiscover(_ client: BLEClient, _ target: FoundPeripheral)
    async throws -> [(CBService, [CBCharacteristic])]
{
    print("Lacze z \"\(target.name)\" [\(target.identifier)] ...")
    try await client.connect(target.peripheral)
    print("Polaczono. Odkrywam serwisy...\n")

    let services = try await client.discoverServices()
    var out: [(CBService, [CBCharacteristic])] = []
    for s in services {
        let chars = (try? await client.discoverCharacteristics(for: s)) ?? []
        out.append((s, chars))
    }
    return out
}

// MARK: - Komendy

func cmdScan(_ client: BLEClient, _ args: Args) async throws {
    let seconds = args.double("seconds", default: 8)
    print("Skanuje \(Int(seconds))s...\n")
    var all = await client.scan(seconds: seconds)
    let systemConnected = await client.alreadyConnected()
    var systemOnly: [FoundPeripheral] = []
    for p in systemConnected where !all.contains(where: { $0.identifier == p.identifier }) {
        systemOnly.append(p); all.append(p)
    }
    guard !all.isEmpty else {
        print("""
        Nic nie znaleziono.

        Sprawdz po kolei:
          1. sluchawki wlaczone (parowanie z Makiem nie jest potrzebne)
          2. Bluetooth w iPhonie wylaczony / aplikacja Marshall zamknieta
          3. tryb parowania: podwojne nacisniecie pokretla, LED wolno pulsuje na niebiesko
        """)
        return
    }
    if !systemOnly.isEmpty {
        print("Polaczone z systemem (nie rozglaszaja sie, wiec nie ma ich w skanie):")
        for p in systemOnly { print("   \(p.name)  [\(p.identifier)]") }
        print("")
    }

    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    defer {
        print("""

        Nie widzisz Marshalla po nazwie? Czesc urzadzen nie wysyla nazwy w rozgloszeniu.
        Sprawdz kandydatow lacząc sie z nimi:

            ./mr probe                 # sonduje wszystkich kandydatow (pomija Apple)
            ./mr probe --id <UUID>     # sonduje jedno konkretne
        """)
    }
    print(pad("RSSI", 7) + pad("IDENTYFIKATOR", 38) + "NAZWA")
    for p in all {
        var mark = ""
        if p.advertisedServices.contains(Zound.service) { mark = "  <== SERWIS ZOUNDA" }
        else if p.manufacturerID == 0x004C { mark = "  (Apple)" }
        else if p.name == "(bez nazwy)" { mark = "  <- kandydat do sondowania" }
        print(pad("\(p.rssi)", 7) + pad(p.identifier.uuidString, 38) + p.name + mark)
        if !p.advertisedServices.isEmpty {
            print("       reklamuje: \(p.advertisedServices.map(\.uuidString).joined(separator: ", "))")
        }
        if let m = p.manufacturerID {
            let who = m == 0x004C ? "Apple" : String(format: "0x%04X", m)
            print("       producent: \(who), \(p.manufacturerBytes) B danych")
        }
    }
}

func cmdDump(_ client: BLEClient, _ args: Args) async throws {
    let target = try await findDevice(client, args: args)
    let tree = try await connectAndDiscover(client, target)

    var snap = Snapshot(deviceName: target.name,
                        identifier: target.identifier.uuidString,
                        capturedAt: Date(),
                        note: args.string("note"),
                        services: [])

    // --only ogranicza zrzut do jednego serwisu. Przy 13 charakterystykach
    // z timeoutami pelny przebieg trwa minuty - przy iteracji to sie liczy.
    let only = args.string("only")?.uppercased()

    for (service, chars) in tree {
        if let only, !service.uuid.uuidString.uppercased().hasPrefix(only) { continue }
        let sLabel = Zound.label(for: service.uuid)
        print("SERWIS \(service.uuid.uuidString)" + (sLabel.map { "   (\($0))" } ?? ""))

        var dumped: [Snapshot.CharacteristicDump] = []
        for ch in chars {
            let props = Fmt.properties(ch.properties)
            var hex: String?, ascii: String?
            var shown = "-"

            var errText: String?
            if ch.properties.contains(.read) {
                switch await client.readResult(ch) {
                case .success(let v):
                    if let v {
                        hex = Fmt.hex(v)
                        ascii = Fmt.asciiIfPrintable(v)
                        shown = Fmt.describe(v)
                    } else {
                        shown = "(pusto)"
                    }
                case .failure(let e):
                    errText = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                    shown = "ODCZYT NIEUDANY: \(errText!)"
                }
            } else {
                shown = "(brak prawa READ)"
            }

            print("   \(ch.uuid.uuidString)  [\(props.joined(separator: ","))]")
            print("      \(shown)")

            // --desc pokazuje deskryptory. Brak CCCD (0x2902) przy charakterystyce
            // z flaga NOTIFY tlumaczy, dlaczego subskrypcja jest odrzucana.
            if args.bool("desc") {
                let ds = await client.discoverDescriptors(for: ch)
                if ds.isEmpty {
                    print("      deskryptory: BRAK" + (ch.properties.contains(.notify) ? "  <-- ma NOTIFY, ale nie ma CCCD" : ""))
                } else {
                    print("      deskryptory: " + ds.map { $0.uuid.uuidString }.joined(separator: ", "))
                }
            }

            dumped.append(.init(uuid: ch.uuid.uuidString,
                                label: Zound.label(for: ch.uuid),
                                properties: props, hex: hex, ascii: ascii, error: errText))
        }
        print("")
        snap.services.append(.init(uuid: service.uuid.uuidString, label: sLabel, characteristics: dumped))
    }

    if let out = args.string("out") {
        try snap.write(to: out)
        print("Zrzut zapisany: \(out)")
    } else {
        print("Podpowiedz: dodaj --out plik.json zeby zapisac zrzut do porownania (marshall-recon diff).")
    }
    client.disconnect()
}

/// Bufor pakietow przychodzacych z urzadzenia. Notyfikacje trafiaja tu z kolejki
/// BLE, glowne zadanie je zabiera po kazdej wyslanej komendzie.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []

    func add(_ d: Data) { lock.lock(); items.append(d); lock.unlock() }

    func drain() -> [Data] {
        lock.lock()
        let out = items
        items.removeAll()
        lock.unlock()
        return out
    }
}

/// Flaga ustawiana na kolejce BLE, czytana z glownego zadania.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func raise() { lock.lock(); value = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Przechowuje ostatnio widziana wartosc kazdej charakterystyki, zeby przy
/// notyfikacji pokazac "bylo -> jest". Notyfikacje przychodza na kolejce BLE,
/// a odczyty poczatkowe z glownego zadania - stad zamek.
final class ValueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier: Data] = [:]

    func set(_ key: ObjectIdentifier, _ d: Data) {
        lock.lock(); defer { lock.unlock() }
        values[key] = d
    }

    /// Zapisuje nowa wartosc i zwraca poprzednia, jesli byla inna.
    func update(_ key: ObjectIdentifier, _ d: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let old = values[key]
        values[key] = d
        return old != d ? old : nil
    }
}

/// Subskrybuje wszystkie charakterystyki z NOTIFY i wypisuje, co przychodzi.
///
/// Dwa zastosowania:
///  1. test przycisku M - odpal i nacisnij przycisk,
///  2. podsluch na zywo - odpal i rownolegle zmieniaj ustawienia w oficjalnej
///     aplikacji na telefonie. Jesli sluchawki utrzymaja dwa polaczenia BLE naraz,
///     dostaniesz cale mapowanie w jednej sesji, bez robienia zrzutow i diffow.
func cmdWatch(_ client: BLEClient, _ args: Args) async throws {
    let target = try await findDevice(client, args: args)
    let tree = try await connectAndDiscover(client, target)

    let store = ValueStore()
    var names: [ObjectIdentifier: String] = [:]
    var subscribed = 0

    client.onNotify = { ch, data, when in
        let who = names[ObjectIdentifier(ch)] ?? Zound.shortName(for: ch.uuid)
        if let old = store.update(ObjectIdentifier(ch), data) {
            print("[\(Fmt.time(when))] \(who)  ZMIANA")
            print("      bylo: \(Fmt.describe(old))")
            print("      jest: \(Fmt.describe(data))")
        } else {
            print("[\(Fmt.time(when))] \(who)  \(Fmt.describe(data))")
        }
    }

    // Wartosci poczatkowe - bez nich pierwsza notyfikacja nie ma sie do czego odniesc.
    for (_, chars) in tree {
        for ch in chars where ch.properties.contains(.read) {
            if let v = await client.read(ch) { store.set(ObjectIdentifier(ch), v) }
        }
    }

    for (service, chars) in tree {
        for ch in chars where ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
            // --char pozwala subskrybowac JEDNA charakterystyke. Major V odrzuca
            // subskrypcje calego serwisu naraz - warto sprawdzic, czy pojedyncza przejdzie.
            if let want = args.string("char"),
               !ch.uuid.uuidString.uppercased().hasPrefix(want.uppercased()) { continue }
            names[ObjectIdentifier(ch)] = Zound.shortName(for: service.uuid) == "FCCD"
                ? Zound.shortName(for: ch.uuid)
                : "\(Zound.shortName(for: service.uuid))/\(Zound.shortName(for: ch.uuid))"
            do { try await client.subscribe(ch); subscribed += 1 }
            catch { print("   nie udalo sie subskrybowac \(ch.uuid): \(error.localizedDescription)") }
        }
    }

    let seconds = args.double("for", default: 180)
    print("""

    Subskrybuje \(subscribed) charakterystyk, wartosci poczatkowe wczytane.
    Nasluchuje przez \(Int(seconds))s.

    TEST 1 - przycisk M:
      nacisnij pojedynczo, odczekaj 3 s, podwojnie, odczekaj 3 s, przytrzymaj.
      Dla porownania poruszaj pokretlem (play/pause, glosnosc).

    TEST 2 - podsluch na zywo:
      wlacz Bluetooth w telefonie i w aplikacji Marshall przelacz po kolei
      interaction sounds, battery preservation, timer, tryb przycisku M.
      Jesli sluchawki utrzymaja oba polaczenia, zobaczysz tu kazda zmiane od razu
      - i mamy cale mapowanie bez robienia dwudziestu zrzutow.

    """)
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    print("\nKoniec nasluchu.")
    client.disconnect()
}

/// Eksperyment: czy sluchawki potrafia raportowac nacisniecia przycisku do hosta.
///
/// Idzie kanalem RACE Airohy - niezaleznym od charakterystyk Zounda, ktore
/// odrzucaja subskrypcje. ZMIERZONE: kanal dziala, urzadzenie odpowiada.
///
/// Status w odpowiedzi to pierwszy bajt payloadu:
///   0x00 - sukces
///   0x02 - zly parametr / zla dlugosc (tak odpowiedzialo na GET_FWVERSION bez parametru)
///   0xFF - odrzucone (tak odpowiedzialo na ENABLE_KEY_EVENT z key_event_id=0xFFFF)
func cmdKeyEvents(_ client: BLEClient, _ args: Args) async throws {
    let target = try await findDevice(client, args: args)
    let tree = try await connectAndDiscover(client, target)

    let all = tree.flatMap { $0.1 }
    guard let wr = all.first(where: { $0.uuid == Race.writeCharacteristic }),
          let nt = all.first(where: { $0.uuid == Race.notifyCharacteristic }) else {
        print("Nie znaleziono kanalu Airohy na tym urzadzeniu."); return
    }

    let inbox = Inbox()
    let verbose = !args.bool("sweep")

    client.onNotify = { ch, data, when in
        guard ch.uuid == Race.notifyCharacteristic else { return }
        inbox.add(data)
        if verbose {
            print("[\(Fmt.time(when))] \(Race.describe(data))")
            print("             surowo: \(Fmt.hex(data))")
        }
    }

    try await client.subscribe(nt)

    /// Wysyla komende i zbiera to, co przyszlo w odpowiedzi.
    @discardableResult
    func send(_ id: UInt16, _ payload: [UInt8] = [], wait: Double = 0.4) async -> [Race.Frame] {
        _ = inbox.drain()
        let pkt = Race.packet(id: id, payload: payload)
        if verbose { print("-> \(Race.knownName(id) ?? String(format: "0x%04X", id)): \(Fmt.hex(pkt))") }
        try? await client.write(pkt, to: wr)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        return inbox.drain().compactMap { Race.parse($0) }
    }

    // --- Sonda: GET_FWVERSION Z parametrem agent_or_client, ktorego brakowalo. ---
    print("Kanal RACE otwarty. Sonda GET_FWVERSION(agent=0)...\n")
    let probe = await send(Race.GET_FWVERSION, [0x00])
    if let f = probe.first(where: { $0.id == Race.GET_FWVERSION }), f.payload.first == 0x00 {
        let ver = f.payload.dropFirst(3)
        print("   wersja firmware: \(String(decoding: ver, as: UTF8.self))  (status 0x00 = OK)\n")
    } else if probe.isEmpty {
        print("   brak odpowiedzi - urzadzenie nie odpowiada na kanale RACE.")
        client.disconnect(); return
    }

    await send(Race.ENABLE_FW_NOTIFY, [0x01])

    // --- Przemiatanie key_event_id ---
    //
    // Wartosci nie ma ani w XML, ani w binarce. Wlaczanie raportowania zdarzen
    // jest nieszkodliwe, wiec zamiast zgadywac - probujemy po kolei i patrzymy,
    // ktora wartosc zwroci status 0x00 zamiast 0xFF.
    if args.bool("sweep") {
        let maxID = UInt16(args.double("sweep-max", default: 63))
        print("""
        UWAGA: ta komenda WYKONUJE akcje MMI, nie wlacza raportowania.
        Przemiatanie moze wywolac dowolna z nich - zmierzone: 0x0018 wylacza sluchawki.
        Znane szkodliwe wartosci sa pomijane, ale reszta jest nieznana.

        Przemiatam key_event_id 0x0000..0x\(String(format: "%04X", maxID))...

        """)
        var accepted: [UInt16] = []
        let harmful = Race.knownHarmfulParameters[Race.ENABLE_KEY_EVENT] ?? []
        for id in 0...maxID {
            if harmful.contains(id) {
                print(String(format: "   0x%04X  POMINIETE (znany skutek uboczny)", id))
                continue
            }
            let frames = await send(Race.ENABLE_KEY_EVENT,
                                    [UInt8(id & 0xFF), UInt8(id >> 8)], wait: 0.25)
            guard let f = frames.first(where: { $0.id == Race.ENABLE_KEY_EVENT }),
                  let status = f.payload.first else { continue }
            if status == 0x00 {
                accepted.append(id)
                print(String(format: "   0x%04X  PRZYJETE (status 0x00)", id))
            }
        }
        if accepted.isEmpty {
            print("""

            Zadna wartosc z zakresu nie zostala przyjeta - wszystkie odrzucone.
            Firmware Major V najprawdopodobniej nie implementuje ENABLE_KEY_EVENT,
            mimo ze komenda jest rozpoznawana przez parser.

            Sprobuj szerszego zakresu:  ./mr keyevents --sweep --sweep-max 255
            """)
            client.disconnect(); return
        }
        print("""

        Przyjete wartosci: \(accepted.map { String(format: "0x%04X", $0) }.joined(separator: ", "))

        NIE wlaczam zadnej automatycznie. Ta komenda nie wlacza raportowania zdarzen,
        tylko wykonuje akcje MMI o podanym numerze - wartosc 0x0018 wylacza sluchawki.
        Kazda przyjeta wartosc cos robi, a nie wiadomo co.

        Zeby wyslac konkretna swiadomie:  ./mr keyevents --key-id <N>
        """)
        client.disconnect(); return
    } else {
        let keyID = UInt16(args.double("key-id", default: 0))
        if (Race.knownHarmfulParameters[Race.ENABLE_KEY_EVENT] ?? []).contains(keyID),
           !args.bool("i-know-what-im-doing") {
            print("key_event_id 0x\(String(format: "%04X", keyID)) ma znany skutek uboczny (wylacza sluchawki).")
            print("Jesli naprawde chcesz, dodaj --i-know-what-im-doing.")
            client.disconnect(); return
        }
        let frames = await send(Race.ENABLE_KEY_EVENT, [UInt8(keyID & 0xFF), UInt8(keyID >> 8)])
        if let f = frames.first(where: { $0.id == Race.ENABLE_KEY_EVENT }), f.payload.first != 0x00 {
            print("""

            Odrzucone (status 0x\(String(format: "%02X", f.payload.first ?? 0))).
            Zamiast zgadywac pojedyncze wartosci, przemiec zakres:

                ./mr keyevents --sweep

            """)
        }
    }

    let seconds = args.double("for", default: 120)
    print("""

    Nasluchuje \(Int(seconds))s.

    NACISNIJ TERAZ PRZYCISK M - pojedynczo, odczekaj 3 s, podwojnie, odczekaj,
    przytrzymaj. Potem poruszaj pokretlem dla porownania.

    Szukamy powiadomienia (typ 0x5C), ktore pojawia sie w momencie nacisniecia.

    """)
    client.onNotify = { ch, data, when in
        guard ch.uuid == Race.notifyCharacteristic else { return }
        print("[\(Fmt.time(when))] \(Race.describe(data))")
        print("             surowo: \(Fmt.hex(data))")
    }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    print("\nKoniec nasluchu.")
    client.disconnect()
}

/// Odczytuje i ustawia akcje przycisku M.
///
/// Bezpieczniejsze niz `write` recznie: zachowuje ramke (pierwsze 4 bajty
/// charakterystyki 0000000D) i podmienia wylacznie ostatni bajt - akcje.
/// Dzieki temu nie da sie przypadkiem wpisac smieci.
func cmdMButton(_ client: BLEClient, _ args: Args) async throws {
    let charPrefix = "0000000D"

    if args.bool("list") || args.positional.first == "list" {
        print("Akcje (wartosc na drucie = indeks, potwierdzone pomiarem):\n")
        for (i, a) in Zound.buttonActionNames.enumerated() {
            var mark = ""
            if ["noAction", "defaultVoiceAssistant", "eqSlotsToggle", "spotifyTapGoCommand"].contains(a) {
                mark = "   <- potwierdzone, pokazywane przez oficjalna aplikacje"
            }
            if a == "playPauseOnly" { mark = "   <- kandydat na \"wznow Apple Music\"" }
            print(String(format: "  0x%02X  %@%@", i, a, mark))
        }
        return
    }

    let target = try await findDevice(client, args: args)
    let tree = try await connectAndDiscover(client, target)

    guard let ch = tree.flatMap({ $0.1 })
        .first(where: { $0.uuid.uuidString.uppercased().hasPrefix(charPrefix) }) else {
        print("Nie znaleziono charakterystyki \(charPrefix)."); return
    }

    guard let current = await client.read(ch), current.count >= 2 else {
        print("Nie udalo sie odczytac biezacej wartosci."); return
    }
    let currentAction = current[current.index(before: current.endIndex)]
    let currentName = Int(currentAction) < Zound.buttonActionNames.count
        ? Zound.buttonActionNames[Int(currentAction)] : "nieznana"
    print("Teraz: \(Fmt.hex(current))  -> akcja 0x\(String(format: "%02X", currentAction)) = \(currentName)")

    guard let wanted = args.positional.first else {
        print("\nZeby zmienic:  ./mr mbutton <nazwa-akcji>       (lista: ./mr mbutton list)")
        client.disconnect(); return
    }
    guard let value = Zound.actionValue(named: wanted) else {
        print("Nieznana akcja \"\(wanted)\". Lista: ./mr mbutton list")
        client.disconnect(); return
    }

    // --probe: format zapisu rozni sie od formatu odczytu (urzadzenie odrzucilo
    // ramke 1:1 z odczytu bledem ATT 0x0D "invalid length"). Probujemy po kolei
    // sensowne ksztalty i patrzymy, ktory przejdzie.
    //
    // To jest bezpieczne w tym sensie, ze odrzucony zapis nie zmienia niczego,
    // a po udanym natychmiast przywracamy stan wyjsciowy. Nie dotykamy przy tym
    // charakterystyki 00000034 (punkt kontrolny) - tam slepy zapis moglby
    // wywolac cokolwiek, lacznie z resetem.
    if args.bool("probe") {
        let original = current
        var tried = Set<String>()
        let candidates: [(String, [UInt8])] = [
            ("sam bajt akcji",                          [value]),
            ("pressType + akcja",                       [0x00, value]),
            ("buttonIdx + akcja",                       [0x01, value]),
            ("buttonIdx + pressType + akcja",           [0x01, 0x00, value]),
            ("buttonIdx=0 + pressType + akcja",         [0x00, 0x00, value]),
            ("count + buttonIdx + pressType + akcja",   [0x01, 0x01, 0x00, value]),
            ("FF + buttonIdx + pressType + akcja",      [0xFF, 0x01, 0x00, value]),
            ("ramka z odczytu bez FF",                  [0x01, 0x01, 0x00, value]),
            ("ramka z odczytu 1:1",                     Array(current.dropLast()) + [value]),
        ]

        for (name, bytes) in candidates {
            let data = Data(bytes)
            let key = Fmt.hex(data)
            if tried.contains(key) { continue }
            tried.insert(key)

            print("  proba: \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(key)")
            do {
                try await client.write(ch, data: data, withResponse: ch.properties.contains(.write))
            } catch {
                let m = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("         odrzucone: \(m)")
                continue
            }
            guard let after = await client.read(ch) else {
                print("         zapis przeszedl, ale odczyt kontrolny zawiodl"); continue
            }
            if after == original {
                print("         zapis przyjety, ale stan sie nie zmienil (zignorowany)")
                continue
            }
            print("""

                     *** DZIALA ***
                     format: \(name)
                     zapisano:   \(key)
                     odczyt po:  \(Fmt.hex(after))

                     """)
            // Natychmiastowe przywrocenie stanu wyjsciowego tym samym formatem.
            var restore = bytes
            restore[restore.count - 1] = currentAction
            try? await client.write(ch, data: Data(restore), withResponse: ch.properties.contains(.write))
            let back = await client.read(ch)
            print("Przywrocono stan wyjsciowy: \(back.map(Fmt.hex) ?? "?") (oczekiwane \(Fmt.hex(original)))")
            print("\nZeby ustawic na stale, uzyj tego formatu recznie:")
            print("  ./mr write \(charPrefix) \(key) --i-know-what-im-doing")
            client.disconnect()
            return
        }

        print("\nZaden z \(tried.count) formatow nie zadzialal. Stan bez zmian.")
        print("Nastepny krok: PacketLogger - podejrzyj, co dokladnie zapisuje oficjalna aplikacja.")
        client.disconnect()
        return
    }

    // ZMIERZONE: zapis ma format 2-bajtowy [selektor][akcja], a nie ramke z odczytu.
    // Ramka 5-bajtowa jest odrzucana bledem ATT 0x0D. Selektor bierzemy z odczytu
    // (przedostatni bajt), zeby nie zgadywac, czy to buttonIdx czy pressType -
    // na Major V i tak jest 0x00 w obu przypadkach.
    let selector = current[current.index(current.endIndex, offsetBy: -2)]
    let payload = Data([selector, value])
    print("Zapisuje: \(Fmt.hex(payload))  -> akcja 0x\(String(format: "%02X", value)) = \(Zound.buttonActionNames[Int(value)])")

    try await client.write(ch, data: payload, withResponse: ch.properties.contains(.write))
    if let after = await client.read(ch) {
        print("Po zapisie: \(Fmt.hex(after))")
        // Odczyt zwraca pelna ramke, wiec porownujemy tylko ostatni bajt.
        if after.last != value {
            print("UWAGA: urzadzenie ma akcje 0x\(String(format: "%02X", after.last ?? 0)),")
            print("a nie zapisana 0x\(String(format: "%02X", value)) - firmware ja odrzucil.")
        } else {
            print("Potwierdzone: akcja przycisku M ustawiona na \(Zound.buttonActionNames[Int(value)]).")
        }
    }
    print("\nPrzywrocenie:  ./mr mbutton \(currentName)")
    client.disconnect()
}

/// Odpytywanie zamiast notyfikacji.
///
/// Charakterystyki serwisu FCCD w Major V deklaruja NOTIFY, ale odrzucaja zapis
/// do deskryptora CCCD ("invalid attribute value length") - subskrypcja jest
/// niemozliwa. Odczyty za to dzialaja bez zarzutu, wiec czytamy je w petli
/// i pokazujemy wylacznie zmiany.
///
/// Efekt jest ten sam co podsluch na zywo: odpalasz to, rownolegle przelaczasz
/// ustawienia w aplikacji na telefonie i od razu widzisz, ktory bajt sie ruszyl.
func cmdPoll(_ client: BLEClient, _ args: Args) async throws {
    let target = try await findDevice(client, args: args)
    let tree = try await connectAndDiscover(client, target)

    let only = (args.string("only") ?? "FCCD").uppercased()
    let interval = args.double("interval", default: 1.0)
    let seconds = args.double("for", default: 300)

    // Tylko odczytywalne charakterystyki wybranego serwisu.
    var watched: [(name: String, ch: CBCharacteristic)] = []
    for (service, chars) in tree {
        guard service.uuid.uuidString.uppercased().hasPrefix(only) else { continue }
        for ch in chars where ch.properties.contains(.read) {
            watched.append((Zound.shortName(for: ch.uuid), ch))
        }
    }
    guard !watched.isEmpty else {
        print("Brak odczytywalnych charakterystyk w serwisie \(only)."); return
    }

    var last: [String: Data] = [:]
    print("\nWartosci poczatkowe (\(watched.count) charakterystyk):\n")
    for w in watched {
        if let v = await client.read(w.ch) {
            last[w.name] = v
            print("   \(w.name)  \(Fmt.describe(v))")
        }
    }

    print("""

    Odpytuje co \(interval)s przez \(Int(seconds))s. Pokazuje TYLKO zmiany.

    Teraz wlacz Bluetooth w telefonie i w aplikacji Marshall przelaczaj ustawienia
    POJEDYNCZO, z kilkusekundowa przerwa miedzy nimi:

        interaction sounds  ->  battery preservation  ->  timer wylaczania
        ->  tryb przycisku M (EQ, potem asystent, potem Spotify)

    Po kazdej zmianie zobaczysz, ktora charakterystyka sie ruszyla i jak.

    """)

    let deadline = Date().addingTimeInterval(seconds)
    var cycles = 0
    while Date() < deadline {
        for w in watched {
            guard let v = await client.read(w.ch, timeout: 4) else { continue }
            if let old = last[w.name], old != v {
                print("[\(Fmt.time(Date()))] \(w.name)  ZMIANA")
                print("      bylo: \(Fmt.describe(old))")
                print("      jest: \(Fmt.describe(v))")
                print("")
            }
            last[w.name] = v
        }
        cycles += 1
        if cycles % 30 == 0 {
            FileHandle.standardError.write("   ... \(cycles) cykli, nasluchuje\n".data(using: .utf8)!)
        }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    print("Koniec. Wykonano \(cycles) cykli odpytywania.")
    client.disconnect()
}

/// Laczy sie po kolei z kandydatami i sprawdza, czy wystawiaja serwis Zounda.
///
/// Po polaczeniu CoreBluetooth zwykle zna juz prawdziwa nazwe urzadzenia, nawet
/// jesli nie bylo jej w rozgloszeniu - wiec to jednoczesnie identyfikuje sprzet.
func cmdProbe(_ client: BLEClient, _ args: Args) async throws {
    let seconds = args.double("seconds", default: 8)
    let minRSSI = Int(args.double("min-rssi", default: -80))

    print("Skanuje \(Int(seconds))s...")
    var candidates = await client.scan(seconds: seconds)
    for p in await client.alreadyConnected()
    where !candidates.contains(where: { $0.identifier == p.identifier }) {
        candidates.append(p)
    }

    if let id = args.string("id") {
        candidates = candidates.filter { $0.identifier.uuidString.lowercased() == id.lowercased() }
        guard !candidates.isEmpty else { throw BLEError.notFound("urzadzenie o id \(id)") }
    } else {
        // Bez Apple (to cudze telefony i zegarki) i bez slabego sygnalu.
        candidates = candidates.filter { $0.looksLikeCandidate && $0.rssi >= minRSSI && $0.isConnectable }
        print("""

        Sonduje \(candidates.count) urzadzen (pominieto Apple i sygnal slabszy niz \(minRSSI) dBm).

        UWAGA: to nawiazuje polaczenie BLE z urzadzeniami w zasiegu. Sa to tylko
        polaczenia, nic nie zapisujemy - ale jesli wolisz nie dotykac cudzego sprzetu,
        uzyj --id i sonduj pojedynczo.

        """)
    }

    for c in candidates {
        let shown = c.name == "(bez nazwy)" ? c.identifier.uuidString : c.name
        print("--- \(shown)  (\(c.rssi) dBm)")
        do {
            try await client.connect(c.peripheral, timeout: 8)
            let services = try await client.discoverServices(timeout: 8)
            // Po polaczeniu nazwa zwykle jest juz znana.
            if let realName = c.peripheral.name, realName != c.name {
                print("    nazwa po polaczeniu: \(realName)")
            }
            let uuids = services.map { $0.uuid }
            if uuids.contains(Zound.service) {
                print("    *** SERWIS ZOUNDA ZNALEZIONY - to sa Twoje sluchawki ***")
                print("    ./mr dump --id \(c.identifier.uuidString) --out 00-baza.json")
            }
            for s in services {
                print("    \(s.uuid.uuidString)" + (Zound.label(for: s.uuid).map { "   (\($0))" } ?? ""))
            }
        } catch {
            let m = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("    nie udalo sie: \(m)")
        }
        await client.disconnectAndWait()
        print("")
    }
}

func cmdDiff(_ args: Args) throws {
    guard args.positional.count == 2 else {
        print("Uzycie: marshall-recon diff przed.json po.json"); return
    }
    let a = try Snapshot.read(from: args.positional[0])
    let b = try Snapshot.read(from: args.positional[1])
    let av = a.flatValues, bv = b.flatValues

    print("A: \(args.positional[0])  (\(a.note ?? "bez notatki"))")
    print("B: \(args.positional[1])  (\(b.note ?? "bez notatki"))\n")

    var changes = 0
    for key in Set(av.keys).union(bv.keys).sorted() {
        let x = av[key] ?? nil, y = bv[key] ?? nil
        guard x != y else { continue }
        changes += 1
        let label = b.label(forKey: key) ?? a.label(forKey: key)
        print("ZMIANA  \(key)" + (label.map { "   (\($0))" } ?? ""))
        print("   przed: \(x ?? "-")")
        print("   po:    \(y ?? "-")\n")
    }
    print(changes == 0
          ? "Brak roznic. Albo ustawienie nie poszlo do urzadzenia, albo trafilo w charakterystyke bez prawa READ."
          : "Roznic: \(changes)")
}

func cmdRead(_ client: BLEClient, _ args: Args) async throws {
    guard let want = args.positional.first else {
        print("Uzycie: marshall-recon read <UUID-charakterystyki>"); return
    }
    let target = try await findDevice(client, args: args)
    let tree = try await connectAndDiscover(client, target)
    for (_, chars) in tree {
        for ch in chars where ch.uuid.uuidString.lowercased().hasPrefix(want.lowercased()) {
            let v = await client.read(ch)
            print("\(ch.uuid.uuidString): \(v.map(Fmt.describe) ?? "(odczyt nieudany)")")
        }
    }
    client.disconnect()
}

func cmdWrite(_ client: BLEClient, _ args: Args) async throws {
    guard args.positional.count == 2 else {
        print("Uzycie: marshall-recon write <UUID> <hex> --i-know-what-im-doing"); return
    }
    guard args.bool("i-know-what-im-doing") else {
        print("""
        Zapis jest zablokowany bez flagi --i-know-what-im-doing.

        Powod: nie znasz jeszcze mapowania charakterystyk. Slepy zapis moze trafic
        w punkt kontrolny DFU albo w ustawienie fabryczne. Najpierw zrob dump i diff,
        ustal co jest czym, i zapisuj tylko tam, gdzie wiesz, jaki jest format.
        """)
        return
    }
    guard let payload = Fmt.data(fromHex: args.positional[1]) else {
        print("Zly hex."); return
    }
    let want = args.positional[0]
    let target = try await findDevice(client, args: args)
    let tree = try await connectAndDiscover(client, target)

    for (_, chars) in tree {
        for ch in chars where ch.uuid.uuidString.lowercased().hasPrefix(want.lowercased()) {
            let before = await client.read(ch)
            print("przed: \(before.map(Fmt.describe) ?? "-")")
            let withResponse = ch.properties.contains(.write)
            try await client.write(ch, data: payload, withResponse: withResponse)
            print("zapisano \(Fmt.hex(payload)) (\(withResponse ? "z odpowiedzia" : "bez odpowiedzi"))")
            let after = await client.read(ch)
            print("po:    \(after.map(Fmt.describe) ?? "-")")
        }
    }
    client.disconnect()
}

func cmdReference() {
    print("""
    Co wiadomo z binarki aplikacji Marshall 3.8.6
    =============================================

    Serwis GATT:   \(Zound.service.uuidString)
    Wzorzec UUID:  ........\(Zound.uuidSuffix)

    Znalezione identyfikatory charakterystyk (\(Zound.knownCharacteristicIDs.count)):
    \(Zound.knownCharacteristicIDs.joined(separator: " "))

    Nazwy charakterystyk w kolejnosci deklaracji (mapowanie na UUID NIEZNANE):
    """)
    for (i, n) in Zound.characteristicNamesInDeclarationOrder.enumerated() {
        let mark = ["actionButtonEvent", "actionButtonConfiguration", "uiSounds",
                    "batteryPreservation", "autoOffTimeSettings", "firmwareRevision"].contains(n) ? "  <== SZUKANE" : ""
        print("  " + (i < 10 ? " " : "") + "\(i)  " + n + mark)
    }
    print("\n  buttonIdx:  " + Zound.buttonIndexNames.joined(separator: ", "))
    print("  pressType:  " + Zound.pressTypeNames.joined(separator: ", "))
    print("\n  buttonAction (kolejnosc deklaracji = prawdopodobny rawValue):")
    for (i, a) in Zound.buttonActionNames.enumerated() {
        print("  " + (i < 10 ? " " : "") + "\(i)  " + a)
    }
}

func usage() {
    print("""
    marshall-recon - rozpoznanie protokolu BLE sluchawek Marshall

      scan   [--seconds N]
             Wypisz wszystkie widoczne urzadzenia BLE.

      dump   [--id <UUID>] [--out plik.json] [--note "opis"] [--only FCCD] [--desc]
             Polacz, odkryj cala strukture GATT, odczytaj kazda charakterystyke.

      watch  [--for 120] [--char 0000000C]
             Subskrybuj wszystkie charakterystyki NOTIFY i wypisuj zdarzenia.
             Tym testujesz, czy przycisk M wysyla actionButtonEvent.

      poll   [--only FCCD] [--interval 1.0] [--for 300]
             Czyta charakterystyki w petli i pokazuje tylko zmiany.
             Uzyj zamiast watch tam, gdzie urzadzenie odrzuca subskrypcje.

      mbutton [nazwa-akcji | list] [--probe]
             Odczytaj albo ustaw akcje przycisku M. Zachowuje ramke,
             podmienia tylko bajt akcji.

      keyevents [--sweep [--sweep-max 63]] [--key-id N] [--for 120]
             Kanalem RACE Airohy wlacza raportowanie zdarzen klawiszy
             i nasluchuje. Test: czy przycisk M da sie przechwycic.

      probe  [--id <UUID>] [--min-rssi -80]
             Polacz sie z kandydatami i sprawdz, ktory wystawia serwis Zounda.
             Uzyj, gdy sluchawki nie pokazuja nazwy w skanie.

      diff   przed.json po.json
             Porownaj dwa zrzuty i pokaz, ktore charakterystyki sie zmienily.

      read   <UUID> [--name marshall]
      write  <UUID> <hex> --i-know-what-im-doing

      reference
             Wypisz wszystko, co wyciagnieto z binarki aplikacji.

    Wspolne flagi: --name <fragment nazwy>, --id <UUID peryferala>, --seconds <czas skanu>
    """)
}

// MARK: - Wejscie

@main
struct Main {
    static func main() async {
        let args = Args(CommandLine.arguments)
        if args.command == "help" || args.command == "--help" { usage(); return }
        if args.command == "reference" { cmdReference(); return }
        if args.command == "env" {
            // Diagnostyka TCC: czy proces widzi swoj bundel i klucz uprawnienia.
            print("Bundle.main.bundlePath : \(Bundle.main.bundlePath)")
            print("bundleIdentifier       : \(Bundle.main.bundleIdentifier ?? "(brak)")")
            let key = "NSBluetoothAlwaysUsageDescription"
            print("\(key): \(Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "(BRAK - macOS ubije proces)")")
            print("executablePath         : \(Bundle.main.executablePath ?? "-")")
            return
        }
        if args.command == "mbutton" && (args.bool("list") || args.positional.first == "list") {
            print("Akcje przycisku (wartosc na drucie = indeks, potwierdzone pomiarem):\n")
            for (i, a) in Zound.buttonActionNames.enumerated() {
                var mark = ""
                if ["noAction", "defaultVoiceAssistant", "eqSlotsToggle", "spotifyTapGoCommand"].contains(a) {
                    mark = "   <- potwierdzone pomiarem"
                }
                if a == "playPauseOnly" { mark = "   <- kandydat na \"wznow Apple Music\"" }
                print(String(format: "  0x%02X  %@%@", i, a, mark))
            }
            return
        }
        if args.command == "diff" {
            do { try cmdDiff(args) } catch { fail(error) }
            return
        }

        // Wyjscie bez buforowania - gdy TCC ubije proces (SIGABRT), zbuforowane
        // linie przepadaja i uzytkownik widzi pusty ekran.
        setvbuf(stdout, nil, _IONBF, 0)

        // Ostrzezenie zawczasu: nie da sie tego przechwycic, bo system wysyla
        // SIGABRT z zewnatrz. Jedyne, co mozemy, to powiedziec o tym WCZESNIEJ.
        FileHandle.standardError.write("""
        (jesli program zaraz zniknie bez slowa: to macOS odmawia dostepu do Bluetooth
         - patrz README, sekcja "Uprawnienie Bluetooth")

        """.data(using: .utf8)!)

        let client = BLEClient()
        do {
            try await client.waitUntilReady()
            switch args.command {
            case "scan":  try await cmdScan(client, args)
            case "dump":  try await cmdDump(client, args)
            case "watch": try await cmdWatch(client, args)
            case "probe": try await cmdProbe(client, args)
            case "poll":  try await cmdPoll(client, args)
            case "mbutton": try await cmdMButton(client, args)
            case "keyevents": try await cmdKeyEvents(client, args)
            case "read":  try await cmdRead(client, args)
            case "write": try await cmdWrite(client, args)
            default:      usage()
            }
        } catch {
            fail(error)
        }
        exit(0)
    }

    static func fail(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write("\nBLAD: \(msg)\n".data(using: .utf8)!)
        exit(1)
    }
}
