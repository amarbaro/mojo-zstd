"""lz4 frames for Mojo through the system liblz4.so.1, loaded at run time (no linker flag)."""
from std.ffi import OwnedDLHandle, external_call
from std.memory import unsafe_memcpy
from lz4.block import decode_block, rd32
from lz4.xxh32 import xxh32

comptime _LIB = "liblz4.so.1"


def _chk(z: OwnedDLHandle, rc: Int) raises -> Int:
    if z.call["LZ4F_isError", UInt32](rc) != 0:
        var p = z.call["LZ4F_getErrorName", Pointer[UInt8, ImmutAnyOrigin]](rc)
        raise Error("lz4: ", String(unsafe_from_utf8=Span(unsafe_ptr=p, length=external_call["strlen", Int](p))))
    return rc


def _prefs(n: Int) -> List[Int]:
    """LZ4F_preferences_t: 4 MiB blocks, content checksum on, content size n, level 0."""
    return [7, 1, n, 0, 0, 0, 0]


def compress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """One frame, with content size and checksum."""
    var z = OwnedDLHandle(_LIB)
    var p = _prefs(len(data))
    var out = List[UInt8](unsafe_uninit_length=z.call["LZ4F_compressFrameBound", Int](len(data), p.unsafe_ptr()))
    var n = z.call["LZ4F_compressFrame", Int](out.unsafe_ptr(), len(out), data.unsafe_ptr(), len(data), p.unsafe_ptr())
    out.resize(unsafe_uninit_length=_chk(z, n))
    return out^


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
