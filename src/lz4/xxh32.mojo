"""xxHash32 (BSD-2-Clause, Yann Collet), one-shot, little endian. Used for lz4 header, block and content checksums."""

comptime _P1: UInt32 = 2654435761
comptime _P2: UInt32 = 2246822519
comptime _P3: UInt32 = 3266489917
comptime _P4: UInt32 = 668265263
comptime _P5: UInt32 = 374761393


@always_inline
def _rd(p: Pointer[UInt8, _], i: Int) -> UInt32:
    return p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_load[alignment=1]()


@always_inline
def _rol(x: UInt32, r: UInt32) -> UInt32:
    return (x << r) | (x >> (32 - r))


@always_inline
def _round(acc: UInt32, v: UInt32) -> UInt32:
    return _rol(acc + v * _P2, 13) * _P1


def xxh32(p: Pointer[UInt8, _], n: Int, seed: UInt32 = 0) -> UInt32:
    var i = 0
    var h: UInt32
    if n >= 16:
        var v1 = seed + _P1 + _P2
        var v2 = seed + _P2
        var v3 = seed
        var v4 = seed - _P1
        while i + 16 <= n:
            v1 = _round(v1, _rd(p, i))
            v2 = _round(v2, _rd(p, i + 4))
            v3 = _round(v3, _rd(p, i + 8))
            v4 = _round(v4, _rd(p, i + 12))
            i += 16
        h = _rol(v1, 1) + _rol(v2, 7) + _rol(v3, 12) + _rol(v4, 18)
    else:
        h = seed + _P5
    h += UInt32(n)
    while i + 4 <= n:
        h = _rol(h + _rd(p, i) * _P3, 17) * _P4
        i += 4
    while i < n:
        h = _rol(h + UInt32(p[unsafe_offset=i]) * _P5, 11) * _P1
        i += 1
    h ^= h >> 15
    h *= _P2
    h ^= h >> 13
    h *= _P3
    h ^= h >> 16
    return h
