import Foundation

// MARK: - Reading

/// Decoders for the characteristic payloads. Every format here was confirmed by
/// watching the bytes change while toggling one setting at a time in the official app.
enum Decode {

    /// `0100` = on, `0000` = off. First byte carries the flag.
    static func interactionSounds(_ d: Data) -> Bool? {
        d.first.map { $0 != 0 }
    }

    /// `0004XX` — the last byte is the level.
    static func batteryPreservation(_ d: Data) -> MajorV.BatteryPreservation? {
        d.last.flatMap(MajorV.BatteryPreservation.init(rawValue:))
    }

    /// `00 02 03` header, then `count` entries of `[id][type][seconds: u16be]`.
    static func autoOffTimers(_ d: Data) -> [MajorV.AutoOffTimer] {
        let b = [UInt8](d)
        guard b.count >= 3 else { return [] }
        let count = Int(b[1])
        var out: [MajorV.AutoOffTimer] = []
        var i = 3
        for _ in 0..<count {
            guard i + 3 < b.count else { break }
            out.append(.init(id: b[i], type: b[i + 1],
                             seconds: UInt16(b[i + 2]) << 8 | UInt16(b[i + 3])))
            i += 4
        }
        return out
    }

    /// `FF 01 01 00 XX` — the last byte is the action.
    static func buttonAction(_ d: Data) -> MajorV.ButtonAction? {
        d.last.flatMap(MajorV.ButtonAction.init(rawValue:))
    }

    /// Records of `[field: u32be][type: u16][length: u16be][UTF-8 bytes]`.
    /// Field 1 is the title, 2 the artist or show, 3 a date, 7 a number.
    static func nowPlaying(_ d: Data) -> [Int: String] {
        let b = [UInt8](d)
        var out: [Int: String] = [:]
        var i = 0
        while i + 8 <= b.count {
            let field = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let len = Int(b[i + 6]) << 8 | Int(b[i + 7])
            let start = i + 8
            guard len > 0 else { i = start; continue }
            guard start + len <= b.count else { break }
            out[field] = String(decoding: b[start..<start + len], as: UTF8.self)
            i = start + len
        }
        return out
    }

    /// `FF 02 [slot] 01 01 00 [preset]`
    static func equaliser(_ d: Data) -> (slot: Int, preset: MajorV.EqualiserPreset)? {
        guard d.count >= 7,
              let preset = MajorV.EqualiserPreset(rawValue: d[d.index(before: d.endIndex)])
        else { return nil }
        // Bajt 2 jest 0-based, a modul PEQGroup zwraca numer slotu 1-based.
        return (Int(d[d.startIndex + 2]) + 1, preset)
    }

    static func text(_ d: Data) -> String {
        String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Writing

/// Write payloads are **not** the same shape as read payloads, and the rule is not
/// consistent between characteristics either. Every format below was confirmed by
/// capturing what the official app puts on the wire (PacketLogger) — the earlier
/// guess-and-retry approach got two of them wrong.
enum Encode {

    /// CONFIRMED. Same two bytes as the read value.
    static func interactionSounds(_ on: Bool) -> Data {
        Data([on ? 1 : 0, 0x00])
    }

    /// CONFIRMED. One byte — just the level. The read value is three bytes
    /// (`00 04 XX`), which is exactly the trap that made frame-shaped guesses fail.
    static func batteryPreservation(_ level: MajorV.BatteryPreservation) -> Data {
        Data([level.rawValue])
    }

    /// CONFIRMED. `[0x01][id][type][seconds: u16be]` — a leading field selector,
    /// then one timer entry. Observed: `0100011C20` set the connected-and-paused
    /// timer to two hours, `01010204B0` set the not-connected one to twenty minutes.
    static func autoOffTimer(_ timer: MajorV.AutoOffTimer, seconds: UInt16) -> Data {
        Data([0x01, timer.id, timer.type, UInt8(seconds >> 8), UInt8(seconds & 0xFF)])
    }

    /// CONFIRMED. `[selector][action]`, two bytes.
    static func buttonAction(_ action: MajorV.ButtonAction) -> Data {
        Data([0x00, action.rawValue])
    }

    /// CONFIRMED. `[0x00][slot]`, where slot is zero-based.
    static func equaliserSlot(_ slot: Int) -> Data {
        Data([0x00, UInt8(slot - 1)])
    }

    /// CONFIRMED. `[0x01][slot][preset]`. Slot 1 holds Marshall's fixed tuning,
    /// so the preset always targets slot 2.
    static func equaliserPreset(_ preset: MajorV.EqualiserPreset) -> Data {
        Data([0x01, 0x01, preset.rawValue])
    }
}
