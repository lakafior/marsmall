import Foundation
import CoreBluetooth

/// Wszystko, co udalo sie odzyskac z binarki `MarshallBluetooth®` (wersja 3.8.6).
///
/// Zrodla:
///  - literaly UUID z sekcji __TEXT (regex na wzorzec `........-1337-1dea-feed-c0ffee70c0de`)
///  - nazwy przypadkow enumow z metadanych refleksji Swifta (sekcja __swift5_reflstr)
///
/// UWAGA co do statusu wiedzy:
///  - lista UUID-ow: PEWNA (to doslowne literaly z binarki)
///  - lista nazw charakterystyk: PEWNA (dosłowne nazwy przypadkow enuma)
///  - przypisanie "nazwa -> ktory UUID": NIEZNANE. Switch mapujacy jedno na drugie
///    jest w stripped Swiftcie i nie zostal rozplatany. Wypelnij to empirycznie,
///    patrz README (PacketLogger albo metoda roznicowa).
enum Zound {

    // MARK: - Serwisy

    /// Baza UUID-ow wlasnego protokolu Zounda. Kazda charakterystyka to
    /// 8 cyfr identyfikatora + ten sufiks.
    static let uuidSuffix = "-1337-1dea-feed-c0ffee70c0de"

    /// Glowny serwis GATT nowych urzadzen Zound/Marshall (m.in. Major V = kryptonim "plant").
    static let service = CBUUID(string: "DEAD0001\(uuidSuffix)")

    /// Sciezka alternatywna w binarce (gdy funkcja pod 0x1005aa7e0 zwraca false).
    /// Zdekodowane ze stalej `mov w0,#0x4141; movk w0,#0x3332,lsl#16` jako maly string Swifta.
    /// NIEPEWNE - potraktuj jako hipoteze, zweryfikuj skanem.
    static let legacyServiceGuess = CBUUID(string: "AA23")

    /// Standardowe serwisy SIG, ktorych aplikacja tez uzywa.
    static let deviceInformationService = CBUUID(string: "180A")
    static let batteryService = CBUUID(string: "180F")

    /// Serwis Tymphany (TAPlatform) - dla kompletnosci; Major V go NIE uzywa.
    static let tymphanyService = CBUUID(string: "00001100-D102-11E1-9B23-00025B00A5A5")

    // MARK: - Co faktycznie wystawia Major V (zmierzone, nie wywnioskowane)
    //
    // Sonda `./mr probe` na prawdziwych sluchawkach "MAJOR V [LE]" pokazala:
    //
    //     180F                                   Battery (SIG)
    //     180A                                   Device Information (SIG)
    //     5052494D-2DAB-0341-6972-6F6861424C45   Airoha
    //     FE2C                                   Google Fast Pair
    //     FCCD                                   producenta, nieznany
    //
    // Serwisu DEAD0001 (Zound) NIE MA. Major V idzie stosem Airohy, nie
    // wlasnym protokolem GATT Zounda - wbrew temu, co sugerowala obecnosc
    // kryptonimu `plant` w enumie urzadzen obok charakterystyk Zounda.
    // Tamten enum wylicza wszystkie urzadzenia, nie tylko te na tym protokole.

    /// Serwis BLE SDK Airohy. Bajty UUID-a to ASCII: "PRIM-..AirohaBLE".
    /// Airoha uzywa tego jako kanalu dla swojego protokolu RACE.
    static let airohaService = CBUUID(string: "5052494D-2DAB-0341-6972-6F6861424C45")

    /// Google Fast Pair - standard, sluzy do szybkiego parowania z Androidem.
    /// Dla nas bez znaczenia.
    static let googleFastPairService = CBUUID(string: "FE2C")

    /// 16-bitowy UUID czlonkowski SIG przypisany Zoundowi.
    /// ZMIERZONE: to pod nim Major V wystawia charakterystyki protokolu Zounda
    /// (`000000NN-1337-1DEA-FEED-C0FFEE70C0DE`) - nie pod DEAD0001.
    static let zoundServiceOnMajorV = CBUUID(string: "FCCD")

    /// Charakterystyki Zounda faktycznie obecne na Major V (firmware 6.4.9),
    /// z flagami tak, jak je zglosilo urzadzenie.
    ///
    /// Wszystkie odczyty tych charakterystyk zawiodly przy niesparowanym Macu -
    /// prawdopodobnie wymagaja szyfrowanego (zbondowanego) polaczenia.
    static let majorVCharacteristics: [(id: String, props: String, hypothesis: String)] = [
        ("00000001", "read notify",       ""),
        ("00000007", "read write notify", ""),
        ("00000008", "read",              "tylko odczyt - moze byc cos statycznego"),
        ("00000009", "read write notify", ""),
        ("0000000A", "read notify",       "bez zapisu - stan raportowany przez urzadzenie"),
        ("0000000B", "read write notify", ""),
        ("0000000C", "notify",            "JEDYNA tylko-notify -> glowny kandydat na actionButtonEvent"),
        ("0000000D", "read write notify", ""),
        ("00000017", "read write notify", ""),
        ("0000001B", "read write notify", ""),
        ("0000002F", "read write notify", ""),
        ("00000032", "read write notify", ""),
        ("00000034", "write notify",      "zapis+notify bez odczytu -> wyglada na punkt kontrolny"),
    ]

    // MARK: - Charakterystyki

    /// Wszystkie 8-cyfrowe identyfikatory znalezione w binarce jako literaly.
    /// To pelna pula charakterystyk protokolu (36 sztuk).
    static let knownCharacteristicIDs: [String] = [
        "00000003", "00000007", "00000009", "0000000A", "0000000B", "0000000C",
        "0000000D", "0000000F", "00000013", "00000014", "00000016", "00000017",
        "00000018", "00000019", "0000001A", "0000001B", "0000001C", "0000001D",
        "0000001E", "0000001F", "00000025", "00000027", "00000028", "0000002F",
        "00000030", "00000032", "00000033", "00000034", "00000035", "00000036",
        "00000037", "00000038", "0000003A", "00000044", "00000045", "00000048",
    ]

    static var knownCharacteristics: [CBUUID] {
        knownCharacteristicIDs.map { CBUUID(string: $0 + uuidSuffix) }
    }

    /// Nazwy przypadkow enuma charakterystyk, W KOLEJNOSCI DEKLARACJI w zrodle.
    /// Indeks w tej tablicy to NIE jest UUID - to tylko kolejnosc, w jakiej
    /// zadeklarowano przypadki. Sluzy jako lista "czego szukamy".
    ///
    /// Interesujace nas pozycje sa oznaczone komentarzem.
    static let characteristicNamesInDeclarationOrder: [String] = [
        "batteryLevel",                          // 0
        "leftBatteryLevel",                      // 1
        "rightBatteryLevel",                     // 2
        "caseBatteryLevel",                      // 3
        "batteryLevelStatus",                    // 4
        "modelNumber",                           // 5
        "serialNumber",                          // 6
        "firmwareRevision",                      // 7   <- potrzebne do "software updates" (tylko odczyt wersji)
        "graphicalEqualizer",                    // 8
        "actionButtonEvent",                     // 9   <-- KLUCZOWE: NOTIFY, zdarzenia nacisniecia przycisku
        "actionButtonConfiguration",             // 10  <-- KLUCZOWE: mapowanie (przycisk, typ nacisniecia) -> akcja
        "audioControl",                          // 11
        "audioNowPlaying",                       // 12
        "trippleBatteryLevel",                   // 13
        "ancConfiguration",                      // 14
        "ancConfigurationTransparencyLevel",     // 15
        "ancConfigurationNoiseCancellingLevel",  // 16
        "ecoCharging",                           // 17
        "equalizerSettings",                     // 18
        "equalizerSettingsCustomPreset",         // 19
        "uiSounds",                              // 20  <-- FUNKCJA 2: interaction sounds
        "touchLock",                             // 21
        "uiLanguage",                            // 22
        "rename",                                // 23
        "roomPlacement",                         // 24
        "volume",                                // 25
        "audioSource",                           // 26
        "toneControl",                           // 27
        "nightMode",                             // 28
        "partyMode",                             // 29
        "wearSensorStatus",                      // 30
        "wearSensorAction",                      // 31
        "batteryPreservation",                   // 32  <-- FUNKCJA 3
        "autoOffTimeSettings",                   // 33  <-- FUNKCJA 4: power off timer
        "bluetoothConnectionControl",            // 34
        "soundStage",                            // 35
        "dynamicAudio",                          // 36
        "broadcastScanner",                      // 37
        "broadcastAudioScanControlPoint",        // 38
        "broadcastReceiveState",                 // 39
        "broadcastShareControl",                 // 40
        "usbConfiguration",                      // 41
        "audioInputConfig",                      // 42
        "ledIntensity",                          // 43
        "audioFeatureConfig",                    // 44
        "mac",                                   // 45
    ]

    // MARK: - Model przycisku

    /// Struktura `buttonMapping` z binarki: { buttonIdx, pressType, buttonAction }.
    /// Obok niej wystepuja pola: schemeFirst, schemeSecond, schemeType,
    /// numberOfButtons, numberOfEventTypes - czyli charakterystyka
    /// `actionButtonConfiguration` niesie CALA TABELE, nie pojedynczy tryb.

    /// Ktory fizyczny przycisk. Kolejnosc deklaracji = prawdopodobnie rawValue 0,1.
    static let buttonIndexNames = ["mButton", "ancButton"]

    /// Typ nacisniecia. Kolejnosc deklaracji = prawdopodobnie rawValue 0...4.
    static let pressTypeNames = [
        "singlePress", "doublePress", "triplePress", "longPress", "singlePressAndHold",
    ]

    /// Akcje przycisku. Indeks w tej tablicy to **wartosc na drucie** - POTWIERDZONE
    /// pomiarem na Major V (firmware 6.4.9): przelaczanie trybu przycisku M
    /// w oficjalnej aplikacji dalo dokladnie te wartosci w ostatnim bajcie
    /// charakterystyki 0000000D:
    ///
    ///     0x00 -> "do nothing"       = noAction
    ///     0x01 -> "voice assistant"  = defaultVoiceAssistant
    ///     0x08 -> "equalizer"        = eqSlotsToggle
    ///     0x09 -> "Spotify Tap"      = spotifyTapGoCommand
    ///
    /// Cztery na cztery zgodnie z kolejnoscia deklaracji enuma z binarki, wiec
    /// pozostale wartosci mozna uznac za wiarygodne. Osobna sprawa jest, czy
    /// firmware Major V realizuje kazda z nich - to trzeba sprawdzic po kolei.
    static let buttonActionNames = [
        "noAction",                                      // 0
        "defaultVoiceAssistant",                         // 1
        "googleVoiceAssistantBisto",                     // 2
        "equalizerPresetsToggle",                        // 3
        "playbackOnlyTransparencyToggle",                // 4
        "playbackOnlyNoiseCancellingTransparencyToggle", // 5
        "noiseCancellingTransparencyToggle",             // 6
        "playbackOnlyNoiseCancellingToggle",             // 7
        "eqSlotsToggle",                                 // 8
        "spotifyTapGoCommand",                           // 9
        "volumeUp",                                      // 10
        "volumeDown",                                    // 11
        "playAndPauseAnswerEndCall",                     // 12
        "skipForwardRejectCall",                         // 13
        "skipBack",                                      // 14
        "rejectCall",                                    // 15
        "adidasRunningStartStopRun",                     // 16
        "adidasRunningPauseResumeRun",                   // 17
        "playPauseOnly",                                 // 18  <-- kandydat pod "wznow Apple Music"
        "skipForwardAnswerEndCall",                      // 19
        "soundstage",                                    // 20
        "soundImage",                                    // 21
        "strobe",                                        // 22
        "mute",                                          // 23
    ]

    /// Wartosc na drucie dla nazwy akcji.
    static func actionValue(named n: String) -> UInt8? {
        buttonActionNames.firstIndex { $0.lowercased() == n.lowercased() }.map(UInt8.init)
    }

    /// Wartosci, ktore aplikacja pokazuje w ekranie M-Button dla Major V.
    /// (enum MButtonMode z binarki - osobny, wezszy niz buttonAction)
    static let mButtonModeNames = [
        "notDefined", "eq", "googleAssistant", "nativeAssistant", "spotifyTap",
    ]

    // MARK: - Pomocnicze

    /// Czytelna nazwa dla UUID-a, jesli to cos standardowego albo znany serwis.
    static func label(for uuid: CBUUID) -> String? {
        let s = uuid.uuidString.uppercased()
        switch s {
        case service.uuidString.uppercased():   return "Zound - glowny serwis"
        case "180A":                             return "Device Information (SIG)"
        case "180F":                             return "Battery (SIG)"
        case "2A19":                             return "Battery Level (SIG)"
        case "2A24":                             return "Model Number (SIG)"
        case "2A25":                             return "Serial Number (SIG)"
        case "2A26":                             return "Firmware Revision (SIG)"
        case "2A27":                             return "Hardware Revision (SIG)"
        case "2A29":                             return "Manufacturer Name (SIG)"
        case "1800", "1801":                     return "GAP/GATT (SIG)"
        case "FE2C":                             return "Google Fast Pair"
        case "FCCD":                             return "Zound (charakterystyki protokolu)"
        case airohaService.uuidString.uppercased(): return "Airoha (kanal RACE)"
        default:
            if s.hasSuffix(uuidSuffix.uppercased()) { return "Zound - charakterystyka" }
            if s.hasSuffix("-2DAB-0341-6972-6F6861424C45") || s.hasSuffix("-6972-6F6861424C45") {
                return "Airoha" + (asciiOfUUID(uuid).map { " \"\($0)\"" } ?? "")
            }
            return asciiOfUUID(uuid).map { "UUID jako ASCII: \"\($0)\"" }
        }
    }

    /// Skrocona nazwa do wydrukow: dla charakterystyk Zounda same 8 cyfr
    /// identyfikatora zamiast calego 128-bitowego UUID-a.
    static func shortName(for uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        if s.hasSuffix(uuidSuffix.uppercased()), let head = s.split(separator: "-").first {
            return String(head)
        }
        return s
    }

    /// Producenci lubia kodowac nazwy w bajtach 128-bitowych UUID-ow
    /// (Airoha: "PRIM-..AirohaBLE"). Warto na to patrzec przy nieznanych UUID-ach.
    /// Zwraca tekst tylko, jesli wiekszosc bajtow jest drukowalna.
    static func asciiOfUUID(_ uuid: CBUUID) -> String? {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        let printable = bytes.filter { $0 >= 0x20 && $0 < 0x7f }.count
        guard printable >= 10 else { return nil }
        return String(bytes.map { $0 >= 0x20 && $0 < 0x7f ? Character(UnicodeScalar($0)) : "." })
    }
}
