"""lz4 block format: decoder with liblz4's safe-decoder verdicts, and the fast encoder of lz4.c.
Port of the algorithms in lz4.c (BSD-2-Clause, Copyright Yann Collet); see NOTICE."""
from std.bit import count_trailing_zeros
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


@always_inline
def _hash(p: Pointer[UInt8, _], i: Int, wide: Bool) -> Int:
    """lz4.c LZ4_hashPosition: 5 bytes into 12 bits for byU32 tables, 4 bytes into 13 bits for byU16."""
    if wide:
        return Int(((rd64(p, i) << 24) * 889523592379) >> 52)
    return Int((rd32(p, i) * 2654435761) >> 19)


@always_inline
def _count(p: Pointer[UInt8, _], a: Int, b: Int, limit: Int) -> Int:
    """Length of the common run of p[a:limit] and p[b:], b < a (LZ4_count)."""
    var i = a
    var m = b
    while i + 8 <= limit:
        var x = rd64(p, i) ^ rd64(p, m)
        if x != 0:
            return i + Int(count_trailing_zeros(x) >> 3) - a
        i += 8
        m += 8
    while i < limit and p[unsafe_offset=i] == p[unsafe_offset=m]:
        i += 1
        m += 1
    return i - a


def compress_block(
    base: Pointer[UInt8, _], start: Int, n: Int, dst: MutPointer[UInt8, _], cap: Int, table: MutPointer[UInt32, _], wide: Bool
) -> Int:
    """lz4.c LZ4_compress_generic at acceleration 1 over base[start:start+n], base[0:start] being the
    history (positions are indexes into `table`). Returns the compressed size, or 0 when it does not fit
    in `cap` bytes (lz4.c's conservative output checks, so a block that would just fit is refused too)."""
    var ip = start
    var anchor = start
    var iend = start + n
    var mflimit1 = iend - MFLIMIT + 1
    var matchlimit = iend - LASTLITERALS
    var op = 0
    var mt = 0
    if n >= MFLIMIT + 1:
        table[unsafe_offset=_hash(base, ip, wide)] = UInt32(ip)
        ip += 1
        var fh = _hash(base, ip, wide)
        while True:
            var fip = ip
            var step = 1
            var nb = 1 << 6
            while True:
                var h = fh
                var m = Int(table[unsafe_offset=h])
                ip = fip
                fip += step
                step = nb >> 6
                nb += 1
                if fip > mflimit1:
                    ip = -1
                    break
                fh = _hash(base, fip, wide)
                table[unsafe_offset=h] = UInt32(ip)
                if wide and m + 65535 < ip:
                    continue
                if rd32(base, m) == rd32(base, ip):
                    mt = m
                    break
            if ip < 0:
                break
            while ip > anchor and mt > 0 and base[unsafe_offset=ip - 1] == base[unsafe_offset=mt - 1]:
                ip -= 1
                mt -= 1
            while True:  # one sequence at ip/mt, then maybe a zero-literal follow-up mt
                var lit = ip - anchor
                var token = op
                op += 1
                if op + lit + (2 + 1 + LASTLITERALS) + lit // 255 > cap:
                    return 0
                if lit >= 15:
                    var r = lit - 15
                    dst[unsafe_offset=token] = 15 << 4
                    while r >= 255:
                        dst[unsafe_offset=op] = 255
                        op += 1
                        r -= 255
                    dst[unsafe_offset=op] = UInt8(r)
                    op += 1
                else:
                    dst[unsafe_offset=token] = UInt8(lit << 4)
                unsafe_memcpy(dest=dst.unsafe_offset(op), src=base.unsafe_offset(anchor), count=lit)
                op += lit
                dst.unsafe_offset(op).unsafe_bitcast[UInt16]().unsafe_store[alignment=1](UInt16(ip - mt))
                op += 2
                var mc = _count(base, ip + MINMATCH, mt + MINMATCH, matchlimit)
                ip += mc + MINMATCH
                if op + (1 + LASTLITERALS) + (mc + 240) // 255 > cap:
                    return 0
                if mc >= 15:
                    dst[unsafe_offset=token] += 15
                    mc -= 15
                    while mc >= 255:
                        dst[unsafe_offset=op] = 255
                        op += 1
                        mc -= 255
                    dst[unsafe_offset=op] = UInt8(mc)
                    op += 1
                else:
                    dst[unsafe_offset=token] += UInt8(mc)
                anchor = ip
                if ip >= mflimit1:
                    ip = -1
                    break
                table[unsafe_offset=_hash(base, ip - 2, wide)] = UInt32(ip - 2)
                var h = _hash(base, ip, wide)
                var m = Int(table[unsafe_offset=h])
                table[unsafe_offset=h] = UInt32(ip)
                if (not wide or m + 65535 >= ip) and rd32(base, m) == rd32(base, ip):
                    mt = m
                    continue
                ip += 1
                fh = _hash(base, ip, wide)
                break
            if ip < 0:
                break
    var last = iend - anchor
    if op + last + 1 + (last + 255 - 15) // 255 > cap:
        return 0
    if last >= 15:
        var r = last - 15
        dst[unsafe_offset=op] = 15 << 4
        op += 1
        while r >= 255:
            dst[unsafe_offset=op] = 255
            op += 1
            r -= 255
        dst[unsafe_offset=op] = UInt8(r)
        op += 1
    else:
        dst[unsafe_offset=op] = UInt8(last << 4)
        op += 1
    unsafe_memcpy(dest=dst.unsafe_offset(op), src=base.unsafe_offset(anchor), count=last)
    return op + last
