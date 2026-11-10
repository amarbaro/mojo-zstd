"""Match finders and parsers of zstd's fast, double-fast, greedy and lazy strategies (algorithms of
libzstd's zstd_fast.c, zstd_double_fast.c, zstd_lazy.c; BSD-2-Clause, Yann Collet). Positions are offsets
into the buffer p; table entries are pos + e.boff, 0 meaning empty."""
from std.bit import count_trailing_zeros
from zstd.enc import Enc
from zstd.fse import hb


@always_inline
def r32(p: ImmPointer[UInt8, _], i: Int) -> UInt32:
    return p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_load[alignment=1]()


@always_inline
def r64(p: ImmPointer[UInt8, _], i: Int) -> UInt64:
    return p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]()


@always_inline
def count(p: ImmPointer[UInt8, _], a: Int, b: Int, limit: Int) -> Int:
    """Common run of p[a:limit] and p[b:] (b < a)."""
    var i = a
    var m = b
    while i + 8 <= limit:
        var x = r64(p, i) ^ r64(p, m)
        if x != 0:
            return i + Int(count_trailing_zeros(x) >> 3) - a
        i += 8
        m += 8
    while i < limit and p[unsafe_offset=i] == p[unsafe_offset=m]:
        i += 1
        m += 1
    return i - a


@always_inline
def hashm(p: ImmPointer[UInt8, _], i: Int, bits: Int, mls: Int) -> Int:
    if mls == 4:
        return Int((r32(p, i) * 2654435761) >> UInt32(32 - bits))
    if mls == 5:
        return Int(((r64(p, i) << 24) * 889523592379) >> UInt64(64 - bits))
    if mls == 6:
        return Int(((r64(p, i) << 16) * 227718039650203) >> UInt64(64 - bits))
    if mls == 7:
        return Int(((r64(p, i) << 8) * 58295818150454627) >> UInt64(64 - bits))
    return Int((r64(p, i) * 0xCF1BBCDCB7A56463) >> UInt64(64 - bits))


def fast(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int) -> Int:
    """ZSTD_compressBlock_fast over p[start:end]; returns the position where the unmatched tail begins."""
    var ht = e.ht.unsafe_ptr()
    var hb_ = e.hlog
    var mls = min(max(e.mml, 4), 7)
    var step0 = e.tlen + (1 if e.tlen == 0 else 0) + 1
    var maxd = 1 << e.wlog
    var boff = e.boff
    var ilimit = end - 8
    var ip = start
    var anchor = start
    if start + boff == 0:
        ip += 1
    while ip < ilimit:
        var h = hashm(p, ip, hb_, mls)
        var cand = Int(ht[unsafe_offset=h]) - boff
        var curr = ip
        ht[unsafe_offset=h] = UInt32(curr + boff)
        var low = max(0, curr - maxd)
        var ml: Int
        var r1 = e.r0
        if ip + 1 - r1 >= low and r32(p, ip + 1) == r32(p, ip + 1 - r1):
            ml = count(p, ip + 5, ip + 5 - r1, end) + 4
            ip += 1
            e.store(p, anchor, ip - anchor, r1, ml)
        else:
            if cand < low or r32(p, cand) != r32(p, ip):
                ip += ((ip - anchor) >> 8) + step0
                continue
            ml = count(p, ip + 4, cand + 4, end) + 4
            while ip > anchor and cand > low and p[unsafe_offset=ip - 1] == p[unsafe_offset=cand - 1]:
                ip -= 1
                cand -= 1
                ml += 1
            e.store(p, anchor, ip - anchor, ip - cand, ml)
        ip += ml
        anchor = ip
        if ip <= ilimit:
            ht[unsafe_offset=hashm(p, curr + 2, hb_, mls)] = UInt32(curr + 2 + boff)
            ht[unsafe_offset=hashm(p, ip - 2, hb_, mls)] = UInt32(ip - 2 + boff)
            while ip <= ilimit and ip - e.r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - e.r1):
                var r2 = e.r1
                var ml2 = count(p, ip + 4, ip + 4 - r2, end) + 4
                ht[unsafe_offset=hashm(p, ip, hb_, mls)] = UInt32(ip + boff)
                e.store(p, ip, 0, r2, ml2)
                ip += ml2
                anchor = ip
    return anchor


def dfast(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int) -> Int:
    """ZSTD_compressBlock_doubleFast: a long (8-byte) and a short (mml-byte) hash table."""
    var hl = e.ht.unsafe_ptr()
    var hs = e.ct.unsafe_ptr()
    var lbits = e.hlog
    var sbits = e.clog
    var mls = min(max(e.mml, 4), 7)
    var maxd = 1 << e.wlog
    var boff = e.boff
    var ilimit = end - 8
    var ip = start
    var anchor = start
    if start + boff == 0:
        ip += 1
    while ip < ilimit:
        var h2 = hashm(p, ip, lbits, 8)
        var h = hashm(p, ip, sbits, mls)
        var mlong = Int(hl[unsafe_offset=h2]) - boff
        var mshort = Int(hs[unsafe_offset=h]) - boff
        var curr = ip
        hl[unsafe_offset=h2] = UInt32(curr + boff)
        hs[unsafe_offset=h] = UInt32(curr + boff)
        var low = max(0, curr - maxd)
        var ml: Int
        var off: Int
        var r1 = e.r0
        var found = False
        if ip + 1 - r1 >= low and r32(p, ip + 1) == r32(p, ip + 1 - r1):
            ml = count(p, ip + 5, ip + 5 - r1, end) + 4
            ip += 1
            e.store(p, anchor, ip - anchor, r1, ml)
        else:
            var m: Int
            if mlong >= low and r64(p, mlong) == r64(p, ip):
                ml = count(p, ip + 8, mlong + 8, end) + 8
                m = mlong
                found = True
            elif mshort >= low and r32(p, mshort) == r32(p, ip):
                var h3 = hashm(p, ip + 1, lbits, 8)
                var m3 = Int(hl[unsafe_offset=h3]) - boff
                hl[unsafe_offset=h3] = UInt32(curr + 1 + boff)
                if m3 >= low and r64(p, m3) == r64(p, ip + 1):
                    ml = count(p, ip + 9, m3 + 8, end) + 8
                    ip += 1
                    m = m3
                else:
                    ml = count(p, ip + 4, mshort + 4, end) + 4
                    m = mshort
                found = True
            else:
                ip += ((ip - anchor) >> 8) + 1
                continue
            while ip > anchor and m > low and p[unsafe_offset=ip - 1] == p[unsafe_offset=m - 1]:
                ip -= 1
                m -= 1
                ml += 1
            e.store(p, anchor, ip - anchor, ip - m, ml)
        ip += ml
        anchor = ip
        if ip <= ilimit:
            hl[unsafe_offset=hashm(p, curr + 2, lbits, 8)] = UInt32(curr + 2 + boff)
            hs[unsafe_offset=hashm(p, curr + 2, sbits, mls)] = UInt32(curr + 2 + boff)
            hl[unsafe_offset=hashm(p, ip - 2, lbits, 8)] = UInt32(ip - 2 + boff)
            hs[unsafe_offset=hashm(p, ip - 2, sbits, mls)] = UInt32(ip - 2 + boff)
            while ip <= ilimit and ip - e.r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - e.r1):
                var r2 = e.r1
                var ml2 = count(p, ip + 4, ip + 4 - r2, end) + 4
                hl[unsafe_offset=hashm(p, ip, lbits, 8)] = UInt32(ip + boff)
                hs[unsafe_offset=hashm(p, ip, sbits, mls)] = UInt32(ip + boff)
                e.store(p, ip, 0, r2, ml2)
                ip += ml2
                anchor = ip
    return anchor


def hc_insert(mut e: Enc, p: ImmPointer[UInt8, _], upto: Int):
    """Fills the hash and chain tables for the positions below upto not yet in them."""
    var ht = e.ht.unsafe_ptr()
    var ct = e.ct.unsafe_ptr()
    var cmask = (1 << e.clog) - 1
    var mls = min(max(e.mml, 4), 6)
    var boff = e.boff
    var i = e.upd
    while i < upto:
        var h = hashm(p, i, e.hlog, mls)
        ct[unsafe_offset=(i + boff) & cmask] = ht[unsafe_offset=h]
        ht[unsafe_offset=h] = UInt32(i + boff)
        i += 1
    e.upd = max(e.upd, upto)


def hc_find(mut e: Enc, p: ImmPointer[UInt8, _], ip: Int, end: Int, mut off: Int) -> Int:
    """ZSTD_HcFindBestMatch: the longest match at ip among the chain of earlier positions with the same
    hash, up to 1 << slog candidates; its distance in off. 0 when there is none of 4 bytes or more."""
    hc_insert(e, p, ip)
    var ht = e.ht.unsafe_ptr()
    var ct = e.ct.unsafe_ptr()
    var cmask = (1 << e.clog) - 1
    var mls = min(max(e.mml, 4), 6)
    var boff = e.boff
    var idx = Int(ht[unsafe_offset=hashm(p, ip, e.hlog, mls)])
    var low = max(0, ip - (1 << e.wlog))
    var minchain = max(0, ip - (1 << e.clog))
    var best = 0
    var attempts = 1 << e.slog
    while idx - boff >= low and idx > 0 and attempts > 0:
        attempts -= 1
        var m = idx - boff
        if m < ip and (best == 0 or (ip + best < end and p[unsafe_offset=m + best] == p[unsafe_offset=ip + best])):
            var cur = count(p, ip, m, end)
            if cur > best:
                best = cur
                off = ip - m
                if ip + cur >= end:
                    break
        if m <= minchain:
            break
        idx = Int(ct[unsafe_offset=idx & cmask])
    return best if best >= 4 else 0


def lazy(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int, depth: Int) -> Int:
    """ZSTD_compressBlock_lazy_generic: greedy (depth 0), lazy (1) or lazy2 (2) over the hash-chain finder."""
    var ilimit = end - 8
    var ip = start
    var anchor = start
    var maxd = 1 << e.wlog
    if start + e.boff == 0:
        ip += 1
    while ip < ilimit:
        var ml = 0
        var off = 0  # distance of the best match; 0 stands for the first repeat offset
        var st = ip + 1
        var r1 = e.r0
        if ip + 1 - r1 >= max(0, ip + 1 - maxd) and r32(p, ip + 1) == r32(p, ip + 1 - r1):
            ml = count(p, ip + 5, ip + 5 - r1, end) + 4
            if depth == 0:
                e.store(p, anchor, st - anchor, r1, ml)
                ip = st + ml
                anchor = ip
                while ip <= ilimit and ip - e.r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - e.r1):
                    var r2 = e.r1
                    var ml2 = count(p, ip + 4, ip + 4 - r2, end) + 4
                    e.store(p, ip, 0, r2, ml2)
                    ip += ml2
                    anchor = ip
                continue
        var o2 = 0
        var ml2 = hc_find(e, p, ip, end, o2)
        if ml2 > ml:
            ml = ml2
            st = ip
            off = o2
        if ml < 4:
            ip += ((ip - anchor) >> 8) + 1
            continue
        if depth >= 1:
            while ip < ilimit:
                ip += 1
                var cur_code = off if off > 0 else r1  # distance in use
                var gain1: Int
                if off > 0 and ip - r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - r1):
                    var mr = count(p, ip + 4, ip + 4 - r1, end) + 4
                    var g2 = mr * 3
                    gain1 = ml * 3 - hb(off + 3) + 1
                    if mr >= 4 and g2 > gain1:
                        ml = mr
                        off = 0
                        st = ip
                var o3 = 0
                var m3 = hc_find(e, p, ip, end, o3)
                var cur = off if off > 0 else r1
                var g1 = ml * 4 - hb(cur + 3) + 4
                var g3 = m3 * 4 - hb(o3 + 3)
                if m3 >= 4 and g3 > g1:
                    ml = m3
                    off = o3
                    st = ip
                    continue
                if depth == 2 and ip < ilimit:
                    ip += 1
                    if off > 0 and ip - r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - r1):
                        var mr = count(p, ip + 4, ip + 4 - r1, end) + 4
                        var g2 = mr * 4
                        var gg1 = ml * 4 - hb(off + 3) + 1
                        if mr >= 4 and g2 > gg1:
                            ml = mr
                            off = 0
                            st = ip
                    var o4 = 0
                    var m4 = hc_find(e, p, ip, end, o4)
                    var cur2 = off if off > 0 else r1
                    var g4 = m4 * 4 - hb(o4 + 3)
                    var g1b = ml * 4 - hb(cur2 + 3) + 7
                    if m4 >= 4 and g4 > g1b:
                        ml = m4
                        off = o4
                        st = ip
                        continue
                break
        var dist = off if off > 0 else r1
        if off > 0:
            while st > anchor and st - dist > max(0, st - maxd) and p[unsafe_offset=st - 1] == p[unsafe_offset=st - dist - 1]:
                st -= 1
                ml += 1
        e.store(p, anchor, st - anchor, dist, ml)
        ip = st + ml
        anchor = ip
        while ip <= ilimit and ip - e.r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - e.r1):
            var r2 = e.r1
            var ml3 = count(p, ip + 4, ip + 4 - r2, end) + 4
            e.store(p, ip, 0, r2, ml3)
            ip += ml3
            anchor = ip
    return anchor
