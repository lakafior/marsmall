import Foundation
import CoreBluetooth

/// Zrzut stanu calego urzadzenia w jednej chwili.
///
/// To jest podstawa metody roznicowej: robisz zrzut, zmieniasz JEDNO ustawienie
/// w oficjalnej aplikacji, robisz drugi zrzut, porownujesz. Charakterystyka,
/// ktora sie zmienila, to ta, ktorej szukasz - a roznica bajtow to jej format.
struct Snapshot: Codable {
    var deviceName: String
    var identifier: String
    var capturedAt: Date
    var note: String?
    var services: [ServiceDump]

    struct ServiceDump: Codable {
        var uuid: String
        var label: String?
        var characteristics: [CharacteristicDump]
    }

    struct CharacteristicDump: Codable {
        var uuid: String
        var label: String?
        var properties: [String]
        /// Wartosc w hexie. `nil` = nie udalo sie odczytac (brak prawa READ, blad, timeout).
        var hex: String?
        /// Ta sama wartosc jako ASCII, jesli wyglada na tekst (przydatne przy nazwie/serialu).
        var ascii: String?
        /// Dlaczego odczyt sie nie udal. Tresc bledu decyduje o nastepnym kroku.
        var error: String?
    }

    func write(to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: URL(fileURLWithPath: path))
    }

    static func read(from path: String) throws -> Snapshot {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Plaska mapa "serwis/charakterystyka" -> hex, do porownywania.
    var flatValues: [String: String?] {
        var out: [String: String?] = [:]
        for s in services {
            for c in s.characteristics {
                out["\(s.uuid)/\(c.uuid)"] = c.hex
            }
        }
        return out
    }

    func label(forKey key: String) -> String? {
        guard let charUUID = key.split(separator: "/").last.map(String.init) else { return nil }
        for s in services {
            for c in s.characteristics where c.uuid == charUUID { return c.label }
        }
        return nil
    }
}

// MARK: - Formatowanie

enum Fmt {

    static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    static func data(fromHex s: String) -> Data? {
        let clean = s.replacingOccurrences(of: " ", with: "")
                     .replacingOccurrences(of: ":", with: "")
                     .replacingOccurrences(of: "0x", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out = Data()
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    /// Zwraca tekst tylko jesli dane naprawde wygladaja na drukowalny ASCII.
    static func asciiIfPrintable(_ d: Data) -> String? {
        guard !d.isEmpty else { return nil }
        let printable = d.filter { $0 >= 0x20 && $0 < 0x7f }.count
        guard Double(printable) / Double(d.count) > 0.8 else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Wiersz w stylu hexdumpa: hex + ascii + interpretacje liczbowe.
    /// Interpretacje sa wazne - wiekszosc tych charakterystyk to 1-2 bajty
    /// i od razu widac, czy to bool, enum czy minuty.
    static func describe(_ d: Data) -> String {
        var parts: [String] = [hex(d).isEmpty ? "(pusto)" : hex(d)]
        if let a = asciiIfPrintable(d) { parts.append("ascii=\"\(a)\"") }
        switch d.count {
        case 1:
            parts.append("u8=\(d[0])")
        case 2:
            let le = UInt16(d[0]) | (UInt16(d[1]) << 8)
            let be = (UInt16(d[0]) << 8) | UInt16(d[1])
            parts.append("u16le=\(le) u16be=\(be)")
        case 4:
            let le = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            parts.append("u32le=\(le)")
        default:
            break
        }
        return parts.joined(separator: "  ")
    }

    static func properties(_ p: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if p.contains(.read)                  { out.append("read") }
        if p.contains(.write)                 { out.append("write") }
        if p.contains(.writeWithoutResponse)  { out.append("writeNoResp") }
        if p.contains(.notify)                { out.append("notify") }
        if p.contains(.indicate)              { out.append("indicate") }
        if p.contains(.broadcast)             { out.append("broadcast") }
        if p.contains(.authenticatedSignedWrites) { out.append("signedWrite") }
        if p.contains(.extendedProperties)    { out.append("ext") }
        return out
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}
