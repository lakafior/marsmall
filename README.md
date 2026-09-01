# MajorLite

A small, native iOS app for the **Marshall Major V** — the settings that matter,
no analytics, no Firebase, no account.

Built on a protocol map recovered by reverse engineering the official app and
confirmed by measurement against real hardware (firmware 6.4.9, Airoha AB156x).
The derivation lives in `../MarshallRecon/NOTES.md`.

## What it does

**Editable**
- M-Button action — all 24 values the protocol carries, not just the four the
  official app offers
- Interaction sounds
- Battery preservation (off / low / medium / max)
- Auto switch-off timers (connected and paused, not connected)

**Read-only**
- Battery level
- Now playing (title, artist, date) as reported by the headphones
- Model, firmware, hardware, manufacturer, serial

## Structure

| Path | What |
|---|---|
| `Protocol/MajorV.swift` | UUIDs, action enum, value types. Pure knowledge, no logic. |
| `Protocol/Codecs.swift` | Byte decoders, write encoders, write-format memory. |
| `BLE/BLEClient.swift` | Thin async wrapper over CoreBluetooth, main queue only. |
| `BLE/DeviceStore.swift` | Observable device state, polling, typed writes. |
| `Views/` | SwiftUI. Liquid Glass, English only. |

## Two things to know before trusting it

**Pairing is required.** The Zound characteristics reject every read unless the
phone is bonded with the headphones. Pair them in Settings › Bluetooth first —
the app cannot do it for you.

**Only one write format is confirmed.** The M-Button write is verified: two bytes,
`[selector][action]`. Writing the full read frame back is rejected with ATT 0x0D.
For interaction sounds, battery preservation and the timers we know how to *read*
the value but never confirmed how the device wants it *written*, so `Codecs.swift`
offers several plausible encodings per setting. The app tries them in order, keeps
the one the device accepts, and remembers it (`WriteFormatMemory`). A rejected write
changes nothing, so the probing is safe — it just costs a few round trips the first
time you touch a setting.

If a change does not stick, the app restores the real value and tells you.

## The M-Button screen

Every action the protocol carries is listed, with its wire value. Four are marked
as supported by the official app and known to work. The other twenty are accepted
by the firmware on write but were **not** observed to do anything when the button
was pressed.

That screen exists to check that properly. Pick an action, press the M-button,
record the result. Findings persist across launches. Test with no other device
connected, so the action is not intercepted somewhere else.

## Not included

**Firmware updates.** That is a separate stack — Qualcomm GAIA, Airoha RACE FOTA,
RWCP retransmission, a DFU state machine, and firmware images from a private S3
bucket. Weeks of work and a real risk of bricking the headphones. Use the official
Marshall app for updates; this app only shows you the installed version.

**Button press events.** The headphones expose a notify-only characteristic that
looks like a button-event channel, but the firmware rejects every attempt to
subscribe (ATT 0x0D on the CCCD write, with and without another host connected).
CoreBluetooth is the only BLE API on iOS and it always writes two bytes to a CCCD,
so no iOS app can subscribe — including Marshall's own.

## Building

Open `MajorLite.xcworkspace`, set your own signing team on the `MajorLite` target,
and run on a device. Requires iOS 26.

The simulator has no Bluetooth, so it will only ever show the "not connected"
screen. Use the Xcode canvas previews in `Views/Previews.swift` to see the rest.
