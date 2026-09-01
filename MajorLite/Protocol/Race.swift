import Foundation
import CoreBluetooth

/// Airoha's RACE protocol — a second control channel, independent of the Zound
/// characteristics, talking straight to the AB156x chip.
///
/// Framing and command ids come from `command_race.xml`, shipped inside
/// `AirohaUnifyLibrary.framework` in the official Marshall app (133 commands).
///
///     [0x05][race_type][packet_len: u16le][race_id: u16le][payload…]
///                       ^^^^^^^^^^^^^^^^^ length from race_id to the end
///
/// Verified against real hardware: `GET_FWVERSION` answers with status 0x00.
enum Race {

    static let service = CBUUID(string: "5052494D-2DAB-0341-6972-6F6861424C45")
    /// "CHAR-.2AirohaBLE" — commands go here.
    static let writeCharacteristic = CBUUID(string: "43484152-2DAB-3241-6972-6F6861424C45")
    /// "CHAR-.1AirohaBLE" — responses and notifications arrive here.
    static let notifyCharacteristic = CBUUID(string: "43484152-2DAB-3141-6972-6F6861424C45")

    static let typeCommand: UInt8 = 0x5A

    /// Battery of the device itself. Request `[agent_or_client]`,
    /// response `[status][agent_or_client][battery percent]`.
    static let TWS_GET_BATTERY: UInt16 = 0x0CD6
    /// Charging state. Request `[agent_or_client]`,
    /// response `[status][agent_or_client][charge_status]`.
    static let GET_CHARGE_INFO: UInt16 = 0x0009
    /// Harmless read, used to check the channel is alive.
    static let GET_FWVERSION: UInt16 = 0x1C07

    /// Make the headphones chirp and flash. Request
    /// `[light_on_off][alert_on_off][recipient]`, response `[status][recipient]`.
    /// A setter, but a benign one — it only produces a sound.
    static let FIND_ME: UInt16 = 0x2C01
    static let FIND_ME_QUERY_STATE: UInt16 = 0x2C00

    /// Generic state accessor. Request `[module: u16]`.
    ///
    /// The response is `[module: u16][status: u8][data…]` — it echoes the module
    /// back before the status. Measured on Major V: all eight implemented modules
    /// echoed their own id, which also confirms the module numbering below.
    static let GET_MMI_ENUM: UInt16 = 0x0901

    /// Decoded GET_MMI_ENUM reply.
    struct ModuleReply {
        var module: UInt16
        var status: UInt8
        var data: [UInt8]
        var ok: Bool { status == 0 }
    }

    static func decodeModuleReply(_ payload: [UInt8]) -> ModuleReply? {
        guard payload.count >= 3 else { return nil }
        return ModuleReply(module: UInt16(payload[0]) | UInt16(payload[1]) << 8,
                           status: payload[2],
                           data: Array(payload.dropFirst(3)))
    }
    /// Request `[cap_status = 0][id = 1]`, response `[status][id][data…]`.
    static let AUDIO_FEATURE_CAPABILITY: UInt16 = 0x0E30
    /// Five-band parametric EQ, in plain units — **not in the command catalogue**,
    /// its structure was recovered by capturing what the official app sends.
    ///
    ///     [00 × 5]
    ///     [01 02][freq ×100][gain ×100][bandwidth ×100][Q ×100]   × 5 bands, i32le
    ///     [00 × 90]
    ///     [headroom ×100][headroom ×100]                          u32le
    ///
    /// **Not sufficient on its own.** Measured: the headphones accept it and report
    /// the new band values, but the sound does not change — the DSP also wants
    /// `PEQ_REALTIME` (`0x0E03`) with computed coefficients, which is not decoded.
    /// Nothing in this app sends either; the definition is kept for the record.
    static let PEQ_BANDS: UInt16 = 0x0E2B

    /// Selects the active PEQ group. Request `[module: u16][value: u8]`.
    ///
    /// The official app ends every custom-EQ edit with module 0 (PEQGroup) set to
    /// **6** — not slot 1 or 2, but a separate group that holds the custom bands.
    /// Sent with module 0 only; nothing else from the setter side of the catalogue
    /// is used.
    static let SET_MMI_ENUM: UInt16 = 0x0900
    static let modulePEQGroup: UInt16 = 0x0000
    static let peqGroupCustom: UInt8 = 6

    /// Turns firmware-pushed notifications on. Request `[on_off]`.
    static let ENABLE_FW_NOTIFY: UInt16 = 0x0006

    /// Module names for GET_MMI_ENUM, in declaration order recovered from the
    /// Airoha SDK's Swift reflection metadata. The index is the likely wire value —
    /// the same assumption held for the button action enum, where four measured
    /// values matched four for four. Still a hypothesis until measured.
    static let mmiModules = [
        "PEQGroup", "VpOnOff", "VpLanguage", "VpGet", "VpSet", "AncStatus",
        "GameMode", "GetPassThruGain", "MicSwap", "ECNREN", "AudioPath",
        "AgentBattery", "PartnerBattery", "BoxBattery", "AwsState", "StopFindMe",
    ]

    static func moduleName(_ i: Int) -> String {
        i < mmiModules.count ? mmiModules[i] : "module \(i)"
    }

    /// Every command defined here is a read. The equaliser turned out to be
    /// writable over the Zound characteristic instead, so nothing in this app
    /// writes to the chip at all — which keeps the catalogue's firmware update,
    /// flash erase and NVKEY commands well out of reach.
    ///
    /// Only getters are listed here on purpose. The same catalogue contains
    /// firmware update, flash erase and NVKEY writes — one of its commands was
    /// observed switching the headphones off outright. Nothing is sent from this
    /// app that has not been checked to be a read.
    static func packet(id: UInt16, payload: [UInt8] = []) -> Data {
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let body = u16(id) + payload
        return Data([0x05, typeCommand] + u16(UInt16(body.count)) + body)
    }

    struct Frame {
        var type: UInt8
        var id: UInt16
        var payload: [UInt8]
    }

    static func parse(_ d: Data) -> Frame? {
        let b = [UInt8](d)
        guard b.count >= 6, b[0] == 0x05 else { return nil }
        return Frame(type: b[1],
                     id: UInt16(b[4]) | UInt16(b[5]) << 8,
                     payload: Array(b.dropFirst(6)))
    }
}
