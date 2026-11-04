"""lz4 frames for Mojo through the system liblz4.so.1, loaded at run time (no linker flag)."""
from std.ffi import OwnedDLHandle, external_call

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


def _inflate(z: OwnedDLHandle, ctx: Int, data: Span[UInt8, _]) raises -> List[UInt8]:
    var info: List[Int] = [0, 0, 0, 0]  # LZ4F_frameInfo_t, content size at [2]
    var used = len(data)
    _ = _chk(z, z.call["LZ4F_getFrameInfo", Int](ctx, info.unsafe_ptr(), data.unsafe_ptr(), Pointer(to=used)))
    var out = List[UInt8](unsafe_uninit_length=info[2] + 1 if 0 < info[2] < (1 << 30) else 4 * len(data) + 4096)
    var done = 0
    while True:
        var room = len(out) - done
        var dn = room
        var sn = len(data) - used
        var rc = _chk(z, z.call["LZ4F_decompress", Int](ctx, out.unsafe_ptr().unsafe_offset(done), Pointer(to=dn),
            data.unsafe_ptr().unsafe_offset(used), Pointer(to=sn), Int(0)))
        done += dn
        used += sn
        if rc == 0 and used == len(data):
            break
        if used == len(data) and dn < room:
            raise Error("lz4: truncated input")
        if dn + sn == 0 and done < len(out):
            raise Error("lz4: corrupt input")
        if done == len(out):
            out.resize(unsafe_uninit_length=2 * len(out))
    out.resize(unsafe_uninit_length=done)
    return out^


def decompress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Every frame of data, concatenated. Raises on corrupt, truncated or trailing non-lz4 data."""
    var z = OwnedDLHandle(_LIB)
    var ctx = 0
    _ = _chk(z, z.call["LZ4F_createDecompressionContext", Int](Pointer(to=ctx), UInt32(100)))
    try:
        var out = _inflate(z, ctx, data)
        _ = z.call["LZ4F_freeDecompressionContext", Int](ctx)
        return out^
    except e:
        _ = z.call["LZ4F_freeDecompressionContext", Int](ctx)
        raise e^
