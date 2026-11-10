"""lz4 frames in pure Mojo (no C library): decode accepts what liblz4 accepts, encode writes what
LZ4F_compressFrame writes at level 0 (liblz4 1.9.4, the version python-lz4 bundles), byte for byte."""
from std.memory import unsafe_memcpy
from lz4.block import compress_block, decode_block, rd32
from lz4.xxh32 import xxh32


def _bad() -> Error:
    return Error("lz4: corrupt input")


def _short() -> Error:
    return Error("lz4: truncated input")


def _reserve(mut out: List[UInt8], need: Int):
    """out's length is its capacity: grow it to at least `need`."""
    if need > len(out):
        out.resize(unsafe_uninit_length=max(need, 2 * len(out)))


def _frame(p: Pointer[UInt8, _], n: Int, mut ip: Int, mut out: List[UInt8], mut op: Int) raises:
    """One frame at p[ip:], appended at out[op:]; advances ip and op. Skippable frames decode to nothing."""
    if ip + 4 > n:
        raise _short()
    var magic = rd32(p, ip)
    if magic & 0xFFFFFFF0 == 0x184D2A50:
        if ip + 8 > n or ip + 8 + Int(rd32(p, ip + 4)) > n:
            raise _short()
        ip += 8 + Int(rd32(p, ip + 4))
        return
    if magic != 0x184D2204:
        raise _bad()
    if ip + 7 > n:
        raise _short()
    var flg = Int(p[unsafe_offset=ip + 4])
    var bd = Int(p[unsafe_offset=ip + 5])
    var hn = 2 + (8 if flg & 8 != 0 else 0) + (4 if flg & 1 != 0 else 0)  # descriptor bytes before the checksum
    if ip + 4 + hn + 1 > n:
        raise _short()
    if flg >> 6 != 1 or flg & 2 != 0 or bd & 0x8F != 0 or (bd >> 4) < 4:
        raise _bad()
    if Int((xxh32(p.unsafe_offset(ip + 4), hn) >> 8) & 0xFF) != Int(p[unsafe_offset=ip + 4 + hn]):
        raise _bad()
    var csize = -1
    if flg & 8 != 0:
        csize = Int(rd32(p, ip + 6)) | (Int(rd32(p, ip + 10)) << 32)
    ip += 4 + hn + 1
    var maxb = 1 << (8 + 2 * (bd >> 4))
    var fstart = op
    var lowest = op
    while True:
        if ip + 4 > n:
            raise _short()
        var bh = Int(rd32(p, ip))
        ip += 4
        if bh == 0:
            break
        var bsz = bh & 0x7FFFFFFF
        if bsz > maxb:
            raise _bad()
        if ip + bsz + (4 if flg & 16 != 0 else 0) > n:
            raise _short()
        _reserve(out, op + maxb + 16)
        var d = out.unsafe_ptr()
        var nop = op + bsz
        if bh & 0x80000000 != 0:
            unsafe_memcpy(dest=d.unsafe_offset(op), src=p.unsafe_offset(ip), count=bsz)
        else:
            nop = decode_block(p.unsafe_offset(ip), bsz, d, op, lowest, maxb)
        if flg & 16 != 0:
            if xxh32(p.unsafe_offset(ip), bsz) != rd32(p, ip + bsz):
                raise _bad()
            ip += 4
        ip += bsz
        op = nop
        if flg & 32 == 0:  # linked blocks see the whole frame so far
            lowest = fstart
        else:
            lowest = op
    if csize >= 0 and csize != op - fstart:
        raise _bad()
    if flg & 4 != 0:
        if ip + 4 > n:
            raise _short()
        if xxh32(out.unsafe_ptr().unsafe_offset(fstart), op - fstart) != rd32(p, ip):
            raise _bad()
        ip += 4


def decompress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Every frame of data, concatenated. Raises on corrupt, truncated or trailing non-lz4 data."""
    var p = data.unsafe_ptr()
    var out = List[UInt8](unsafe_uninit_length=4 * len(data) + 4096)
    var ip = 0
    var op = 0
    if len(data) == 0:
        raise _short()
    while ip < len(data):
        _frame(p, len(data), ip, out, op)
    out.resize(unsafe_uninit_length=op)
    return out^


def _put32(p: MutPointer[UInt8, _], i: Int, v: UInt32):
    p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_store[alignment=1](v)


def compress_with(
    data: Span[UInt8, _], block_id: Int = 7, linked: Bool = True, checksum: Bool = True, store_size: Bool = True
) raises -> List[UInt8]:
    """LZ4F_compressFrame at level 0. block_id 4..7 is the largest block (64 KiB..4 MiB), shrunk to the
    smallest that holds the input. Linked blocks see the 64 KiB before them, except when the frame is
    one block. 0 means 64 KiB."""
    var n = len(data)
    if n >= 1 << 31:
        raise Error("lz4: input over 2 GiB")
    var want = 4 if block_id == 0 else block_id
    var bid = 4
    while want > bid and n > (1 << (8 + 2 * bid)):
        bid += 1
    var bsize = 1 << (8 + 2 * bid)
    var indep = not linked or n <= bsize
    var nblocks = (n + bsize - 1) // bsize
    var out = List[UInt8](unsafe_uninit_length=19 + n + 4 * nblocks + 8)
    var o = out.unsafe_ptr()
    var src = data.unsafe_ptr()
    _put32(o, 0, 0x184D2204)
    var flg = 0x40 | (0x20 if indep else 0) | (4 if checksum else 0) | (8 if store_size and n > 0 else 0)
    o[unsafe_offset=4] = UInt8(flg)
    o[unsafe_offset=5] = UInt8(bid << 4)
    var op = 6
    if flg & 8 != 0:
        _put32(o, op, UInt32(n))
        _put32(o, op + 4, 0)
        op += 8
    o[unsafe_offset=op] = UInt8((xxh32(o.unsafe_offset(4), op - 4) >> 8) & 0xFF)
    op += 1
    var table = List[UInt32](length=8192, fill=0)
    var t = table.unsafe_ptr()
    var i = 0
    while i < n:
        var bn = min(bsize, n - i)
        var cs: Int
        if indep:
            for k in range(8192):
                t[unsafe_offset=k] = 0
            cs = compress_block(src.unsafe_offset(i), 0, bn, o.unsafe_offset(op + 4), bn - 1, t, bn >= 65547)
        else:
            cs = compress_block(src, i, bn, o.unsafe_offset(op + 4), bn - 1, t, True)
        if cs == 0:
            cs = bn
            _put32(o, op, UInt32(bn) | 0x80000000)
            unsafe_memcpy(dest=o.unsafe_offset(op + 4), src=src.unsafe_offset(i), count=bn)
        else:
            _put32(o, op, UInt32(cs))
        op += 4 + cs
        i += bn
    _put32(o, op, 0)
    op += 4
    if checksum:
        _put32(o, op, xxh32(src, n))
        op += 4
    out.resize(unsafe_uninit_length=op)
    return out^


def compress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """One frame, 4 MiB blocks at most, content size and checksum."""
    return compress_with(data)
