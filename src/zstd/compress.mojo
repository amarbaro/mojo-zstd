"""zstd compression driver: level parameters (libzstd's clevels.h), the window buffer, frame header, block loop,
checksum. One engine serves compress() over a whole buffer and ZstdWriter over a stream."""
from std.memory import unsafe_memcpy, unsafe_memmove
from zstd.enc import Enc
from zstd.fse import hb
from zstd.finder import dfast, fast
from zstd.opt import lazy, opt_parse
from zstd.xxh64 import Xxh64

comptime BLOCK = 1 << 17

def _table() -> List[Int]:
    # per size tier (above 256 KiB, up to 256 KiB, 128 KiB, 16 KiB) and level 0..22: windowLog, chainLog,
    # hashLog, searchLog, minMatch, targetLength, strategy (1 fast .. 9 btultra2)
    return [
        19, 12, 13, 1, 6, 1, 1, 19, 13, 14, 1, 7, 0, 1, 20, 15, 16, 1, 6, 0, 1,
        21, 16, 17, 1, 5, 0, 2, 21, 18, 18, 1, 5, 0, 2, 21, 18, 19, 3, 5, 2, 3,
        21, 18, 19, 3, 5, 4, 4, 21, 19, 20, 4, 5, 8, 4, 21, 19, 20, 4, 5, 16, 5,
        22, 20, 21, 4, 5, 16, 5, 22, 21, 22, 5, 5, 16, 5, 22, 21, 22, 6, 5, 16, 5,
        22, 22, 23, 6, 5, 32, 5, 22, 22, 22, 4, 5, 32, 6, 22, 22, 23, 5, 5, 32, 6,
        22, 23, 23, 6, 5, 32, 6, 22, 22, 22, 5, 5, 48, 7, 23, 23, 22, 5, 4, 64, 7,
        23, 23, 22, 6, 3, 64, 8, 23, 24, 22, 7, 3, 256, 9, 25, 25, 23, 7, 3, 256, 9,
        26, 26, 24, 7, 3, 512, 9, 27, 27, 25, 9, 3, 999, 9, 18, 12, 13, 1, 5, 1, 1,
        18, 13, 14, 1, 6, 0, 1, 18, 14, 14, 1, 5, 0, 2, 18, 16, 16, 1, 4, 0, 2,
        18, 16, 17, 3, 5, 2, 3, 18, 17, 18, 5, 5, 2, 3, 18, 18, 19, 3, 5, 4, 4,
        18, 18, 19, 4, 4, 4, 4, 18, 18, 19, 4, 4, 8, 5, 18, 18, 19, 5, 4, 8, 5,
        18, 18, 19, 6, 4, 8, 5, 18, 18, 19, 5, 4, 12, 6, 18, 19, 19, 7, 4, 12, 6,
        18, 18, 19, 4, 4, 16, 7, 18, 18, 19, 4, 3, 32, 7, 18, 18, 19, 6, 3, 128, 7,
        18, 19, 19, 6, 3, 128, 8, 18, 19, 19, 8, 3, 256, 8, 18, 19, 19, 6, 3, 128, 9,
        18, 19, 19, 8, 3, 256, 9, 18, 19, 19, 10, 3, 512, 9, 18, 19, 19, 12, 3, 512, 9,
        18, 19, 19, 13, 3, 999, 9, 17, 12, 12, 1, 5, 1, 1, 17, 12, 13, 1, 6, 0, 1,
        17, 13, 15, 1, 5, 0, 1, 17, 15, 16, 2, 5, 0, 2, 17, 17, 17, 2, 4, 0, 2,
        17, 16, 17, 3, 4, 2, 3, 17, 16, 17, 3, 4, 4, 4, 17, 16, 17, 3, 4, 8, 5,
        17, 16, 17, 4, 4, 8, 5, 17, 16, 17, 5, 4, 8, 5, 17, 16, 17, 6, 4, 8, 5,
        17, 17, 17, 5, 4, 8, 6, 17, 18, 17, 7, 4, 12, 6, 17, 18, 17, 3, 4, 12, 7,
        17, 18, 17, 4, 3, 32, 7, 17, 18, 17, 6, 3, 256, 7, 17, 18, 17, 6, 3, 128, 8,
        17, 18, 17, 8, 3, 256, 8, 17, 18, 17, 10, 3, 512, 8, 17, 18, 17, 5, 3, 256, 9,
        17, 18, 17, 7, 3, 512, 9, 17, 18, 17, 9, 3, 512, 9, 17, 18, 17, 11, 3, 999, 9,
        14, 12, 13, 1, 5, 1, 1, 14, 14, 15, 1, 5, 0, 1, 14, 14, 15, 1, 4, 0, 1,
        14, 14, 15, 2, 4, 0, 2, 14, 14, 14, 4, 4, 2, 3, 14, 14, 14, 3, 4, 4, 4,
        14, 14, 14, 4, 4, 8, 5, 14, 14, 14, 6, 4, 8, 5, 14, 14, 14, 8, 4, 8, 5,
        14, 15, 14, 5, 4, 8, 6, 14, 15, 14, 9, 4, 8, 6, 14, 15, 14, 3, 4, 12, 7,
        14, 15, 14, 4, 3, 24, 7, 14, 15, 14, 5, 3, 32, 8, 14, 15, 15, 6, 3, 64, 8,
        14, 15, 15, 7, 3, 256, 8, 14, 15, 15, 5, 3, 48, 9, 14, 15, 15, 6, 3, 128, 9,
        14, 15, 15, 7, 3, 256, 9, 14, 15, 15, 8, 3, 256, 9, 14, 15, 15, 8, 3, 512, 9,
        14, 15, 15, 9, 3, 512, 9, 14, 15, 15, 10, 3, 999, 9,
    ]


def set_params(mut e: Enc, level: Int, size: Int):
    """ZSTD_getCParams + ZSTD_adjustCParams for a level (clamped) and a source size (-1 unknown), and fresh tables."""
    var lv = level
    if lv == 0:
        lv = 3
    lv = min(lv, 22)
    var tier = 0
    if size >= 0:
        tier = 3 if size <= 16384 else (2 if size <= 131072 else (1 if size <= 262144 else 0))
    var t = _table()
    var row = t[(tier * 23 + max(lv, 0)) * 7 : (tier * 23 + max(lv, 0)) * 7 + 7]
    e.level = lv
    e.wlog = row[0]
    e.clog = row[1]
    e.hlog = row[2]
    e.slog = row[3]
    e.mml = row[4]
    e.tlen = row[5]
    e.strat = row[6]
    if lv < 0:
        e.tlen = -lv
    if size >= 0:
        var src_log = 6 if size < 64 else hb(size - 1) + 1
        if e.wlog > src_log:
            e.wlog = src_log
    if e.hlog > e.wlog + 1:
        e.hlog = e.wlog + 1
    var cycle = e.clog - (1 if e.strat >= 6 else 0)
    if cycle > e.wlog:
        e.clog -= cycle - e.wlog
    e.wlog = max(e.wlog, 10)
    e.hlog = max(e.hlog, 6)
    e.clog = max(e.clog, 6)
    e.ht = List[UInt32](length=1 << e.hlog, fill=0)
    e.ct = List[UInt32]()
    if e.strat >= 2:
        e.ct = List[UInt32](length=1 << e.clog, fill=0)
    if e.strat >= 6:
        e.o.alloc()
        if e.mml == 3:
            e.o.h3 = List[UInt32](length=1 << min(17, e.hlog), fill=0)
    e.boff = 0
    e.upd = 0
    e.reset_frame()


def parse(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int) -> Int:
    if e.strat == 1:
        return fast(e, p, start, end)
    if e.strat == 2:
        return dfast(e, p, start, end)
    if e.strat <= 5:
        return lazy[False](e, p, start, end, 0 if e.strat == 3 else (1 if e.strat == 4 else 2))
    if e.strat == 6:
        return lazy[True](e, p, start, end, 2)
    if e.strat == 9 and e.boff + start == 0 and e.o.llsum == 0 and end - start > 8:
        # btultra2: a first pass over the block only to learn the statistics, then parse again without history
        var r0 = e.r0
        var r1 = e.r1
        var r2 = e.r2
        _ = opt_parse(e, p, start, end, 2)
        e.nseq = 0
        e.nlit = 0
        e.r0 = r0
        e.r1 = r1
        e.r2 = r2
        e.boff += end - start
        e.upd = start
        e.o.nupd3 = start
        for i in range(len(e.ht)):
            e.ht[i] = 0
        for i in range(len(e.ct)):
            e.ct[i] = 0
    return opt_parse(e, p, start, end, 0 if e.strat == 7 else 2)


def put_header(mut out: List[UInt8], wlog: Int, size: Int, checksum: Bool):
    """Frame header; size -1 when unknown."""
    var window = 1 << wlog
    var single = size >= 0 and window >= size
    var fcs = 0
    if size >= 0:
        fcs = (1 if size >= 256 else 0) + (1 if size >= 65792 else 0) + (1 if size >= (1 << 32) else 0)
    for b in [0x28, 0xB5, 0x2F, 0xFD]:
        out.append(UInt8(b))
    out.append(UInt8((fcs << 6) | ((1 if single else 0) << 5) | ((1 if checksum else 0) << 2)))
    if not single:
        out.append(UInt8((wlog - 10) << 3))
    if size >= 0:
        var nb = 1 if (fcs == 0 and single) else (0 if fcs == 0 else (2 if fcs == 1 else (4 if fcs == 2 else 8)))
        var v = size - (256 if fcs == 1 else 0)
        for k in range(nb):
            out.append(UInt8((v >> (8 * k)) & 255))


def rebase(mut e: Enc):
    """Table indices stay in 32 bits: when they get large, subtract a multiple of the chain size from all."""
    var unit = 1 << max(e.clog, 6)
    var corr = (e.boff // unit) * unit
    if corr == 0:
        return
    var h = e.ht.unsafe_ptr()
    for i in range(len(e.ht)):
        var v = Int(h[unsafe_offset=i])
        h[unsafe_offset=i] = UInt32(v - corr) if v > corr else 0
    var c = e.ct.unsafe_ptr()
    for i in range(len(e.ct)):
        var v = Int(c[unsafe_offset=i])
        c[unsafe_offset=i] = UInt32(v - corr) if v > corr else 0
    e.boff -= corr


def encode_blocks(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int, last: Bool, mut out: List[UInt8]):
    """Compresses p[start:end] (p[:start] is history) as blocks of at most 128 KiB, appended to out; the last
    one carries the last-block bit when `last`."""
    var pos = start
    while True:
        var bn = min(BLOCK, end - pos)
        var is_last = last and pos + bn >= end
        if e.boff + pos > (1 << 31):
            rebase(e)
        e.nseq = 0
        e.nlit = 0
        var r0 = e.r0
        var r1 = e.r1
        var r2 = e.r2
        var n0 = len(out)
        out.resize(unsafe_uninit_length=n0 + bn + bn // 8 + 1024)
        if bn >= 16:
            var anchor = parse(e, p, pos, pos + bn)
            var tail = pos + bn - anchor
            if e.nlit + tail + 64 > len(e.lits):
                e.lits.resize(unsafe_uninit_length=e.nlit + tail + 64 + len(e.lits))
            unsafe_memcpy(dest=e.lits.unsafe_ptr().unsafe_offset(e.nlit), src=p.unsafe_offset(anchor), count=tail)
            e.nlit += tail
        else:
            if e.nlit + bn + 64 > len(e.lits):
                e.lits.resize(unsafe_uninit_length=e.nlit + bn + 64 + len(e.lits))
            unsafe_memcpy(dest=e.lits.unsafe_ptr(), src=p.unsafe_offset(pos), count=bn)
            e.nlit = bn
        var w = e.block(p.unsafe_offset(pos), bn, out.unsafe_ptr().unsafe_offset(n0), is_last, r0, r1, r2)
        out.resize(unsafe_uninit_length=n0 + w)
        pos += bn
        if pos >= end:
            break


def compress_all(data: Span[UInt8, _], level: Int) raises -> List[UInt8]:
    """One frame with content size and checksum."""
    var n = len(data)
    if n >= 1 << 31:
        raise Error("zstd: input over 2 GiB")
    var e = Enc()
    set_params(e, level, n)
    var out = List[UInt8]()
    out.reserve(n // 2 + 64)
    put_header(out, e.wlog, n, True)
    var p = data.unsafe_ptr().unsafe_mut_cast[False]()
    if n == 0:
        out.append(1)
        out.append(0)
        out.append(0)
    else:
        encode_blocks(e, p, 0, n, True, out)
    var h = Xxh64()
    h.update(p, n)
    var d = Int(h.digest() & 0xFFFFFFFF)
    for k in range(4):
        out.append(UInt8((d >> (8 * k)) & 255))
    return out^


struct Zenc(Movable):
    """Streaming encoder: input is copied into a window buffer (the last window of history plus room for two
    blocks), compressed block by block, and the output is handed to a file as it grows."""

    var e: Enc
    var buf: List[UInt8]
    var blen: Int
    var bpos: Int
    var hist: Int
    var cap: Int
    var out: List[UInt8]
    var hash: Xxh64
    var started: Bool

    def __init__(out self, level: Int):
        self.e = Enc()
        set_params(self.e, level, -1)
        self.hist = 1 << self.e.wlog
        self.cap = self.hist + 2 * BLOCK
        self.buf = List[UInt8](length=self.cap + 64, fill=0)
        self.blen = 0
        self.bpos = 0
        self.out = List[UInt8]()
        self.hash = Xxh64()
        self.started = False

    def _flush(mut self, mut f: FileHandle, force: Bool) raises:
        if len(self.out) >= (1 << 17) or (force and len(self.out) > 0):
            try:
                f.write_all(Span(self.out))
            except:
                raise Error("zstd: write error")
            self.out.clear()

    def _blocks(mut self, mut f: FileHandle) raises:
        var p = self.buf.unsafe_ptr().unsafe_mut_cast[False]()
        while self.blen - self.bpos >= BLOCK:
            encode_blocks(self.e, p, self.bpos, self.bpos + BLOCK, False, self.out)
            self.bpos += BLOCK
            self._flush(f, False)

    def write(mut self, data: Span[UInt8, _], mut f: FileHandle) raises:
        if not self.started:
            put_header(self.out, self.e.wlog, -1, True)
            self.started = True
        var n = len(data)
        self.hash.update(data.unsafe_ptr().unsafe_mut_cast[False](), n)
        var i = 0
        while i < n:
            var k = min(n - i, self.cap - self.blen)
            unsafe_memcpy(dest=self.buf.unsafe_ptr().unsafe_offset(self.blen), src=data.unsafe_ptr().unsafe_offset(i).unsafe_mut_cast[False](), count=k)
            self.blen += k
            i += k
            self._blocks(f)
            if self.blen == self.cap:  # full: drop what is older than the window
                var shift = self.bpos - min(self.bpos, self.hist)
                var b = self.buf.unsafe_ptr()
                unsafe_memmove(dest=b, src=b.unsafe_offset(shift).unsafe_origin_cast[MutUntrackedOrigin](), count=self.blen - shift)
                self.blen -= shift
                self.bpos -= shift
                self.e.boff += shift
                self.e.upd = max(self.e.upd - shift, 0)
                self.e.o.nupd3 = max(self.e.o.nupd3 - shift, 0)

    def finish(mut self, mut f: FileHandle) raises:
        if not self.started:
            put_header(self.out, self.e.wlog, -1, True)
            self.started = True
        var p = self.buf.unsafe_ptr().unsafe_mut_cast[False]()
        if self.blen > self.bpos:
            encode_blocks(self.e, p, self.bpos, self.blen, True, self.out)
        else:
            self.out.append(1)
            self.out.append(0)
            self.out.append(0)
        var d = Int(self.hash.digest() & 0xFFFFFFFF)
        for k in range(4):
            self.out.append(UInt8((d >> (8 * k)) & 255))
        self._flush(f, True)
