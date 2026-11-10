"""xxHash64 (BSD-2-Clause, Yann Collet), incremental, little endian: the zstd content checksum."""

comptime _P1: UInt64 = 11400714785074694791
comptime _P2: UInt64 = 14029467366897019727
comptime _P3: UInt64 = 1609587929392839161
comptime _P4: UInt64 = 9650029242287828579
comptime _P5: UInt64 = 2870177450012600261


@always_inline
def _rd64(p: ImmPointer[UInt8, _], i: Int) -> UInt64:
    return p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]()


@always_inline
def _rd32(p: ImmPointer[UInt8, _], i: Int) -> UInt64:
    return UInt64(p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_load[alignment=1]())


@always_inline
def _rol(x: UInt64, r: UInt64) -> UInt64:
    return (x << r) | (x >> (64 - r))


@always_inline
def _round(acc: UInt64, v: UInt64) -> UInt64:
    return _rol(acc + v * _P2, 31) * _P1


@always_inline
def _merge(h: UInt64, v: UInt64) -> UInt64:
    return (h ^ _round(0, v)) * _P1 + _P4


struct Xxh64(Movable):
    var v1: UInt64
    var v2: UInt64
    var v3: UInt64
    var v4: UInt64
    var total: Int
    var mem: List[UInt8]  # unprocessed tail, under 32 bytes
    var memn: Int

    def __init__(out self):
        self.v1 = _P1 + _P2
        self.v2 = _P2
        self.v3 = 0
        self.v4 = 0 - _P1
        self.total = 0
        self.mem = List[UInt8](length=32, fill=0)
        self.memn = 0

    def update(mut self, p: ImmPointer[UInt8, _], n: Int):
        self.total += n
        var i = 0
        if self.memn > 0:
            var take = min(32 - self.memn, n)
            for k in range(take):
                self.mem[self.memn + k] = p[unsafe_offset=k]
            self.memn += take
            i = take
            if self.memn < 32:
                return
            var m = self.mem.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[ImmUntrackedOrigin]()
            self.v1 = _round(self.v1, _rd64(m, 0))
            self.v2 = _round(self.v2, _rd64(m, 8))
            self.v3 = _round(self.v3, _rd64(m, 16))
            self.v4 = _round(self.v4, _rd64(m, 24))
            self.memn = 0
        var a = self.v1
        var b = self.v2
        var c = self.v3
        var d = self.v4
        while i + 32 <= n:
            a = _round(a, _rd64(p, i))
            b = _round(b, _rd64(p, i + 8))
            c = _round(c, _rd64(p, i + 16))
            d = _round(d, _rd64(p, i + 24))
            i += 32
        self.v1 = a
        self.v2 = b
        self.v3 = c
        self.v4 = d
        while i < n:
            self.mem[self.memn] = p[unsafe_offset=i]
            self.memn += 1
            i += 1

    def digest(self) -> UInt64:
        var h: UInt64
        if self.total >= 32:
            h = _rol(self.v1, 1) + _rol(self.v2, 7) + _rol(self.v3, 12) + _rol(self.v4, 18)
            h = _merge(h, self.v1)
            h = _merge(h, self.v2)
            h = _merge(h, self.v3)
            h = _merge(h, self.v4)
        else:
            h = _P5
        h += UInt64(self.total)
        var m = self.mem.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[ImmUntrackedOrigin]()
        var i = 0
        while i + 8 <= self.memn:
            h = _rol(h ^ _round(0, _rd64(m, i)), 27) * _P1 + _P4
            i += 8
        if i + 4 <= self.memn:
            h = _rol(h ^ (_rd32(m, i) * _P1), 23) * _P2 + _P3
            i += 4
        while i < self.memn:
            h = _rol(h ^ (UInt64(m[unsafe_offset=i]) * _P5), 11) * _P1
            i += 1
        h ^= h >> 33
        h *= _P2
        h ^= h >> 29
        h *= _P3
        h ^= h >> 32
        return h
