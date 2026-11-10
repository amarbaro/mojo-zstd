"""Binary-tree match finder and optimal parser of zstd's btlazy2, btopt, btultra and btultra2 strategies
(algorithms of libzstd's zstd_opt.c and the BT part of zstd_lazy.c; BSD-3-Clause, Meta Platforms and Yann Collet)."""
from zstd.enc import Enc
from zstd.finder import count, hashm, hc_find, r32
from zstd.fse import hb

comptime OPT_NUM = 1 << 12
comptime MAXP = 1 << 30


@always_inline
def wt(stat: Int, lvl: Int) -> Int:
    """WEIGHT(): bits to code a symbol seen `stat` times, 8 fractional bits (whole bits at optLevel 0)."""
    var s = stat + 1
    var h = hb(s)
    if lvl == 0:
        return h * 256
    return h * 256 + ((s << 8) >> h)


def set_base_prices(mut e: Enc, lvl: Int):
    e.o.lbp = wt(e.o.lsum, lvl)
    e.o.llbp = wt(e.o.llsum, lvl)
    e.o.mlbp = wt(e.o.mlsum, lvl)
    e.o.ofbp = wt(e.o.ofsum, lvl)


def _downscale(mut t: List[Int], last: Int, shift: Int, base1: Bool) -> Int:
    var sm = 0
    for s in range(last + 1):
        var b = 1 if base1 else (1 if t[s] > 0 else 0)
        t[s] = b + (t[s] >> shift)
        sm += t[s]
    return sm


def _scale(mut t: List[Int], last: Int, target: Int) -> Int:
    var prev = 0
    for s in range(last + 1):
        prev += t[s]
    var factor = prev >> target
    if factor <= 1:
        return prev
    return _downscale(t, last, hb(factor), True)


def rescale(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, n: Int, lvl: Int):
    """ZSTD_rescaleFreqs: initial statistics from the block on the first call, scaled-down old ones after."""
    e.o.predef = False
    if e.o.llsum == 0:
        if n <= 8:
            e.o.predef = True
        for i in range(256):
            e.o.lfreq[i] = 0
        for i in range(n):
            e.o.lfreq[Int(p[unsafe_offset=start + i])] += 1
        e.o.lsum = _downscale(e.o.lfreq, 255, 8, False)
        var bl: List[Int] = [4, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        e.o.llsum = 0
        for i in range(36):
            e.o.llf[i] = bl[i]
            e.o.llsum += bl[i]
        for i in range(53):
            e.o.mlf[i] = 1
        e.o.mlsum = 53
        var bo: List[Int] = [6, 2, 1, 1, 2, 3, 4, 4, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        e.o.ofsum = 0
        for i in range(32):
            e.o.off_f[i] = bo[i]
            e.o.ofsum += bo[i]
    else:
        e.o.lsum = _scale(e.o.lfreq, 255, 12)
        e.o.llsum = _scale(e.o.llf, 35, 11)
        e.o.mlsum = _scale(e.o.mlf, 52, 11)
        e.o.ofsum = _scale(e.o.off_f, 31, 11)
    set_base_prices(e, lvl)


@always_inline
def lit_price(e: Enc, p: ImmPointer[UInt8, _], i: Int, lvl: Int) -> Int:
    if e.o.predef:
        return 6 * 256
    var mx = e.o.lbp - 256
    var lp = wt(e.o.lfreq[Int(p[unsafe_offset=i])], lvl)
    if lp > mx:
        lp = mx
    return e.o.lbp - lp


def ll_price(e: Enc, l: Int, lvl: Int) -> Int:
    if e.o.predef:
        return wt(l, lvl)
    if l == 131072:
        return 256 + ll_price(e, 131071, lvl)
    var c = e.ll_code(l)
    return e.llb[c] * 256 + e.o.llbp - wt(e.o.llf[c], lvl)


def match_price(e: Enc, off_base: Int, ml: Int, lvl: Int) -> Int:
    var oc = hb(off_base)
    var mb = ml - 3
    if e.o.predef:
        return wt(mb, lvl) + (16 + oc) * 256
    var price = oc * 256 + (e.o.ofbp - wt(e.o.off_f[oc], lvl))
    if lvl < 2 and oc >= 20:
        price += (oc - 19) * 2 * 256
    var mc = e.ml_code(mb)
    price += e.mlb[mc] * 256 + (e.o.mlbp - wt(e.o.mlf[mc], lvl))
    return price + 256 // 5


def update_stats(mut e: Enc, p: ImmPointer[UInt8, _], anchor: Int, ll: Int, off_base: Int, ml: Int):
    for u in range(ll):
        e.o.lfreq[Int(p[unsafe_offset=anchor + u])] += 2
    e.o.lsum += ll * 2
    e.o.llf[e.ll_code(ll)] += 1
    e.o.llsum += 1
    e.o.off_f[hb(off_base)] += 1
    e.o.ofsum += 1
    e.o.mlf[e.ml_code(ml - 3)] += 1
    e.o.mlsum += 1


def new_rep(r0: Int, r1: Int, r2: Int, off_base: Int, ll0: Bool, mut o0: Int, mut o1: Int, mut o2: Int):
    """ZSTD_newRep: the repeat offsets after a match with this offBase."""
    o0 = r0
    o1 = r1
    o2 = r2
    if off_base > 3:
        o2 = r1
        o1 = r0
        o0 = off_base - 3
    else:
        var rc = off_base - 1 + (1 if ll0 else 0)
        if rc > 0:
            var cur = r0 - 1 if rc == 3 else (r1 if rc == 1 else r2)
            if rc >= 2:
                o2 = r1
            o1 = r0
            o0 = cur


def bt_insert1(mut e: Enc, p: ImmPointer[UInt8, _], ip: Int, iend: Int, mls: Int) -> Int:
    """ZSTD_insertBt1: puts position ip into the tree; returns how many positions may be skipped."""
    var ht = e.ht.unsafe_ptr()
    var bt = e.ct.unsafe_ptr()
    var btlog = e.clog - 1
    var btmask = (1 << btlog) - 1
    var boff = e.boff
    var curr = ip + boff
    var h = hashm(p, ip, e.hlog, mls)
    var mi = Int(ht[unsafe_offset=h])
    var cl_s = 0
    var cl_l = 0
    var btlow = 0 if btmask >= curr else curr - btmask
    var sm = 2 * (curr & btmask)
    var lg = sm + 1
    var wlow = max(max(boff, 1), curr - (1 << e.wlog))
    var mend = curr + 8 + 1
    var best = 8
    var nb = 1 << e.slog
    ht[unsafe_offset=h] = UInt32(curr)
    while nb > 0 and mi >= wlow:
        nb -= 1
        var nxt = 2 * (mi & btmask)
        var ml = min(cl_s, cl_l)
        var m = mi - boff
        ml += count(p, ip + ml, m + ml, iend)
        if ml > best:
            best = ml
            if ml > mend - mi:
                mend = mi + ml
        if ip + ml == iend:
            break
        if p[unsafe_offset=m + ml] < p[unsafe_offset=ip + ml]:
            if sm >= 0:
                bt[unsafe_offset=sm] = UInt32(mi)
            cl_s = ml
            if mi <= btlow:
                sm = -1
                break
            sm = nxt + 1
            mi = Int(bt[unsafe_offset=nxt + 1])
        else:
            if lg >= 0:
                bt[unsafe_offset=lg] = UInt32(mi)
            cl_l = ml
            if mi <= btlow:
                lg = -1
                break
            lg = nxt
            mi = Int(bt[unsafe_offset=nxt])
    if sm >= 0:
        bt[unsafe_offset=sm] = 0
    if lg >= 0:
        bt[unsafe_offset=lg] = 0
    var pos = 0
    if best > 384:
        pos = min(192, best - 384)
    return max(pos, mend - (curr + 8))


def bt_update(mut e: Enc, p: ImmPointer[UInt8, _], upto: Int, iend: Int, mls: Int):
    var i = e.upd
    while i < upto:
        i += bt_insert1(e, p, i, iend, mls)
    e.upd = max(e.upd, upto)


def bt_all(
    mut e: Enc, p: ImmPointer[UInt8, _], ip: Int, ilim: Int, r0: Int, r1: Int, r2: Int, ll0: Bool, beat: Int, mls: Int, reps: Bool
) -> Int:
    """ZSTD_btGetAllMatches: inserts ip into the tree and lists the matches there that are longer than
    beat - 1, shortest first, repeat offsets first. Fills e.o.mlen / e.o.moff, returns their number."""
    if ip < e.upd:
        return 0
    bt_update(e, p, ip, ilim, mls)
    var suff = min(e.tlen, OPT_NUM - 1)
    var boff = e.boff
    var curr = ip + boff
    var minm = 3 if mls == 3 else 4
    var ht = e.ht.unsafe_ptr()
    var bt = e.ct.unsafe_ptr()
    var h = hashm(p, ip, e.hlog, mls)
    var mi = Int(ht[unsafe_offset=h])
    var btlog = e.clog - 1
    var btmask = (1 << btlog) - 1
    var btlow = 0 if btmask >= curr else curr - btmask
    var wlow = max(boff, curr - (1 << e.wlog))
    var mlow = wlow if wlow > 0 else 1
    var sm = 2 * (curr & btmask)
    var lg = sm + 1
    var mend = curr + 8 + 1
    var cl_s = 0
    var cl_l = 0
    var mnum = 0
    var nb = 1 << e.slog
    var best = beat - 1
    if reps:
        var lastr = 3 + (1 if ll0 else 0)
        for rc in range(1 if ll0 else 0, lastr):
            var ro = r0 - 1 if rc == 3 else (r0 if rc == 0 else (r1 if rc == 1 else r2))
            var rl = 0
            if ro >= 1 and ro <= ip and curr - ro >= wlow:
                if minm == 3:
                    if (r32(p, ip) & 0xFFFFFF) == (r32(p, ip - ro) & 0xFFFFFF):
                        rl = count(p, ip + 3, ip + 3 - ro, ilim) + 3
                elif r32(p, ip) == r32(p, ip - ro):
                    rl = count(p, ip + 4, ip + 4 - ro, ilim) + 4
            if rl > best:
                best = rl
                e.o.moff[mnum] = rc - (1 if ll0 else 0) + 1
                e.o.mlen[mnum] = rl
                mnum += 1
                if rl > suff or ip + rl == ilim:
                    return mnum
    if mls == 3 and best < mls:
        var h3b = min(17, e.hlog)
        var i3 = e.o.nupd3
        while i3 < ip:
            e.o.h3[Int((((r32(p, i3) & 0xFFFFFF) << 8) * 506832829) >> UInt32(32 - h3b))] = UInt32(i3 + boff)
            i3 += 1
        e.o.nupd3 = ip
        var m3 = Int(e.o.h3[Int((((r32(p, ip) & 0xFFFFFF) << 8) * 506832829) >> UInt32(32 - h3b))])
        if m3 >= mlow and curr - m3 < (1 << 18):
            var pos3 = m3 - boff
            var mlen = count(p, ip, pos3, ilim)
            if mlen >= mls:
                best = mlen
                e.o.moff[0] = curr - m3 + 3
                e.o.mlen[0] = mlen
                mnum = 1
                if mlen > suff or ip + mlen == ilim:
                    e.upd = max(e.upd, ip + 1)
                    return 1
    ht[unsafe_offset=h] = UInt32(curr)
    while nb > 0 and mi >= mlow:
        nb -= 1
        var nxt = 2 * (mi & btmask)
        var ml = min(cl_s, cl_l)
        var m = mi - boff
        ml += count(p, ip + ml, m + ml, ilim)
        if ml > best:
            if ml > mend - mi:
                mend = mi + ml
            best = ml
            e.o.moff[mnum] = curr - mi + 3
            e.o.mlen[mnum] = ml
            mnum += 1
            if ml > OPT_NUM or ip + ml == ilim:
                break
        if p[unsafe_offset=m + ml] < p[unsafe_offset=ip + ml]:
            if sm >= 0:
                bt[unsafe_offset=sm] = UInt32(mi)
            cl_s = ml
            if mi <= btlow:
                sm = -1
                break
            sm = nxt + 1
            mi = Int(bt[unsafe_offset=nxt + 1])
        else:
            if lg >= 0:
                bt[unsafe_offset=lg] = UInt32(mi)
            cl_l = ml
            if mi <= btlow:
                lg = -1
                break
            lg = nxt
            mi = Int(bt[unsafe_offset=nxt])
    if sm >= 0:
        bt[unsafe_offset=sm] = 0
    if lg >= 0:
        bt[unsafe_offset=lg] = 0
    e.upd = max(e.upd, mend - 8 - boff)
    return mnum


def bt_find(mut e: Enc, p: ImmPointer[UInt8, _], ip: Int, end: Int, mut off: Int) -> Int:
    """The longest match at ip from the tree (for btlazy2); its distance in off."""
    var mls = min(max(e.mml, 4), 6)
    var n = bt_all(e, p, ip, end, e.r0, e.r1, e.r2, False, 4, mls, False)
    if n == 0:
        return 0
    off = e.o.moff[n - 1] - 3
    return e.o.mlen[n - 1]


def _code_off(e: Enc, off_base: Int, ll: Int) -> Int:
    """The distance an offBase stands for just before a sequence with ll literals."""
    if off_base > 3:
        return off_base - 3
    var rc = off_base - 1 + (1 if ll == 0 else 0)
    if rc == 3:
        return e.r0 - 1
    return e.r0 if rc == 0 else (e.r1 if rc == 1 else e.r2)


@always_inline
def _llinc(e: Enc, l: Int, lvl: Int) -> Int:
    return ll_price(e, l, lvl) - ll_price(e, l - 1, lvl)


def opt_parse(mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int, lvl: Int) -> Int:
    """ZSTD_compressBlock_opt_generic: dynamic programming over the matches of up to 4096 bytes ahead, prices
    from running statistics. lvl 0 is btopt, 2 btultra. Returns where the unmatched tail begins."""
    rescale(e, p, start, end - start, lvl)
    var ilimit = end - 8
    var ip = start
    var anchor = start
    var mls = min(max(e.mml, 3), 6)
    var minm = 3 if e.mml == 3 else 4
    var suff = min(e.tlen, OPT_NUM - 1)
    if start + e.boff == 0:
        ip += 1
    var lml = 0
    var lof = 0
    var lll = 0
    while ip < ilimit:
        var cur = 0
        var last_pos = 0
        var short = False
        var litlen = ip - anchor
        var nb = bt_all(e, p, ip, end, e.r0, e.r1, e.r2, litlen == 0, minm, mls, True)
        if nb == 0:
            ip += 1
            continue
        e.o.nml[0] = 0
        e.o.nll[0] = litlen
        e.o.price[0] = ll_price(e, litlen, lvl)
        e.o.nr0[0] = e.r0
        e.o.nr1[0] = e.r1
        e.o.nr2[0] = e.r2
        var maxml = e.o.mlen[nb - 1]
        if maxml > suff:
            lll = 0
            lml = maxml
            lof = e.o.moff[nb - 1]
            cur = 0
            last_pos = maxml
            short = True
        if not short:
            var pos = 1
            while pos < minm:
                e.o.price[pos] = MAXP
                e.o.nml[pos] = 0
                e.o.nll[pos] = litlen + pos
                pos += 1
            for mn in range(nb):
                var ob = e.o.moff[mn]
                var mend = e.o.mlen[mn]
                while pos <= mend:
                    var sp = e.o.price[0] + match_price(e, ob, pos, lvl)
                    e.o.nml[pos] = pos
                    e.o.noff[pos] = ob
                    e.o.nll[pos] = 0
                    e.o.price[pos] = sp + ll_price(e, 0, lvl)
                    pos += 1
            last_pos = pos - 1
            e.o.price[pos] = MAXP
            cur = 1
            while cur <= last_pos:
                var inr = ip + cur
                var litlen2 = e.o.nll[cur - 1] + 1
                var price2 = e.o.price[cur - 1] + lit_price(e, p, ip + cur - 1, lvl) + _llinc(e, litlen2, lvl)
                if price2 <= e.o.price[cur]:
                    var pm_price = e.o.price[cur]
                    var pm_off = e.o.noff[cur]
                    var pm_ml = e.o.nml[cur]
                    var pm_ll = e.o.nll[cur]
                    e.o.noff[cur] = e.o.noff[cur - 1]
                    e.o.nml[cur] = e.o.nml[cur - 1]
                    e.o.nr0[cur] = e.o.nr0[cur - 1]
                    e.o.nr1[cur] = e.o.nr1[cur - 1]
                    e.o.nr2[cur] = e.o.nr2[cur - 1]
                    e.o.nll[cur] = litlen2
                    e.o.price[cur] = price2
                    if lvl >= 1 and pm_ll == 0 and _llinc(e, 1, lvl) < 0 and ip + cur < end:
                        var w1 = pm_price + lit_price(e, p, ip + cur, lvl) + _llinc(e, 1, lvl)
                        var wm = price2 + lit_price(e, p, ip + cur, lvl) + _llinc(e, litlen2 + 1, lvl)
                        if w1 < wm and w1 < e.o.price[cur + 1]:
                            var prv = cur - pm_ml
                            var a0 = 0
                            var a1 = 0
                            var a2 = 0
                            new_rep(e.o.nr0[prv], e.o.nr1[prv], e.o.nr2[prv], pm_off, e.o.nll[prv] == 0, a0, a1, a2)
                            e.o.noff[cur + 1] = pm_off
                            e.o.nml[cur + 1] = pm_ml
                            e.o.nr0[cur + 1] = a0
                            e.o.nr1[cur + 1] = a1
                            e.o.nr2[cur + 1] = a2
                            e.o.nll[cur + 1] = 1
                            e.o.price[cur + 1] = w1
                            if last_pos < cur + 1:
                                last_pos = cur + 1
                if e.o.nll[cur] == 0:
                    var prv = cur - e.o.nml[cur]
                    var a0 = 0
                    var a1 = 0
                    var a2 = 0
                    new_rep(e.o.nr0[prv], e.o.nr1[prv], e.o.nr2[prv], e.o.noff[cur], e.o.nll[prv] == 0, a0, a1, a2)
                    e.o.nr0[cur] = a0
                    e.o.nr1[cur] = a1
                    e.o.nr2[cur] = a2
                if inr > ilimit:
                    cur += 1
                    continue
                if cur == last_pos:
                    break
                if lvl == 0 and e.o.price[cur + 1] <= e.o.price[cur] + 128:
                    cur += 1
                    continue
                var ll0 = e.o.nll[cur] == 0
                var base_price = e.o.price[cur] + ll_price(e, 0, lvl)
                var nb2 = bt_all(e, p, inr, end, e.o.nr0[cur], e.o.nr1[cur], e.o.nr2[cur], ll0, minm, mls, True)
                if nb2 == 0:
                    cur += 1
                    continue
                var longest = e.o.mlen[nb2 - 1]
                if longest > suff or cur + longest >= OPT_NUM or ip + cur + longest >= end:
                    lml = longest
                    lof = e.o.moff[nb2 - 1]
                    lll = 0
                    last_pos = cur + longest
                    short = True
                    break
                for mn in range(nb2):
                    var offset = e.o.moff[mn]
                    var lastml = e.o.mlen[mn]
                    var startml = e.o.mlen[mn - 1] + 1 if mn > 0 else minm
                    var ml = lastml
                    while ml >= startml:
                        var pos2 = cur + ml
                        var pr = base_price + match_price(e, offset, ml, lvl)
                        if pos2 > last_pos or pr < e.o.price[pos2]:
                            while last_pos < pos2:
                                last_pos += 1
                                e.o.price[last_pos] = MAXP
                                e.o.nll[last_pos] = 1
                            e.o.nml[pos2] = ml
                            e.o.noff[pos2] = offset
                            e.o.nll[pos2] = 0
                            e.o.price[pos2] = pr
                        elif lvl == 0:
                            break
                        ml -= 1
                e.o.price[last_pos + 1] = MAXP
                cur += 1
            if not short:
                lll = e.o.nll[last_pos]
                lml = e.o.nml[last_pos]
                lof = e.o.noff[last_pos]
                cur = last_pos - lml
        # the cheapest path is chosen: store it
        if lml == 0:
            ip += last_pos
            continue
        if lll > 0:
            cur -= lll
        var store_end = cur + 2
        var store_start = store_end
        var stretch = cur
        e.o.noff[store_end] = lof
        e.o.nml[store_end] = lml
        e.o.nll[store_end] = lll
        while True:
            var nlit = e.o.nll[stretch]
            var nml = e.o.nml[stretch]
            e.o.nll[store_start] = nlit
            if nml == 0:
                break
            store_start -= 1
            e.o.noff[store_start] = e.o.noff[stretch]
            e.o.nml[store_start] = nml
            e.o.nll[store_start] = nlit
            stretch -= nlit + nml
        for sp in range(store_start, store_end + 1):
            var llen = e.o.nll[sp]
            var mlen = e.o.nml[sp]
            var ob = e.o.noff[sp]
            if mlen == 0:
                ip = anchor + llen
                continue
            update_stats(e, p, anchor, llen, ob, mlen)
            e.store(p, anchor, llen, _code_off(e, ob, llen), mlen)
            anchor += llen + mlen
            ip = anchor
        set_base_prices(e, lvl)
    return anchor


@always_inline
def _find[bt: Bool](mut e: Enc, p: ImmPointer[UInt8, _], ip: Int, end: Int, mut off: Int) -> Int:
    comptime if bt:
        return bt_find(e, p, ip, end, off)
    else:
        return hc_find(e, p, ip, end, off)


def lazy[bt: Bool](mut e: Enc, p: ImmPointer[UInt8, _], start: Int, end: Int, depth: Int) -> Int:
    """ZSTD_compressBlock_lazy_generic: greedy (depth 0), lazy (1) or lazy2 (2) over the hash-chain finder, or the
    binary tree when bt (btlazy2)."""
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
        var ml2 = _find[bt](e, p, ip, end, o2)
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
                if off > 0 and ip - r1 >= max(0, ip - maxd) and r32(p, ip) == r32(p, ip - r1):
                    var mr = count(p, ip + 4, ip + 4 - r1, end) + 4
                    var g2 = mr * 3
                    var gain1 = ml * 3 - hb(off + 3) + 1
                    if mr >= 4 and g2 > gain1:
                        ml = mr
                        off = 0
                        st = ip
                var o3 = 0
                var m3 = _find[bt](e, p, ip, end, o3)
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
                    var m4 = _find[bt](e, p, ip, end, o4)
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
