#!/usr/bin/env python3
"""Analizuje blok współczynników equalizera z nagrania PacketLoggera.

Paruje komendy 0x0E2B (definicje pasm — nasza prawda o tym, co było ustawione)
z 0x0E03 (PEQ_REALTIME, policzone współczynniki) i próbuje rozłożyć te drugie.

Co już wiadomo i co ten skrypt weryfikuje:
  - element = jedna częstotliwość próbkowania: 44.1, 48, 88.2, 96 kHz
  - w każdym elemencie 5 pasm po 16 bajtów, rozdzielonych ff7f00ff
  - w 8-bajtowej jednostce: pole 0 = a1 w Q14, pole 2 = a2 w Q15 (RBJ peaking)

Czego szuka:
  - które gniazdo odpowiada któremu pasmu (układ bloku)
  - co siedzi w polach 1 i 3

    python3 analyse-peq.py nagranie.pklg
"""
import subprocess, struct, math, sys, pathlib, collections

BANDS = [(160, 0.7), (400, 0.7), (1000, 1.0), (2500, 1.0), (6250, 1.0)]
RATES = [44100, 48000, 88200, 96000]
SEP = bytes.fromhex("ff7f00ff")
HERE = pathlib.Path(__file__).parent


def rbj(f0, q, gain_db, fs):
    """Współczynniki filtru peaking wg receptury RBJ."""
    a = 10 ** (gain_db / 40)
    w0 = 2 * math.pi * f0 / fs
    alpha = math.sin(w0) / (2 * q)
    a0 = 1 + alpha / a
    return {"b0": (1 + alpha * a) / a0, "b1": (-2 * math.cos(w0)) / a0,
            "b2": (1 - alpha * a) / a0, "a1": (-2 * math.cos(w0)) / a0,
            "a2": (1 - alpha / a) / a0}


def pairs(path):
    out = subprocess.run(["python3", str(HERE / "parse-pklg.py"), path, "--handle", "0x0053"],
                         capture_output=True, text=True).stdout
    seq = []
    for line in out.splitlines():
        hx = line.split()[-1]
        if len(hx) < 12:
            continue
        b = bytes.fromhex(hx)
        rid = b[4] | (b[5] << 8)
        if rid in (0x0E2B, 0x0E03):
            seq.append((rid, b[6:]))
    res = []
    for i in range(len(seq) - 1):
        if seq[i][0] == 0x0E2B and seq[i + 1][0] == 0x0E03:
            gains = [struct.unpack_from("<i", seq[i][1], 5 + n * 18 + 6)[0] / 100 for n in range(5)]
            res.append((gains, seq[i + 1][1][4:]))
    return res


def units(body, element):
    """Pięć 16-bajtowych bloków jednego elementu."""
    el = body[2 + element * 110: 2 + element * 110 + 110]
    parts = el.split(SEP)
    if len(parts) != 5:
        return []
    return [parts[0][9:]] + parts[1:4] + [parts[4][:16]]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data = pairs(sys.argv[1])
    print(f"par (pasma -> współczynniki): {len(data)}\n")

    flat = next((b for g, b in data if all(x == 0 for x in g)), None)
    if flat is None:
        print("BRAK przechwycenia z wszystkimi pasmami na zerze — bez niego nie ma punktu odniesienia.")
        return

    # --- układ: które gniazdo rusza się przy którym paśmie ---
    print("UKŁAD BLOKU — które gniazdo zmienia się przy zmianie danego pasma\n")
    for gains, body in data:
        active = [i for i, g in enumerate(gains) if g != 0]
        if len(active) != 1:
            continue
        band = active[0]
        moved = []
        for slot, (u, f) in enumerate(zip(units(body, 0), units(flat, 0))):
            if u != f:
                moved.append(slot)
        print(f"  pasmo {band + 1} ({BANDS[band][0]:>5} Hz) na {gains[band]:+5.1f} dB "
              f"-> ruszyły gniazda {moved}")

    # --- pola 1 i 3 kontra współczynniki b ---
    print("\nPOLA 1 i 3 — dopasowanie do współczynników b\n")
    seen = set()
    for gains, body in data:
        active = [i for i, g in enumerate(gains) if g != 0]
        if len(active) != 1:
            continue
        band = active[0]
        key = (band, gains[band])
        if key in seen:
            continue
        seen.add(key)
        f0, q = BANDS[band]
        c = rbj(f0, q, gains[band], RATES[0])
        for slot, u in enumerate(units(body, 0)):
            for half in (0, 8):
                h = u[half:half + 8]
                a1 = struct.unpack_from("<h", h, 0)[0] / 16384
                if abs(a1 - c["a1"]) > 0.002:
                    continue
                f1 = struct.unpack_from("<H", h, 2)[0]
                f3 = struct.unpack_from("<H", h, 6)[0]
                print(f"  {f0:>5} Hz {gains[band]:+5.1f} dB  gniazdo {slot} połowa {half//8}"
                      f"   pole1={f1:>6} pole3={f3:>6}"
                      f"   b0={c['b0']:+.5f} b2={c['b2']:+.5f}"
                      f"   pole1/b0={f1/c['b0'] if c['b0'] else 0:>9.1f}"
                      f" pole3/b2={f3/c['b2'] if c['b2'] else 0:>9.1f}")


if __name__ == "__main__":
    main()
