"""lz4 block format: decoder with liblz4's safe-decoder verdicts, and the fast encoder of lz4.c.
Port of the algorithms in lz4.c (BSD-2-Clause, Copyright Yann Collet); see NOTICE."""
from std.memory import unsafe_memcpy, unsafe_memset

comptime MINMATCH = 4
comptime LASTLITERALS = 5
comptime MFLIMIT = 12


@always_inline
def rd16(p: Pointer[UInt8, _], i: Int) -> Int:
    return Int(p.unsafe_offset(i).unsafe_bitcast[UInt16]().unsafe_load[alignment=1]())


@always_inline
def rd32(p: Pointer[UInt8, _], i: Int) -> UInt32:
    return p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_load[alignment=1]()


@always_inline
def rd64(p: Pointer[UInt8, _], i: Int) -> UInt64:
    return p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]()


@always_inline
def wr64(p: MutPointer[UInt8, _], i: Int, v: UInt64):
    p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_store[alignment=1](v)


def decode_block(
    src: Pointer[UInt8, _], sn: Int, dst: MutPointer[UInt8, _], op0: Int, lowest: Int, cap: Int
) raises -> Int:
    """Decodes one compressed block src[0:sn] to dst[op0:], returns the new end. A match may reach back
    to dst[lowest]; the block may not claim more than `cap` bytes. dst must have 16 spare bytes past
    op0 + cap. Accepts and rejects what liblz4's LZ4_decompress_safe does."""
    var ip = 0
    var op = op0
    var oend = op0 + cap
    while True:
        if ip >= sn:
            raise Error("lz4: corrupt input")
        var token = Int(src[unsafe_offset=ip])
        ip += 1
        var length = token >> 4
        if length == 15:
            if ip >= sn - 15:
                raise Error("lz4: corrupt input")
            while True:
                var s = Int(src[unsafe_offset=ip])
                ip += 1
                length += s
                if ip > sn - 15:
                    raise Error("lz4: corrupt input")
                if s != 255:
                    break
        var cpy = op + length
        if cpy > oend - MFLIMIT or ip + length > sn - (2 + 1 + LASTLITERALS):
            if ip + length != sn or cpy > oend:  # the last sequence: literals only, to the end of input
                raise Error("lz4: corrupt input")
            unsafe_memcpy(dest=dst.unsafe_offset(op), src=src.unsafe_offset(ip), count=length)
            return cpy
        unsafe_memcpy(dest=dst.unsafe_offset(op), src=src.unsafe_offset(ip), count=length)
        ip += length
        op = cpy
        var offset = rd16(src, ip)
        ip += 2
        if op - offset < lowest:
            raise Error("lz4: corrupt input")
        length = token & 15
        if length == 15:
            while True:
                var s = Int(src[unsafe_offset=ip])
                ip += 1
                length += s
                if ip > sn - (LASTLITERALS - 1):
                    raise Error("lz4: corrupt input")
                if s != 255:
                    break
        length += MINMATCH
        cpy = op + length
        if cpy > oend - LASTLITERALS:
            raise Error("lz4: corrupt input")
        var m = op - offset
        if offset == 0:  # liblz4 accepts it and copies uninitialised memory: define it as zeros
            unsafe_memset(dst.unsafe_offset(op), 0, length)
        elif offset >= length:
            unsafe_memcpy(dest=dst.unsafe_offset(op), src=dst.unsafe_offset(m).unsafe_origin_cast[MutUntrackedOrigin](), count=length)
        elif offset >= 8:
            while op < cpy:  # 8-byte steps: overlap distance >= 8, tail overwritten by the next write
                wr64(dst, op, rd64(dst, m))
                op += 8
                m += 8
        else:
            while op < cpy:
                dst[unsafe_offset=op] = dst[unsafe_offset=m]
                op += 1
                m += 1
        op = cpy
