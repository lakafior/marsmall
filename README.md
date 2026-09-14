# MajorLite

> **Disclaimer**: I will not continue this project, as my main goal was to reprogram M-Button which seems to be impossible, and since I bought more marshall hardware app with focus on Major series stopped to make sense. But I leave it here for anyone as it could be handy for your project.

A small, native iOS app for the **Marshall Major V** — the settings that matter,
no analytics, no Firebase, no account.

Built on a protocol map recovered by reverse engineering the official app and
confirmed by measurement against real hardware (firmware 6.4.9, Airoha AB156x).
The full derivation lives in [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

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

## Repository layout

| Path | What |
|---|---|
| `MajorLite/` | The iOS app |
| `Icon/` | App icon source and the SVG renderer that produces the three variants |
| `docs/PROTOCOL.md` | **The protocol reference.** Everything decoded about Major V — characteristics, byte formats, RACE commands, what was measured and what is inferred. |
| `docs/PEQ-SESSION-PLAN.md` | Plan for the capture session that would finish the custom equaliser |
| `tools/recon/` | macOS command-line BLE tool used to map the protocol: scan, dump, poll, snapshot, diff |
| `tools/parse-pklg.py` | Reads raw PacketLogger captures. The text export truncates large packets; this does not. |
| `tools/parse-packetlog.py` | Filters a text export down to the writes that matter |
| `tools/analyse-peq.py` | Pairs equaliser commands with coefficient blocks and decodes them |
| `captures/` | Bluetooth captures — **not in git**, they carry the serial number and MAC addresses |

The decrypted Marshall app the protocol was recovered from is deliberately not
here. It is Marshall's copyrighted binary; only the findings belong in this repo.
