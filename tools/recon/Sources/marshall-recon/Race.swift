import Foundation
import CoreBluetooth

/// Protokol RACE firmy Airoha - drugi, zupelnie niezalezny kanal sterowania
/// obok charakterystyk Zounda pod serwisem FCCD.
///
/// Zrodlo: `Frameworks/AirohaUnifyLibrary.framework/command_race.xml` z rozpakowanej
/// aplikacji Marshalla - kompletna mapa 133 komend z identyfikatorami i formatami.
///
/// Ramka:
///
///     [0x05][race_type][packet_len: uint16][race_id: uint16][payload...]
///                       ^^^^^^^^^^^^^^^^^^ dlugosc OD race_id do konca
///
/// Typy pakietow:
///   0x5A - komenda (host -> urzadzenie)
///   0x5B - odpowiedz (urzadzenie -> host)
///   0x5C - powiadomienie (urzadzenie -> host, niepytane)
enum Race {

    // MARK: - Kanal BLE

    /// Zapis komend. Charakterystyka "CHAR-.2AirohaBLE".
    static let writeCharacteristic = CBUUID(string: "43484152-2DAB-3241-6972-6F6861424C45")
    /// Odbior odpowiedzi i powiadomien. Charakterystyka "CHAR-.1AirohaBLE".
    /// Ta subskrybuje sie bez problemu - w przeciwienstwie do charakterystyk Zounda.
    static let notifyCharacteristic = CBUUID(string: "43484152-2DAB-3141-6972-6F6861424C45")

    // MARK: - Komendy

    static let typeCommand: UInt8 = 0x5A
    static let typeResponse: UInt8 = 0x5B
    static let typeNotification: UInt8 = 0x5C

    /// Odczyt wersji firmware. Nieszkodliwa - uzywamy jej do sprawdzenia,
    /// czy w ogole poprawnie skladamy ramke (i z ktora kolejnoscia bajtow).
    static let GET_FWVERSION: UInt16 = 0x1C07

    /// Wlaczenie powiadomien z firmware. Payload: [on_off: uint8]
    static let ENABLE_FW_NOTIFY: UInt16 = 0x0006

    /// Payload: [key_event_id: uint16]
    ///
    /// UWAGA - nazwa myli. ZMIERZONE na Major V: ta komenda nie wlacza
    /// raportowania zdarzen, tylko **wykonuje akcje MMI** o podanym numerze.
    /// `key_event_id = 0x0018` niezawodnie WYLACZA SLUCHAWKI.
    ///
    /// Nie przemiataj tego parametru na slepo. Kazda wartosc, ktora zwroci
    /// status 0x00, cos w urzadzeniu robi - a nie wiemy co.
    static let ENABLE_KEY_EVENT: UInt16 = 0x1101

    /// Parametry komend, o ktorych wiadomo, ze wywoluja skutki uboczne.
    /// Klucz: race_id, wartosc: zbior zakazanych wartosci pierwszego parametru.
    static let knownHarmfulParameters: [UInt16: Set<UInt16>] = [
        ENABLE_KEY_EVENT: [0x0018],   // wylacza sluchawki
    ]

    /// Odczyt mapy MMI (gest -> akcja) na poziomie chipu.
    static let GET_MMI_ENUM: UInt16 = 0x0901
    /// Zapis mapy MMI. Payload: [module: uint16][parametry...]
    static let SET_MMI_ENUM: UInt16 = 0x0900

    /// Komendy, ktorych narzedzie nie wysle nawet z flaga wymuszajaca.
    /// FOTA, kasowanie pamieci, reset sprzetowy, zapis NVKEY - kazda z nich
    /// moze trwale uszkodzic sluchawki.
    static let blocked: Set<UInt16> = [
        0x0206, 0x0402, 0x0404, 0x0430, 0x0431, 0x0432, 0x0433, 0x09FD,
        0x0A00, 0x0A01, 0x0A03, 0x0A09, 0x0A0C, 0x0A0D, 0x0E08, 0x1204,
        0x1205, 0x1C00, 0x1C02, 0x1C03, 0x1C04, 0x1C05, 0x1C06, 0x1C08,
        0x1C0A, 0x1C11, 0x1C12, 0x1C13, 0x1C14, 0x1C19, 0x1C1B, 0x2204,
    ]

    // MARK: - Skladanie i rozbieranie ramek

    /// Kolejnosc bajtow pol 16-bitowych nie jest udokumentowana w XML.
    /// Sprawdzamy ja empirycznie nieszkodliwa komenda GET_FWVERSION.
    static func packet(type: UInt8 = typeCommand, id: UInt16,
                       payload: [UInt8] = [], littleEndian: Bool = true) -> Data {
        func u16(_ v: UInt16) -> [UInt8] {
            littleEndian ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
        let body = u16(id) + payload          // packet_len liczy od race_id do konca
        return Data([0x05, type] + u16(UInt16(body.count)) + body)
    }

    struct Frame {
        var type: UInt8
        var id: UInt16
        var payload: [UInt8]

        var typeName: String {
            switch type {
            case typeCommand:      return "komenda"
            case typeResponse:     return "ODPOWIEDZ"
            case 0x5D:             return "ODPOWIEDZ(5D)"
            case typeNotification: return "POWIADOMIENIE"
            default:               return String(format: "0x%02X", type)
            }
        }
    }

    static func parse(_ d: Data, littleEndian: Bool = true) -> Frame? {
        let b = [UInt8](d)
        guard b.count >= 6, b[0] == 0x05 else { return nil }
        let id: UInt16 = littleEndian
            ? UInt16(b[4]) | (UInt16(b[5]) << 8)
            : (UInt16(b[4]) << 8) | UInt16(b[5])
        return Frame(type: b[1], id: id, payload: Array(b.dropFirst(6)))
    }

    static func describe(_ d: Data, littleEndian: Bool = true) -> String {
        guard let f = parse(d, littleEndian: littleEndian) else {
            return "nie-RACE: \(Fmt.hex(d))"
        }
        let name = knownName(f.id).map { " (\($0))" } ?? ""
        return String(format: "%@ id=0x%04X%@  payload=%@",
                      f.typeName, f.id, name,
                      f.payload.isEmpty ? "-" : f.payload.map { String(format: "%02x", $0) }.joined())
    }

    static func knownName(_ id: UInt16) -> String? {
        switch id {
        case GET_FWVERSION:     return "GET_FWVERSION"
        case ENABLE_FW_NOTIFY:  return "ENABLE_FW_NOTIFY"
        case ENABLE_KEY_EVENT:  return "ENABLE_KEY_EVENT"
        case GET_MMI_ENUM:      return "GET_MMI_ENUM"
        case SET_MMI_ENUM:      return "SET_MMI_ENUM"
        case 0x2C80:            return "NOTIFY_GET_MMI_STATE"
        default:                return nil
        }
    }
}
