import Foundation
import CoreBluetooth

/// Everything we know about the Marshall Major V BLE protocol.
///
/// All of this was recovered by reverse engineering: UUIDs and enum orders from the
/// official app binary, byte formats confirmed by measurement against real hardware
/// (Major V, firmware 6.4.9, Airoha AB156x).
///
/// See NOTES.md in the MarshallRecon tool for the full derivation.
enum MajorV {

    // MARK: - Services

    /// Zound's own service. Everything configurable lives here.
    /// Reading and writing these characteristics requires the host to be **bonded**
    /// with the headphones — without pairing, every read fails.
    static let zoundService = CBUUID(string: "FCCD")
    static let deviceInfoService = CBUUID(string: "180A")
    static let batteryService = CBUUID(string: "180F")

    /// Airoha's RACE channel. Not used by this app, listed for completeness.
    static let airohaService = CBUUID(string: "5052494D-2DAB-0341-6972-6F6861424C45")

    // MARK: - Characteristics

    static let zoundSuffix = "-1337-1DEA-FEED-C0FFEE70C0DE"

    /// Zound characteristics present on Major V. The names come from the official
    /// app's Swift reflection metadata; the assignment to a specific UUID was
    /// established by changing one setting at a time and diffing the bytes.
    enum Char: String, CaseIterable {
        /// Confirmed. `0100` = on, `0000` = off.
        case interactionSounds = "0000000B"
        /// Confirmed. `0004XX`, where XX is 0…3 = none/low/medium/max.
        case batteryPreservation = "0000002F"
        /// Confirmed. Header `000203` + two 4-byte entries `[id][type][seconds: u16be]`.
        case autoOffTimers = "00000032"
        /// Confirmed. Reads `FF010100XX`, XX = action. Writes take **2 bytes**.
        case mButtonAction = "0000000D"
        /// Confirmed. Records of `[field: u32be][type: u16 = 0x006A][length: u16be][UTF-8]`.
        case nowPlaying = "0000000A"
        /// Confirmed — tracks the control knob.
        case volume = "00000007"

        // Present on the device but not yet identified.
        case unknown01 = "00000001"
        case unknown07 = "00000008"
        case unknown09 = "00000009"
        /// Notify-only. Most likely `actionButtonEvent`, but the firmware rejects
        /// every attempt to subscribe (ATT 0x0D on the CCCD write), so it is
        /// unreachable from any iOS app — including Marshall's own.
        case actionButtonEvent = "0000000C"
        /// Confirmed. `FF 02 [slot] 01 01 00 [preset]` — byte 2 is the active
        /// slot (0 = slot 1, 1 = slot 2), the last byte is the preset in slot 2.
        /// Every other byte is constant.
        case equaliser = "00000017"

        case unknown1B = "0000001B"
        /// Write + notify, no read. Looks like a control point. Left alone.
        case controlPoint = "00000034"

        var uuid: CBUUID { CBUUID(string: rawValue + zoundSuffix) }

        /// Short id for display, e.g. "0000000B".
        var shortID: String { rawValue }
    }

    /// Short label for a characteristic: the eight hex digits for Zound
    /// characteristics, the plain 16-bit id for standard ones.
    static func label(for uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        if s.hasSuffix(zoundSuffix), let head = s.split(separator: "-").first {
            return String(head)
        }
        return s
    }

    /// Human name where we know one.
    static func friendlyName(for uuid: CBUUID) -> String? {
        if let c = Char.allCases.first(where: { $0.uuid == uuid }) {
            switch c {
            case .interactionSounds: return "interaction sounds"
            case .batteryPreservation: return "battery preservation"
            case .autoOffTimers: return "auto-off timers"
            case .mButtonAction: return "M-button action"
            case .nowPlaying: return "now playing"
            case .volume: return "volume"
            case .actionButtonEvent: return "button events (unreachable)"
            case .equaliser: return "equaliser"
            case .controlPoint: return "control point"
            default: return nil
            }
        }
        switch uuid.uuidString.uppercased() {
        case "2A19": return "battery level"
        case "2A24": return "model"
        case "2A25": return "serial"
        case "2A26": return "firmware"
        case "2A27": return "hardware"
        case "2A29": return "manufacturer"
        default: return nil
        }
    }

    /// Standard SIG characteristics we read for the info panel.
    enum Info {
        static let batteryLevel = CBUUID(string: "2A19")
        static let modelNumber = CBUUID(string: "2A24")
        static let serialNumber = CBUUID(string: "2A25")
        static let firmwareRevision = CBUUID(string: "2A26")
        static let hardwareRevision = CBUUID(string: "2A27")
        static let manufacturer = CBUUID(string: "2A29")
    }

    // MARK: - Button actions

    /// The full action set the protocol carries.
    ///
    /// The raw value is the on-the-wire byte. This was **proven by measurement**:
    /// switching the M-button mode in the official app produced exactly 0x00, 0x01,
    /// 0x08 and 0x09 for "do nothing", "voice assistant", "equalizer" and
    /// "Spotify Tap" — matching the declaration order of the enum found in the
    /// app binary, four for four.
    ///
    /// `isOfficial` marks the four the Marshall app exposes for Major V. The other
    /// twenty are carried by the protocol and accepted by the firmware on write,
    /// but the button was not observed to act on them. They are listed here so
    /// they can be verified by hand, one at a time.
    enum ButtonAction: UInt8, CaseIterable, Identifiable {
        case noAction = 0x00
        case voiceAssistant = 0x01
        case googleAssistantBisto = 0x02
        case equalizerPresetsToggle = 0x03
        case playbackOnlyTransparencyToggle = 0x04
        case playbackOnlyNCTransparencyToggle = 0x05
        case noiseCancellingTransparencyToggle = 0x06
        case playbackOnlyNoiseCancellingToggle = 0x07
        case equalizerSlotsToggle = 0x08
        case spotifyTap = 0x09
        case volumeUp = 0x0A
        case volumeDown = 0x0B
        case playPauseAnswerEndCall = 0x0C
        case skipForwardRejectCall = 0x0D
        case skipBack = 0x0E
        case rejectCall = 0x0F
        case runningStartStop = 0x10
        case runningPauseResume = 0x11
        case playPauseOnly = 0x12
        case skipForwardAnswerEndCall = 0x13
        case soundstage = 0x14
        case soundImage = 0x15
        case strobe = 0x16
        case mute = 0x17

        var id: UInt8 { rawValue }

        /// Exposed by the official Marshall app for Major V, so known to work.
        var isOfficial: Bool {
            switch self {
            case .noAction, .voiceAssistant, .equalizerSlotsToggle, .spotifyTap: true
            default: false
            }
        }

        var title: String {
            switch self {
            case .noAction: "Do nothing"
            case .voiceAssistant: "Voice assistant"
            case .googleAssistantBisto: "Google Assistant (Bisto)"
            case .equalizerPresetsToggle: "Equaliser presets"
            case .playbackOnlyTransparencyToggle: "Transparency (playback only)"
            case .playbackOnlyNCTransparencyToggle: "ANC / transparency (playback only)"
            case .noiseCancellingTransparencyToggle: "ANC / transparency"
            case .playbackOnlyNoiseCancellingToggle: "ANC (playback only)"
            case .equalizerSlotsToggle: "Equaliser"
            case .spotifyTap: "Spotify Tap"
            case .volumeUp: "Volume up"
            case .volumeDown: "Volume down"
            case .playPauseAnswerEndCall: "Play / pause, answer / end call"
            case .skipForwardRejectCall: "Skip forward, reject call"
            case .skipBack: "Skip back"
            case .rejectCall: "Reject call"
            case .runningStartStop: "Running: start / stop"
            case .runningPauseResume: "Running: pause / resume"
            case .playPauseOnly: "Play / pause"
            case .skipForwardAnswerEndCall: "Skip forward, answer / end call"
            case .soundstage: "Soundstage"
            case .soundImage: "Sound image"
            case .strobe: "Strobe light"
            case .mute: "Low volume mode"
            }
        }

        var hex: String { String(format: "0x%02X", rawValue) }
    }

    // MARK: - Equaliser

    /// What sits in slot 2. Slot 1 is always Marshall's own tuning.
    ///
    /// Measured: changing the mode in the official app moved exactly one byte,
    /// running 0…5 in the order the app lists them.
    enum EqualiserPreset: UInt8, CaseIterable, Identifiable {
        case marshall = 0
        case custom = 1
        case bassBoost = 2
        case midBoost = 3
        case trebleBoost = 4
        case midReduction = 5

        var id: UInt8 { rawValue }

        var title: String {
            switch self {
            case .marshall: "Marshall"
            case .custom: "Custom"
            case .bassBoost: "Bass boost"
            case .midBoost: "Mid boost"
            case .trebleBoost: "Treble boost"
            case .midReduction: "Mid reduction"
            }
        }

        var caption: String {
            switch self {
            case .marshall: "The original tuning"
            case .custom: "Five bands you set yourself"
            case .bassBoost: "Lifts the low end"
            case .midBoost: "Lifts vocals and guitars"
            case .trebleBoost: "Lifts the top end"
            case .midReduction: "Scoops the middle"
            }
        }
    }

    // MARK: - Battery preservation

    enum BatteryPreservation: UInt8, CaseIterable, Identifiable {
        case none = 0x00, low = 0x01, medium = 0x02, max = 0x03
        var id: UInt8 { rawValue }
        var title: String {
            switch self {
            case .none: "Off"
            case .low: "Low"
            case .medium: "Medium"
            case .max: "Max"
            }
        }
        var caption: String {
            switch self {
            case .none: "Charge to 100%"
            case .low: "Slightly reduced charge limit"
            case .medium: "Balanced"
            case .max: "Longest battery lifespan"
            }
        }
    }

    // MARK: - Auto-off timers

    /// One auto-off timer entry: `[id][type][seconds: u16be]`.
    ///
    /// Entry `id = 0` is the "connected and paused" timer, `id = 1` is
    /// "not connected". Both confirmed by measurement (3 h = 0x2A30,
    /// 2 h = 0x1C20, 50 min = 0x0BB8, 30 min = 0x0708, 20 min = 0x04B0).
    struct AutoOffTimer: Identifiable, Equatable {
        var id: UInt8
        var type: UInt8
        var seconds: UInt16

        var title: String {
            switch id {
            case 0: "Connected and paused"
            case 1: "Not connected"
            default: "Timer \(id)"
            }
        }

        var formatted: String { Self.format(seconds) }

        static func format(_ s: UInt16) -> String {
            if s == 0 { return "Off" }
            let m = Int(s) / 60
            if m % 60 == 0 && m >= 60 { return "\(m / 60) h" }
            if m >= 60 { return "\(m / 60) h \(m % 60) min" }
            return "\(m) min"
        }

        /// Values offered in the picker. The device was observed using 20, 30 and
        /// 50 minutes and 2 and 3 hours; the rest are plausible neighbours and may
        /// be rejected by the firmware.
        static let choices: [UInt16] = [
            300, 600, 900, 1200, 1800, 3000, 3600, 7200, 10800,
        ]
    }
}
