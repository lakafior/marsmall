#!/usr/bin/env python3
"""Wyciąga z tekstowego eksportu PacketLoggera to, co istotne.

Zostawia zapisy i odczyty charakterystyk Zounda oraz ruch na kanale RACE Airohy,
odsiewając odkrywanie serwisów, konfigurację powiadomień i całą resztę szumu.

    python3 parse-packetlog.py log.txt            # tylko zapisy (domyślnie)
    python3 parse-packetlog.py log.txt --all      # zapisy, odczyty i notyfikacje
"""
import re, sys, pathlib

ZOUND = re.compile(r'(0000[0-9A-F]{4})-1337-1DEA-FEED-C0FFEE70C0DE', re.I)
RACE_W = "43484152-2DAB-3241"          # kanal Airohy, zapis
RACE_N = "43484152-2DAB-3141"          # kanal Airohy, odbior


def race(value: str) -> str:
    """Rozbiera ramkę RACE: [05][typ][dlugosc u16le][race_id u16le][payload]."""
    b = bytes.fromhex(value.replace(" ", ""))
    if len(b) < 6 or b[0] != 0x05:
        return ""
    kind = {0x5A: "cmd", 0x5B: "resp", 0x5C: "NOTIFY", 0x5D: "resp"}.get(b[1], hex(b[1]))
    rid = b[4] | (b[5] << 8)
    return f"  RACE {kind} id=0x{rid:04X} payload={b[6:].hex()}"


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    show_all = "--all" in sys.argv
    lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()

    for line in lines:
        if "ATT" not in line:
            continue
        is_write = "Write Request" in line or "Write Command" in line
        if not (is_write or show_all):
            continue
        # Konfiguracja powiadomien to nie sa dane - pomijamy.
        if "Configuration" in line and "Value:" not in line:
            continue

        m = ZOUND.search(line)
        tag = None
        if m:
            tag = m.group(1)
        elif RACE_W in line or RACE_N in line:
            tag = "RACE"
        if not tag:
            continue

        value = ""
        v = re.search(r'Value:\s*([0-9A-F ]+?)(?:…|\s*$)', line)
        if v:
            value = v.group(1).strip()

        when = line[:21].strip()
        what = "WRITE" if is_write else ("NOTIFY" if "Notification" in line else "read ")
        print(f"{when}  {what}  {tag:<10} {value.replace(' ', '').lower()}")
        if tag == "RACE" and value:
            print(race(value))


if __name__ == "__main__":
    main()
