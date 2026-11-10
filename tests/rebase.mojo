# Table indices start 1.5 MB below 2^31, so the encoder must rebase them in the middle of the stream. Writes
# .work/rb.raw and .work/rb<level>.zst for levels 1, 3, 12 and 19; check.sh decodes them under Python.
from zstd.compress import Zenc


def main() raises:
    var n = 3 << 20
    var raw = List[UInt8](length=n, fill=0)
    var s = 1
    for i in range(n):  # words from a 64-entry table: compressible, never periodic
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        raw[i] = UInt8(97 + ((s >> 16) & 7) + (i & 56 if (s >> 24) & 1 == 0 else 0))
    with open(".work/rb.raw", "w") as f:
        f.write_bytes(raw)
    for lv in [1, 3, 12, 19]:
        var z = Zenc(lv)
        z.e.boff = (1 << 31) - 1_500_000
        with open(".work/rb" + String(lv) + ".zst", "w") as fh:
            var i = 0
            while i < n:
                var k = min(100000, n - i)
                z.write(Span(raw)[i : i + k], fh)
                i += k
            z.finish(fh)
    print("rebase: ok")
