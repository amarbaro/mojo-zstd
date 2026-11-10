"""Huffman literals for zstd (RFC 8878; algorithms of libzstd's HUF, BSD-3-Clause, Meta Platforms and Yann Collet): the weight
header, a one-level decoding table of up to 12 bits, and the one- and four-stream backward decoders."""
from std.memory import unsafe_memset
from zstd.fse import BitD, bad, decode_weights, hb


def read_table(
    src: ImmPointer[UInt8, _], n: Int, mut tbl: List[UInt16], mut log: Int, mut wts: List[UInt8]
) raises -> Int:
    """HUF_readDTableX1: weights header at src[0:n] into the table tbl (entry = symbol | nbBits << 8, size
    1 << log). Returns the header size. wts is scratch of 256 bytes."""
    if n < 1:
        raise bad("corrupt input")
    var hdr = Int(src[unsafe_offset=0])
    var nw: Int
    var used: Int
    if hdr >= 128:
        nw = hdr - 127
        used = (nw + 1) // 2
        if used + 1 > n:
            raise bad("corrupt input")
        for i in range(0, nw, 2):
            var b = Int(src[unsafe_offset=1 + i // 2])
            wts[i] = UInt8(b >> 4)
            wts[i + 1] = UInt8(b & 15)
    else:
        used = hdr
        if used + 1 > n:
            raise bad("corrupt input")
        nw = decode_weights(src.unsafe_offset(1), used, wts)
    var rank = List[Int](length=14, fill=0)
    var total = 0
    for i in range(nw):
        var w = Int(wts[i])
        if w > 12:
            raise bad("corrupt input")
        rank[w] += 1
        total += (1 << w) >> 1
    if total == 0:
        raise bad("corrupt input")
    log = hb(total) + 1
    if log > 12:
        raise bad("corrupt input")
    var rest = (1 << log) - total
    if (1 << hb(rest)) != rest:
        raise bad("corrupt input")
    var last = hb(rest) + 1
    wts[nw] = UInt8(last)
    rank[last] += 1
    if rank[1] < 2 or rank[1] & 1 != 0:
        raise bad("corrupt input")
    var start = List[Int](length=14, fill=0)
    var s = 0
    for w in range(1, log + 1):
        start[w] = s
        s += rank[w] << (w - 1)
    for sym in range(nw + 1):
        var w = Int(wts[sym])
        if w == 0:
            continue
        var len = 1 << (w - 1)
        var e = UInt16(sym) | (UInt16(log + 1 - w) << 8)
        for k in range(len):
            tbl[start[w] + k] = e
        start[w] += len
    return used + 1


def _stream(
    tbl: List[UInt16], log: Int, mut b: BitD, dst: MutPointer[UInt8, _], count: Int
):
    var t = tbl.unsafe_ptr()
    var i = 0
    while i < count:
        _ = b.reload()
        var k = min(4, count - i)
        for j in range(k):
            var e = Int(t[unsafe_offset=b.look(log)])
            b.consumed += e >> 8
            dst[unsafe_offset=i + j] = UInt8(e & 255)
        i += k


def _checked(
    tbl: List[UInt16], log: Int, src: ImmPointer[UInt8, _], n: Int, dst: MutPointer[UInt8, _], count: Int
) raises:
    """One stream that must hold exactly count symbols and end on its first bit."""
    var b = BitD(src, n)
    _stream(tbl, log, b, dst, count)
    if not b.at_end():
        raise bad("corrupt input")


def decode(
    tbl: List[UInt16], log: Int, src: ImmPointer[UInt8, _], n: Int, four: Bool, dst: MutPointer[UInt8, _], count: Int
) raises:
    """count literals from the Huffman streams src[0:n] (one stream, or a jump table and four)."""
    if not four:
        _checked(tbl, log, src, n, dst, count)
        return
    if n < 10:
        raise bad("corrupt input")
    var l1 = Int(src[unsafe_offset=0]) | (Int(src[unsafe_offset=1]) << 8)
    var l2 = Int(src[unsafe_offset=2]) | (Int(src[unsafe_offset=3]) << 8)
    var l3 = Int(src[unsafe_offset=4]) | (Int(src[unsafe_offset=5]) << 8)
    if 6 + l1 + l2 + l3 > n:
        raise bad("corrupt input")
    var l4 = n - 6 - l1 - l2 - l3
    var seg = (count + 3) // 4
    var e1 = 6 + l1
    var e2 = e1 + l2
    var e3 = e2 + l3
    if log <= 11 and l1 >= 8 and l2 >= 8 and l3 >= 8 and l4 >= 8 and 3 * seg < count:
        # libzstd's fast loop: no marker or end checks, and a stream that reads below its start reads
        # the bytes before it
        var b1 = BitD(src, fast_end=e1)
        var b2 = BitD(src, fast_end=e2)
        var b3 = BitD(src, fast_end=e3)
        var b4 = BitD(src, fast_end=n)
        _stream(tbl, log, b1, dst, seg)
        _stream(tbl, log, b2, dst.unsafe_offset(seg), seg)
        _stream(tbl, log, b3, dst.unsafe_offset(2 * seg), seg)
        _stream(tbl, log, b4, dst.unsafe_offset(3 * seg), count - 3 * seg)
        return
    _checked(tbl, log, src.unsafe_offset(6), l1, dst, seg)
    _checked(tbl, log, src.unsafe_offset(e1), l2, dst.unsafe_offset(seg), seg)
    _checked(tbl, log, src.unsafe_offset(e2), l3, dst.unsafe_offset(2 * seg), seg)
    _checked(tbl, log, src.unsafe_offset(e3), l4, dst.unsafe_offset(3 * seg), count - 3 * seg)
