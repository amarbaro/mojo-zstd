# Malformed-input fuzz for the zstd and lz4 decoders: mutates each frame in DIR (flip, truncate, splice) and decodes it.
# A raise is fine; a crash or hang is the bug. Prints "case F K" before each decode so a crash names its input.
# Usage: mojo run -I src tests/fuzz.mojo DIR ROUNDS SEED
from std.sys import argv
from std.os import listdir
import lz4.codec
import zstd


def load(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var d = String(argv()[1])
    var rounds = Int(argv()[2])
    var seed = UInt64(Int(argv()[3]))
    var ok = 0
    var err = 0
    for name in listdir(d):
        if not name.endswith(".zst"):
            continue
        var src = load(d + "/" + name)
        for k in range(rounds):
            seed = seed * 6364136223846793005 + 1442695040888963407
            var m = src.copy()
            var r = Int(seed >> 33)
            var op = r % 3
            if op == 0 and len(m) > 0:
                for j in range(1 + (r >> 4) % 4):
                    var i = (r >> (j * 5)) % len(m)
                    m[i] ^= UInt8(1 << ((r >> 2) % 8))
            elif op == 1 and len(m) > 1:
                m.shrink((r >> 3) % len(m))
            elif len(m) > 4:
                var i = (r >> 3) % len(m)
                for j in range(min(8, len(m) - i)):
                    m[i + j] = UInt8((r >> (j * 3)) & 0xFF)
            print("case", name, k, flush=True)
            try:
                if src[0] != 0x04:  # lz4 frame magic starts 04 22 4D 18
                    _ = zstd.decompress(m)
                else:
                    _ = lz4.codec.decompress(m)
                ok += 1
            except:
                err += 1
    print("DONE ok", ok, "err", err)
