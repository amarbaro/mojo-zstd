"""Entropy encoders for zstd (RFC 8878; algorithms of libzstd's FSE and HUF compressors, BSD-3-Clause, Meta Platforms and
Yann Collet): forward bit writer, FSE tables and the normalized-count header, Huffman tree, header, streams."""
from std.memory import unsafe_memcpy
from std.math import log2
from zstd.fse import hb


@always_inline
def put64(p: MutPointer[UInt8, _], i: Int, v: UInt64):
    p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_store[alignment=1](v)


struct BitC(Movable):
    """libzstd's BIT_CStream. The output needs 8 spare bytes past the largest result."""

    var cont: UInt64
    var pos: Int
    var dst: MutPointer[UInt8, MutUntrackedOrigin]
    var op: Int

    def __init__(out self, dst: MutPointer[UInt8, _]):
        self.cont = 0
        self.pos = 0
        self.dst = dst.unsafe_origin_cast[MutUntrackedOrigin]()
        self.op = 0

    @always_inline
    def add(mut self, v: Int, nb: Int):
        self.cont |= (UInt64(v) & ((UInt64(1) << UInt64(nb)) - 1)) << UInt64(self.pos)
        self.pos += nb

    @always_inline
    def flush(mut self):
        var n = self.pos >> 3
        put64(self.dst, self.op, self.cont)
        self.op += n
        self.pos &= 7
        self.cont >>= UInt64(n * 8)

    def close(mut self) -> Int:
        self.add(1, 1)
        self.flush()
        return self.op + (1 if self.pos > 0 else 0)


def normalize(count: List[Int], total: Int, nsym: Int, log: Int, low_prob: Bool, mut norm: List[Int]) -> Bool:
    """FSE counts into probabilities summing to 1 << log (at least 1 each for present symbols, -1 for rare ones
    when low_prob). False when one symbol holds everything."""
    var size = 1 << log
    var low = total >> log
    var left = size
    var best = 0
    for s in range(nsym):
        norm[s] = 0
        if count[s] == total:
            return False
        if count[s] == 0:
            continue
        if low_prob and count[s] <= low:
            norm[s] = -1
            left -= 1
            continue
        var p = (count[s] * size) // total
        if p < 1:
            p = 1
        norm[s] = p
        left -= p
        if count[s] > count[best] or norm[best] <= 0:
            best = s
    while left != 0:
        # give or take one unit where it costs least: the symbol whose share is furthest from its probability
        var pick = -1
        var score = 0
        for s in range(nsym):
            if norm[s] <= 0:
                continue
            var share = count[s] * size * 1024 // total  # ideal probability, 10 fractional bits
            var diff = share - norm[s] * 1024
            if left > 0:
                if pick < 0 or diff > score:
                    pick = s
                    score = diff
            elif norm[s] > 1:
                if pick < 0 or diff < score:
                    pick = s
                    score = diff
        if pick < 0:
            return False
        if left > 0:
            norm[pick] += 1
            left -= 1
        else:
            norm[pick] -= 1
            left += 1
    return True


def optimal_log(max_log: Int, nsrc: Int, max_sym: Int) -> Int:
    """FSE_optimalTableLog: the smallest log that still resolves the stats."""
    var bits_src = hb(max(nsrc - 1, 1)) - 2
    var tl = max_log
    var min_bits = min(hb(nsrc) + 1, hb(max(max_sym, 1)) + 2)
    if bits_src < tl:
        tl = bits_src
    if min_bits > tl:
        tl = min_bits
    return max(5, min(tl, 12))


struct FseC(Copyable, Movable):
    """FSE encoding table: stateTable and the per-symbol transform of FSE_buildCTable."""

    var log: Int
    var st: List[UInt16]
    var nb: List[Int]
    var fs: List[Int]
    var pr: List[Int]  # the probabilities it was built from

    def __init__(out self):
        self.log = 0
        self.pr = List[Int]()
        self.st = List[UInt16]()
        self.nb = List[Int]()
        self.fs = List[Int]()

    def build(mut self, norm: List[Int], nsym: Int, log: Int):
        self.log = log
        self.pr = norm.copy()
        var size = 1 << log
        var mask = size - 1
        var high = size - 1
        self.st = List[UInt16](length=size, fill=0)
        self.nb = List[Int](length=nsym, fill=0)
        self.fs = List[Int](length=nsym, fill=0)
        var cumul = List[Int](length=nsym + 1, fill=0)
        var sym = List[Int](length=size, fill=0)
        for u in range(1, nsym + 1):
            if norm[u - 1] == -1:
                cumul[u] = cumul[u - 1] + 1
                sym[high] = u - 1
                high -= 1
            else:
                cumul[u] = cumul[u - 1] + norm[u - 1]
        var step = (size >> 1) + (size >> 3) + 3
        var pos = 0
        for s in range(nsym):
            for _ in range(max(norm[s], 0)):
                sym[pos] = s
                pos = (pos + step) & mask
                while pos > high:
                    pos = (pos + step) & mask
        for u in range(size):
            var s = sym[u]
            self.st[cumul[s]] = UInt16(size + u)
            cumul[s] += 1
        var total = 0
        for s in range(nsym):
            var n = norm[s]
            if n == 0:
                self.nb[s] = ((log + 1) << 16) - size
            elif n == -1 or n == 1:
                self.nb[s] = (log << 16) - size
                self.fs[s] = total - 1
                total += 1
            else:
                var mbo = log - hb(n - 1)
                self.nb[s] = (mbo << 16) - (n << mbo)
                self.fs[s] = total - n
                total += n

    def build_rle(mut self, nsym: Int):
        """The table of a single repeated symbol: no state bits at all."""
        self.log = 0
        self.pr = List[Int](length=nsym, fill=0)
        self.st = List[UInt16](length=2, fill=0)
        self.nb = List[Int](length=nsym, fill=0)
        self.fs = List[Int](length=nsym, fill=0)

    @always_inline
    def init_state(self, sym: Int) -> Int:
        var nbo = (self.nb[sym] + (1 << 15)) >> 16
        var state = (nbo << 16) - self.nb[sym]
        return Int(self.st[(state >> nbo) + self.fs[sym]])

    @always_inline
    def put(self, mut b: BitC, mut state: Int, sym: Int):
        var nbo = (state + self.nb[sym]) >> 16
        b.add(state, nbo)
        state = Int(self.st[(state >> nbo) + self.fs[sym]])

    def cost(self, count: List[Int], nsym: Int) -> Float64:
        """Bits to code symbols with these counts (ZSTD_fseBitCost); infinite when one has no code here."""
        var bits: Float64 = 0
        for s in range(nsym):
            if count[s] == 0:
                continue
            if s >= len(self.pr) or self.pr[s] == 0:
                return 1e30
            bits += Float64(count[s]) * (Float64(self.log) - log2(Float64(max(self.pr[s], 1))))
        return bits


def write_ncount(dst: MutPointer[UInt8, _], norm: List[Int], nsym: Int, log: Int) -> Int:
    """FSE_writeNCount. Returns the header size."""
    var op = 0
    var size = 1 << log
    var remaining = size + 1
    var threshold = size
    var nb = log + 1
    var bs = 0
    var bc = 0
    var sym = 0
    var prev0 = False
    bs += (log - 5) << bc
    bc += 4
    while sym < nsym and remaining > 1:
        if prev0:
            var start = sym
            while sym < nsym and norm[sym] == 0:
                sym += 1
            if sym == nsym:
                break
            while sym >= start + 24:
                start += 24
                bs += 0xFFFF << bc
                dst[unsafe_offset=op] = UInt8(bs & 255)
                dst[unsafe_offset=op + 1] = UInt8((bs >> 8) & 255)
                op += 2
                bs >>= 16
            while sym >= start + 3:
                start += 3
                bs += 3 << bc
                bc += 2
            bs += (sym - start) << bc
            bc += 2
            if bc > 16:
                dst[unsafe_offset=op] = UInt8(bs & 255)
                dst[unsafe_offset=op + 1] = UInt8((bs >> 8) & 255)
                op += 2
                bs >>= 16
                bc -= 16
        var count = norm[sym]
        sym += 1
        var mx = (2 * threshold - 1) - remaining
        remaining -= -count if count < 0 else count
        count += 1
        if count >= threshold:
            count += mx
        bs += count << bc
        bc += nb
        if count < mx:
            bc -= 1
        prev0 = count == 1
        while remaining < threshold:
            nb -= 1
            threshold >>= 1
        if bc > 16:
            dst[unsafe_offset=op] = UInt8(bs & 255)
            dst[unsafe_offset=op + 1] = UInt8((bs >> 8) & 255)
            op += 2
            bs >>= 16
            bc -= 16
    dst[unsafe_offset=op] = UInt8(bs & 255)
    dst[unsafe_offset=op + 1] = UInt8((bs >> 8) & 255)
    return op + ((bc + 7) >> 3)


def fse_encode_all(syms: List[Int], n: Int, ct: FseC, dst: MutPointer[UInt8, _]) -> Int:
    """FSE_compress_usingCTable for n >= 2 symbols: two interleaved states (even positions on the first),
    written backwards so a decoder reads them forwards. Returns the stream size."""
    var b = BitC(dst)
    var s1: Int
    var s2: Int
    if n & 1 == 1:
        s1 = ct.init_state(syms[n - 1])
        s2 = ct.init_state(syms[n - 2])
    else:
        s2 = ct.init_state(syms[n - 1])
        s1 = ct.init_state(syms[n - 2])
    var i = n - 3
    while i >= 0:
        if i & 1 == 1:
            ct.put(b, s2, syms[i])
        else:
            ct.put(b, s1, syms[i])
        b.flush()
        i -= 1
    b.add(s2, ct.log)
    b.flush()
    b.add(s1, ct.log)
    b.flush()
    return b.close()


struct HufC(Copyable, Movable):
    """A Huffman code: bits and value per symbol, canonical as zstd's decoder rebuilds it from weights."""

    var nb: List[Int]
    var val: List[Int]
    var maxb: Int
    var last: Int  # highest symbol in use

    def __init__(out self):
        self.nb = List[Int](length=256, fill=0)
        self.val = List[Int](length=256, fill=0)
        self.maxb = 0
        self.last = 0

    def build(mut self, count: List[Int], max_bits: Int) -> Bool:
        """Lengths from counts by Huffman's algorithm, limited to max_bits; False with fewer than two symbols."""
        var syms = List[Int]()
        for s in range(256):
            if count[s] > 0:
                syms.append(s)
        var n = len(syms)
        if n < 2:
            return False
        # insertion sort by (count, symbol): n <= 256
        for i in range(1, n):
            var x = syms[i]
            var j = i - 1
            while j >= 0 and count[syms[j]] > count[x]:
                syms[j + 1] = syms[j]
                j -= 1
            syms[j + 1] = x
        var w = List[Int](length=2 * n, fill=0)
        var parent = List[Int](length=2 * n, fill=0)
        for i in range(n):
            w[i] = count[syms[i]]
        var qi = 0
        var qj = n
        var made = n
        for _ in range(n - 1):
            var picks = List[Int](length=2, fill=0)
            for k in range(2):
                if qi < n and (qj >= made or w[qi] <= w[qj]):
                    picks[k] = qi
                    qi += 1
                else:
                    picks[k] = qj
                    qj += 1
            w[made] = w[picks[0]] + w[picks[1]]
            parent[picks[0]] = made
            parent[picks[1]] = made
            made += 1
        var depth = List[Int](length=2 * n, fill=0)
        for i in range(made - 2, -1, -1):
            depth[i] = depth[parent[i]] + 1
        var ln = List[Int](length=n, fill=0)
        var mx = 0
        for i in range(n):
            ln[i] = depth[i]
            mx = max(mx, ln[i])
        if mx > max_bits:
            var kraft = 0
            for i in range(n):
                ln[i] = min(ln[i], max_bits)
                kraft += 1 << (max_bits - ln[i])
            var target = 1 << max_bits
            while kraft > target:
                var pick = -1
                for i in range(n):  # longest code still below the limit, rarest first
                    if ln[i] < max_bits and (pick < 0 or ln[i] > ln[pick] or (ln[i] == ln[pick] and count[syms[i]] < count[syms[pick]])):
                        pick = i
                ln[pick] += 1
                kraft -= 1 << (max_bits - ln[pick])
            var moved = True
            while moved and kraft < target:
                moved = False
                for i in range(n - 1, -1, -1):  # most frequent first
                    if ln[i] > 1 and kraft + (1 << (max_bits - ln[i])) <= target:
                        kraft += 1 << (max_bits - ln[i])
                        ln[i] -= 1
                        moved = True
                        break
            mx = 0
            for i in range(n):
                mx = max(mx, ln[i])
        for s in range(256):
            self.nb[s] = 0
        self.last = 0
        for i in range(n):
            self.nb[syms[i]] = ln[i]
            self.last = max(self.last, syms[i])
        self.maxb = mx
        var per = List[Int](length=16, fill=0)
        for i in range(n):
            per[ln[i]] += 1
        var vals = List[Int](length=16, fill=0)
        var m = 0
        for l in range(mx, 0, -1):
            vals[l] = m
            m += per[l]
            m >>= 1
        for s in range(256):
            if self.nb[s] > 0:
                self.val[s] = vals[self.nb[s]]
                vals[self.nb[s]] += 1
        return True

    def can_code(self, count: List[Int]) -> Bool:
        for s in range(256):
            if count[s] > 0 and self.nb[s] == 0:
                return False
        return True

    def stream_bytes(self, count: List[Int]) -> Int:
        var bits = 0
        for s in range(256):
            bits += count[s] * self.nb[s]
        return (bits + 7) >> 3

    def header(self, dst: MutPointer[UInt8, _]) -> Int:
        """The weights header of the table; returns its size."""
        var nw = self.last
        var wt = List[Int](length=256, fill=0)
        for s in range(nw):
            wt[s] = (self.maxb + 1 - self.nb[s]) if self.nb[s] > 0 else 0
        # FSE-compressed weights when that is smaller than 4 bits each
        var cnt = List[Int](length=13, fill=0)
        var top = 0
        for s in range(nw):
            cnt[wt[s]] += 1
            top = max(top, wt[s])
        var most = 0
        for k in range(13):
            most = max(most, cnt[k])
        if nw > 1 and most != nw and most != 1:
            var log = optimal_log(6, nw, top)
            var norm = List[Int](length=13, fill=0)
            if normalize(cnt, nw, top + 1, log, False, norm):
                var tmp = List[UInt8](length=300, fill=0)
                var hn = write_ncount(tmp.unsafe_ptr(), norm, top + 1, log)
                var ct = FseC()
                ct.build(norm, top + 1, log)
                var sym = List[Int](length=nw, fill=0)
                for s in range(nw):
                    sym[s] = wt[s]
                var sn = fse_encode_all(sym, nw, ct, tmp.unsafe_ptr().unsafe_offset(hn))
                var hs = hn + sn
                if hs > 1 and hs < nw // 2 and hs < 128:
                    dst[unsafe_offset=0] = UInt8(hs)
                    unsafe_memcpy(dest=dst.unsafe_offset(1), src=tmp.unsafe_ptr().unsafe_mut_cast[False](), count=hs)
                    return hs + 1
        dst[unsafe_offset=0] = UInt8(127 + nw)
        for i in range(0, nw, 2):
            dst[unsafe_offset=1 + i // 2] = UInt8((wt[i] << 4) | (wt[i + 1] if i + 1 < nw else 0))
        return 1 + (nw + 1) // 2

    def encode(self, src: ImmPointer[UInt8, _], n: Int, dst: MutPointer[UInt8, _]) -> Int:
        """One backwards-written stream of the n symbols; returns its size."""
        var b = BitC(dst)
        var i = n - 1
        while i >= 0:
            var k = 0
            while k < 4 and i >= 0:
                var s = Int(src[unsafe_offset=i])
                b.add(self.val[s], self.nb[s])
                i -= 1
                k += 1
            b.flush()
        return b.close()

    def encode4(self, src: ImmPointer[UInt8, _], n: Int, dst: MutPointer[UInt8, _]) -> Int:
        """Jump table and four streams; returns the size, or 0 when a stream does not fit the table."""
        var seg = (n + 3) // 4
        var p = 6
        var sizes = List[Int](length=4, fill=0)
        for k in range(4):
            var len = min(seg, n - k * seg) if k < 3 else n - 3 * seg
            sizes[k] = self.encode(src.unsafe_offset(k * seg), len, dst.unsafe_offset(p))
            if k < 3 and sizes[k] > 65535:
                return 0
            p += sizes[k]
        for k in range(3):
            dst[unsafe_offset=2 * k] = UInt8(sizes[k] & 255)
            dst[unsafe_offset=2 * k + 1] = UInt8(sizes[k] >> 8)
        return p
