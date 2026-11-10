"""Finite state entropy for zstd (RFC 8878, BSD-2-Clause algorithms of Yann Collet's FSE/zstd): the backward
bit reader, normalized-count headers, decoding tables, and the two-state weight stream of Huffman headers."""
from std.bit import count_leading_zeros


@always_inline
def hb(x: Int) -> Int:
    """Index of the highest set bit (x > 0)."""
    return 63 - Int(count_leading_zeros(UInt64(x)))


@always_inline
def rd64(p: ImmPointer[UInt8, _], i: Int) -> UInt64:
    return p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]()


def bad(what: String) -> Error:
    return Error("zstd: ", what)


struct BitD(Movable):
    """libzstd's BIT_DStream: a stream read backwards from its last byte (whose top set bit is a marker)."""

    var p: ImmPointer[UInt8, ImmUntrackedOrigin]
    var cont: UInt64
    var consumed: Int
    var ptr: Int

    def __init__(out self, src: ImmPointer[UInt8, _], n: Int) raises:
        self.p = src.unsafe_origin_cast[ImmUntrackedOrigin]()
        self.cont = 0
        self.consumed = 0
        self.ptr = 0
        if n < 1:
            raise bad("corrupt input")
        var last = Int(src[unsafe_offset=n - 1])
        if last == 0:
            raise bad("corrupt input")
        if n >= 8:
            self.ptr = n - 8
            self.cont = rd64(src, n - 8)
            self.consumed = 8 - hb(last)
        else:
            for i in range(n):
                self.cont |= UInt64(src[unsafe_offset=i]) << UInt64(8 * i)
            self.consumed = 8 - hb(last) + (8 - n) * 8

    def __init__(out self, src: ImmPointer[UInt8, _], *, fast_end: Int):
        """libzstd's HUF_initFastDStream: the stream ending at src[fast_end] (8 or more bytes), no checks, a zero
        last byte starts at bit 0. Reads below its start see the bytes before it."""
        self.p = src.unsafe_origin_cast[ImmUntrackedOrigin]()
        self.ptr = fast_end - 8
        self.cont = rd64(src, fast_end - 8)
        var last = Int(src[unsafe_offset=fast_end - 1])
        self.consumed = 8 - hb(last) if last != 0 else 0

    @always_inline
    def look(self, nb: Int) -> Int:
        return Int(((self.cont << UInt64(self.consumed & 63)) >> 1) >> UInt64((63 - nb) & 63))

    @always_inline
    def read(mut self, nb: Int) -> Int:
        var v = self.look(nb)
        self.consumed += nb
        return v

    @always_inline
    def reload(mut self) -> Int:
        """0 unfinished, 1 reached the start with bits left, 2 exactly used up, 3 read past the start."""
        if self.consumed > 64:
            return 3
        if self.ptr >= 8:
            self.ptr -= self.consumed >> 3
            self.consumed &= 7
            self.cont = rd64(self.p, self.ptr)
            return 0
        if self.ptr == 0:
            return 1 if self.consumed < 64 else 2
        var nb = self.consumed >> 3
        var r = 0
        if self.ptr - nb < 0:
            nb = self.ptr
            r = 1
        self.ptr -= nb
        self.consumed -= nb * 8
        self.cont = rd64(self.p, self.ptr)
        return r

    def at_end(mut self) -> Bool:
        _ = self.reload()
        return self.ptr == 0 and self.consumed == 64


def _peek(p: ImmPointer[UInt8, _], n: Int, bp: Int, nb: Int) -> Int:
    var byte = bp >> 3
    var v = 0
    for k in range(4):
        if byte + k < n:
            v |= Int(p[unsafe_offset=byte + k]) << (8 * k)
    return (v >> (bp & 7)) & ((1 << nb) - 1)


def read_ncount(
    src: ImmPointer[UInt8, _], n: Int, max_sym: Int, mut norm: List[Int], mut log: Int, mut nsym: Int
) raises -> Int:
    """FSE_readNCount: the normalized counts of a table header into norm[0:nsym], accuracy log into log.
    Returns the header size in bytes. Reading past the end counts as zero bits, then fails the size check."""
    var acc = _peek(src, n, 0, 4) + 5
    if acc > 15:
        raise bad("table log too large")
    var bp = 4
    var remaining = (1 << acc) + 1
    var threshold = 1 << acc
    var nb = acc + 1
    var ch = 0
    var prev0 = False
    log = acc
    for i in range(len(norm)):
        norm[i] = 0
    while True:
        if prev0:
            while True:
                var r = _peek(src, n, bp, 2)
                bp += 2
                ch += r
                if r != 3:
                    break
            if ch > max_sym:
                raise bad("corrupt input")
        var mx = (2 * threshold - 1) - remaining
        var v = _peek(src, n, bp, nb)
        var count: Int
        if (v & (threshold - 1)) < mx:
            count = v & (threshold - 1)
            bp += nb - 1
        else:
            count = v & (2 * threshold - 1)
            if count >= threshold:
                count -= mx
            bp += nb
        count -= 1
        if count >= 0:
            remaining -= count
        else:
            remaining -= 1
        if ch > max_sym:
            raise bad("corrupt input")
        norm[ch] = count
        ch += 1
        prev0 = count == 0
        if remaining < threshold:
            if remaining <= 1:
                break
            nb = hb(remaining) + 1
            threshold = 1 << (nb - 1)
        if ch > max_sym:
            break
    if remaining != 1:
        raise bad("corrupt input")
    nsym = ch
    var used = (bp + 7) >> 3
    if used > n:
        raise bad("corrupt input")
    return used


def build_table(
    norm: List[Int], nsym: Int, log: Int, mut cells: List[UInt64], base: List[UInt32], bits: List[UInt8]
):
    """Decoding table, cell u = base[sym] | nextState << 32 | nbBits << 48 | bits[sym] << 56."""
    var size = 1 << log
    var high = size - 1
    var next = List[Int](length=nsym, fill=0)
    var sym = List[UInt8](length=size, fill=0)
    for s in range(nsym):
        if norm[s] == -1:
            sym[high] = UInt8(s)
            high -= 1
            next[s] = 1
        else:
            next[s] = norm[s]
    var step = (size >> 1) + (size >> 3) + 3
    var mask = size - 1
    var pos = 0
    for s in range(nsym):
        for _ in range(max(norm[s], 0)):
            sym[pos] = UInt8(s)
            pos = (pos + step) & mask
            while pos > high:
                pos = (pos + step) & mask
    for u in range(size):
        var s = Int(sym[u])
        var ns = next[s]
        next[s] = ns + 1
        var nbits = log - hb(ns)
        var nstate = (ns << nbits) - size
        cells[u] = UInt64(base[s]) | (UInt64(nstate) << 32) | (UInt64(nbits) << 48) | (UInt64(bits[s]) << 56)


def decode_weights(src: ImmPointer[UInt8, _], n: Int, mut out: List[UInt8]) raises -> Int:
    """FSE_decompress of a Huffman weight stream (two interleaved states, accuracy log <= 6): the
    number of weights, at most 255, into out."""
    var norm = List[Int](length=256, fill=0)
    var log = 0
    var nsym = 0
    var used = read_ncount(src, n, 255, norm, log, nsym)
    if log > 6:
        raise bad("table log too large")
    var ident = List[UInt32](length=256, fill=0)
    for i in range(256):
        ident[i] = UInt32(i)
    var cells = List[UInt64](length=1 << log, fill=0)
    build_table(norm, nsym, log, cells, ident, List[UInt8](length=256, fill=0))
    var b = BitD(src.unsafe_offset(used), n - used)
    var s1 = b.read(log)
    var s2 = b.read(log)
    if b.reload() == 3:
        raise bad("corrupt input")
    var op = 0
    while True:
        if op > 253:
            raise bad("too many weights")
        var c = cells[s1]
        out[op] = UInt8(c & 0xFF)
        op += 1
        s1 = Int((c >> 32) & 0xFFFF) + b.read(Int((c >> 48) & 0xFF))
        if b.reload() == 3:
            c = cells[s2]
            out[op] = UInt8(c & 0xFF)
            op += 1
            break
        if op > 253:
            raise bad("too many weights")
        c = cells[s2]
        out[op] = UInt8(c & 0xFF)
        op += 1
        s2 = Int((c >> 32) & 0xFFFF) + b.read(Int((c >> 48) & 0xFF))
        if b.reload() == 3:
            c = cells[s1]
            out[op] = UInt8(c & 0xFF)
            op += 1
            break
    return op
