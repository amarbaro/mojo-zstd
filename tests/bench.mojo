# Compresses then decompresses argv[1] with zstd (level 3) and lz4, timing each. Same work as
# `tools/oracle.py bench`.
from std.sys import argv
from std.time import perf_counter_ns
import lz4
import zstd


def levels(raw: List[UInt8]) raises:
    """Levels 1, 9 and 19 on the first 4 MiB: compress and decompress ms, bytes."""
    var part = List[UInt8](Span(raw)[: min(len(raw), 4 << 20)])
    for lv in [1, 9, 19]:
        var t = perf_counter_ns()
        var c = zstd.compress(part, lv)
        var t1 = perf_counter_ns()
        var d = zstd.decompress(c)
        var t2 = perf_counter_ns()
        if d != part:
            raise Error("bench: zstd round trip differs at level ", lv)
        print("L", lv, "c", (t1 - t) // 1_000_000, "ms d", (t2 - t1) // 1_000_000, "ms (", len(c), "B )")


def main() raises:
    var raw: List[UInt8]
    with open(String(argv()[1]), "r") as f:
        raw = f.read_bytes()
    if len(argv()) > 2:
        levels(raw)
        return
    var t = perf_counter_ns()
    var c = zstd.compress(raw)
    var t1 = perf_counter_ns()
    var d = zstd.decompress(c)
    var t2 = perf_counter_ns()
    if d != raw:
        raise Error("bench: zstd round trip differs")
    _ = d^
    var t2b = perf_counter_ns()
    var lc = lz4.compress(raw)
    var t3 = perf_counter_ns()
    var ld = lz4.decompress(lc)
    var t4 = perf_counter_ns()
    if ld != raw:
        raise Error("bench: lz4 round trip differs")
    print("zstd c", (t1 - t) // 1_000_000, "ms d", (t2 - t1) // 1_000_000, "ms (", len(c), "B ); lz4 c", (t3 - t2b) // 1_000_000,
          "ms d", (t4 - t3) // 1_000_000, "ms (", len(lc), "B )")
