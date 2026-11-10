"""Pre-split of a 128 KiB block where the statistics change (libzstd's zstd_preSplit.c: hash fingerprints of 8 KiB
chunks compared with the data before them, BSD-3-Clause, Meta Platforms and Yann Collet)."""

comptime _CHUNK = 8 << 10


@always_inline
def _hash2(p: ImmPointer[UInt8, _], i: Int, bits: Int) -> Int:
    if bits == 8:
        return Int(p[unsafe_offset=i])
    var v = UInt32(p[unsafe_offset=i]) | (UInt32(p[unsafe_offset=i + 1]) << 8)
    return Int((v * 0x9E3779B9) >> UInt32(32 - bits))


def _record(mut fp: List[Int], p: ImmPointer[UInt8, _], off: Int, n: Int, rate: Int, bits: Int) -> Int:
    """Events of p[off:off+n] sampled every `rate` bytes into fp; returns their count as libzstd tallies it."""
    for i in range(1 << bits):
        fp[i] = 0
    var limit = n - 1
    var k = 0
    while k < limit:
        fp[_hash2(p, off + k, bits)] += 1
        k += rate
    return limit // rate


def _dist(f1: List[Int], n1: Int, f2: List[Int], n2: Int, bits: Int) -> Int:
    var d = 0
    for i in range(1 << bits):
        var x = f1[i] * n2 - f2[i] * n1
        d += -x if x < 0 else x
    return d


def _differs(r: List[Int], nr: Int, f: List[Int], nf: Int, penalty: Int, bits: Int) -> Bool:
    return _dist(r, nr, f, nf, bits) >= (nr * nf * (14 + penalty)) // 16


def split_block(p: ImmPointer[UInt8, _], at: Int, size: Int, level: Int) -> Int:
    """ZSTD_splitBlock over p[at:at+size] (128 KiB): where to cut the block. level 0 looks at the borders and
    the middle only, 1..4 compare every 8 KiB chunk with the ones before it, sampling more densely."""
    if level == 0:
        var past = List[Int](length=256, fill=0)
        var new = List[Int](length=256, fill=0)
        var mid = List[Int](length=256, fill=0)
        for i in range(512):
            past[Int(p[unsafe_offset=at + i])] += 1
            new[Int(p[unsafe_offset=at + size - 512 + i])] += 1
        if not _differs(past, 512, new, 512, 0, 8):
            return size
        for i in range(512):
            mid[Int(p[unsafe_offset=at + size // 2 - 256 + i])] += 1
        var db = _dist(past, 512, mid, 512, 8)
        var de = _dist(new, 512, mid, 512, 8)
        var diff = db - de
        if (-diff if diff < 0 else diff) < 512 * 512 // 3:
            return 64 << 10
        return (32 << 10) if db > de else (96 << 10)
    var rate = 43 if level == 1 else (11 if level == 2 else (5 if level == 3 else 1))
    var bits = 8 if level == 1 else (9 if level == 2 else 10)
    var past = List[Int](length=1024, fill=0)
    var new = List[Int](length=1024, fill=0)
    var npast = _record(past, p, at, _CHUNK, rate, bits)
    var penalty = 3
    var pos = _CHUNK
    while pos <= size - _CHUNK:
        var nnew = _record(new, p, at + pos, _CHUNK, rate, bits)
        if _differs(past, npast, new, nnew, penalty, bits):
            return pos
        for i in range(1 << bits):
            past[i] += new[i]
        npast += nnew
        if penalty > 0:
            penalty -= 1
        pos += _CHUNK
    return size
