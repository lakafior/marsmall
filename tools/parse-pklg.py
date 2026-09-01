#!/usr/bin/env python3
"""Wyciąga pełne pakiety ATT z surowego nagrania PacketLoggera (.pklg).

Eksport tekstowy PacketLoggera przycina wartości do kilkunastu bajtów, przez co
duże payloady (współczynniki equalizera) są nie do odczytania. Ten skrypt czyta
plik binarny, więc widzi wszystko.

Rekord .pklg:  [u32be długość][u32be sek][u32be µs][u8 typ][dane]
Typy: 0x02 ACL host→kontroler, 0x03 ACL kontroler→host.

    python3 parse-pklg.py nagranie.pklg                 # zapisy ATT
    python3 parse-pklg.py nagranie.pklg --handle 0x0053 # tylko jeden uchwyt
    python3 parse-pklg.py nagranie.pklg --all           # też odczyty i notyfikacje
"""
import struct, sys, pathlib
from datetime import datetime, timezone

ATT_CID = 0x0004
OPS = {0x12: "WriteReq", 0x52: "WriteCmd", 0x0A: "ReadReq", 0x0B: "ReadRsp",
       0x1B: "Notify", 0x1D: "Indicate", 0x13: "WriteRsp", 0x01: "Error"}


def records(data: bytes):
    off = 0
    while off + 4 <= len(data):
        (ln,) = struct.unpack_from(">I", data, off)
        rec = data[off + 4: off + 4 + ln]
        off += 4 + ln
        if len(rec) < 9:
            continue
        ts_s, ts_us, typ = struct.unpack_from(">IIB", rec, 0)
        yield ts_s, ts_us, typ, rec[9:]


def att_pdus(data: bytes):
    """Składa fragmenty ACL i zwraca kompletne PDU z kanału ATT."""
    partial = {}
    for ts_s, ts_us, typ, payload in records(data):
        if typ not in (0x02, 0x03) or len(payload) < 4:
            continue
        h, total = struct.unpack_from("<HH", payload, 0)
        handle, pb = h & 0x0FFF, (h >> 12) & 0x3
        body = payload[4:4 + total]

        if pb == 0b01 and handle in partial:            # kontynuacja
            partial[handle][1] += body
        else:
            if len(body) < 4:
                continue
            l2len, cid = struct.unpack_from("<HH", body, 0)
            if cid != ATT_CID:
                partial.pop(handle, None)
                continue
            partial[handle] = [l2len, bytearray(body[4:]), ts_s, ts_us, typ]

        if handle in partial:
            want, buf, s, us, t = partial[handle]
            if len(buf) >= want:
                yield s, us, t, bytes(buf[:want])
                del partial[handle]


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    args = sys.argv[2:]
    show_all = "--all" in args
    want_handle = None
    if "--handle" in args:
        want_handle = int(args[args.index("--handle") + 1], 0)

    data = pathlib.Path(sys.argv[1]).read_bytes()
    for ts_s, ts_us, direction, pdu in att_pdus(data):
        if not pdu:
            continue
        op = pdu[0]
        name = OPS.get(op)
        if name is None:
            continue
        if not show_all and op not in (0x12, 0x52):
            continue
        if len(pdu) < 3:
            continue
        (att_handle,) = struct.unpack_from("<H", pdu, 1)
        if want_handle is not None and att_handle != want_handle:
            continue
        value = pdu[3:]
        when = datetime.fromtimestamp(ts_s, timezone.utc).strftime("%H:%M:%S")
        arrow = "->" if direction == 0x02 else "<-"
        print(f"{when}.{ts_us // 1000:03d} {arrow} {name:9s} handle=0x{att_handle:04X} "
              f"len={len(value):3d} {value.hex()}")


if __name__ == "__main__":
    main()
