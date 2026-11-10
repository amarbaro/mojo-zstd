"""Prints the structure of a zstd frame: header, and per block its type, literal section type and size, sequence
count and table modes. A debugging aid for comparing encoders: .venv/bin/python -I tools/zstd_info.py FILE"""
import sys

def info(c):
    fd = c[4]; single = (fd >> 5) & 1; fcs = fd >> 6; dsz = [0, 1, 2, 4][fd & 3]; cs = [1 if single else 0, 2, 4, 8][fcs]
    q = 5 + (0 if single else 1) + dsz + cs
    print(f"frame {len(c)} B header {q} B single={single} checksum={(fd >> 2) & 1}")
    while True:
        bh = int.from_bytes(c[q:q + 3], "little"); last, t, sz = bh & 1, (bh >> 1) & 3, bh >> 3
        q += 3
        if t == 2:
            body = c[q:q + sz]; lb = body[0]; lt = lb & 3; fm = (lb >> 2) & 3
            if lt < 2:
                lh = [1, 2, 1, 3][fm]; ls = [lb >> 3, (lb | body[1] << 8) >> 4, lb >> 3, (lb | body[1] << 8 | body[2] << 16) >> 4][fm]; cl = lh + (1 if lt else ls)
            else:
                v = int.from_bytes(body[:5], "little"); lh, ls, cl = [(3, (v >> 4) & 1023, (v >> 14) & 1023), (3, (v >> 4) & 1023, (v >> 14) & 1023), (4, (v >> 4) & 16383, v >> 18 & 16383), (5, (v >> 4) & 262143, (v >> 22) & 262143)][fm]; cl += lh
            n = body[cl]; p = cl + 1
            if n > 127:
                n = ((n - 128) << 8) + body[p] if n < 255 else body[p] + (body[p + 1] << 8) + 0x7F00; p += 1 if n < 0x7F00 else 2
            modes = body[p] if n else None
            print(f"  block compressed {sz} B last={last}: literals type {lt} regen {ls} comp {cl - lh} (header {lh}), {n} sequences, modes {modes if modes is None else (modes >> 6, (modes >> 4) & 3, (modes >> 2) & 3)}")
        else:
            print(f"  block {['raw', 'rle'][t]} {sz} B last={last}")
        q += (1 if t == 1 else sz)
        if last: break

info(open(sys.argv[1], "rb").read())
