"""zstd block decoder (RFC 8878): literals, sequence tables, sequences. Accepts and rejects what libzstd 1.5.7
does (BSD-3-Clause algorithms, Meta Platforms and Yann Collet; see NOTICE)."""
from std.memory import unsafe_memcpy, unsafe_memset
from zstd.fse import BitD, bad, build_table, hb, read_ncount
from std.sys.defines import get_defined_int
from zstd import huf

comptime MUTANT = get_defined_int["ZSTD_MUTANT", 0]()  # gate negative control: build with -D ZSTD_MUTANT=1


def ll_norm() -> List[Int]:
    return [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]


def ml_norm() -> List[Int]:
    return [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1]


def of_norm() -> List[Int]:
    return [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]


struct Dctx(Movable):
    """Entropy state that lives across the blocks of one frame, plus the constant code tables."""

    var cus: List[List[UInt64]]  # tables in use: 0 literal lengths, 1 offsets, 2 match lengths
    var dfl: List[List[UInt64]]  # predefined tables
    var logs: List[Int]  # accuracy log of the table in use
    var base: List[List[UInt32]]  # per kind: value of a code (offset codes: the code)
    var bits: List[List[UInt8]]  # per kind: extra bits of a code
    var fse_ok: Bool
    var huf: List[UInt16]
    var huf_log: Int
    var lit_ok: Bool
    var lit: List[UInt8]
    var wts: List[UInt8]
    var norm: List[Int]
    var rep0: Int
    var rep1: Int
    var rep2: Int

    def __init__(out self):
        var lb = List[UInt32](length=36, fill=0)
        var lbits: List[UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        for i in range(16):
            lb[i] = UInt32(i)
        var v = 16
        for i in range(16, 36):
            lb[i] = UInt32(v)
            v += 1 << Int(lbits[i])
        var mb = List[UInt32](length=53, fill=0)
        var mbits: List[UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        v = 3
        for i in range(53):
            mb[i] = UInt32(v)
            v += 1 << Int(mbits[i])
        var ob = List[UInt32](length=32, fill=0)
        var obits = List[UInt8](length=32, fill=0)
        for i in range(32):
            ob[i] = UInt32(i)
            obits[i] = UInt8(i)
        self.base = [lb^, ob^, mb^]
        self.bits = [lbits^, obits^, mbits^]
        self.cus = [List[UInt64](length=512, fill=0), List[UInt64](length=256, fill=0), List[UInt64](length=512, fill=0)]
        self.dfl = [List[UInt64](length=64, fill=0), List[UInt64](length=32, fill=0), List[UInt64](length=64, fill=0)]
        self.logs = [6, 5, 6]
        self.fse_ok = False
        self.huf = List[UInt16](length=4096, fill=0)
        self.huf_log = 0
        self.lit_ok = False
        self.lit = List[UInt8]()  # grown to the largest literals section seen
        self.wts = List[UInt8](length=300, fill=0)
        self.norm = List[Int](length=64, fill=0)
        self.rep0 = 1
        self.rep1 = 4
        self.rep2 = 8
        build_table(ll_norm(), 36, 6, self.dfl[0], self.base[0], self.bits[0])
        build_table(of_norm(), 29, 5, self.dfl[1], self.base[1], self.bits[1])
        build_table(ml_norm(), 53, 6, self.dfl[2], self.base[2], self.bits[2])

    def new_frame(mut self):
        self.fse_ok = False
        self.lit_ok = False
        self.rep0 = 1
        self.rep1 = 4
        self.rep2 = 8


def _literals(
    mut dc: Dctx, src: ImmPointer[UInt8, _], n: Int, bmax: Int, mut lp: ImmPointer[UInt8, ImmUntrackedOrigin], mut ln: Int,
    mut direct: Bool
) raises -> Int:
    """Literals section at src[0:n]: sets lp/ln to the literal bytes, returns the section size. direct is set
    when they are raw and followed by 32 more bytes, which libzstd reads in place."""
    if n < 2:
        raise bad("corrupt input")
    var b0 = Int(src[unsafe_offset=0])
    var typ = b0 & 3
    var fmt = (b0 >> 2) & 3
    if typ < 2:  # raw or RLE
        var hs: Int
        var sz: Int
        if fmt == 1:
            hs = 2
            sz = (b0 >> 4) | (Int(src[unsafe_offset=1]) << 4)
        elif fmt == 3:
            if n < 3:
                raise bad("corrupt input")
            hs = 3
            sz = (b0 >> 4) | (Int(src[unsafe_offset=1]) << 4) | (Int(src[unsafe_offset=2]) << 12)
        else:
            hs = 1
            sz = b0 >> 3
        if sz > bmax:
            raise bad("corrupt input")
        if typ == 0:
            if hs + sz > n:
                raise bad("corrupt input")
            lp = src.unsafe_offset(hs).unsafe_origin_cast[ImmUntrackedOrigin]()
            ln = sz
            direct = hs + sz + 32 <= n
            return hs + sz
        if hs + 1 > n:
            raise bad("corrupt input")
        if len(dc.lit) < sz + 64:
            dc.lit.resize(unsafe_uninit_length=sz + 64)
        unsafe_memset(dc.lit.unsafe_ptr(), src[unsafe_offset=hs], sz)
        lp = dc.lit.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[ImmUntrackedOrigin]()
        ln = sz
        return hs + 1
    if typ == 3 and not dc.lit_ok:
        raise bad("dictionary corrupted")
    if n < 5:
        raise bad("corrupt input")
    var hs: Int
    var lsz: Int
    var csz: Int
    var h = Int(src[unsafe_offset=0]) | (Int(src[unsafe_offset=1]) << 8) | (Int(src[unsafe_offset=2]) << 16) | (Int(src[unsafe_offset=3]) << 24)
    if fmt < 2:
        hs = 3
        lsz = (h >> 4) & 0x3FF
        csz = (h >> 14) & 0x3FF
    elif fmt == 2:
        hs = 4
        lsz = (h >> 4) & 0x3FFF
        csz = h >> 18
    else:
        hs = 5
        lsz = (h >> 4) & 0x3FFFF
        csz = (h >> 22) + (Int(src[unsafe_offset=4]) << 10)
    if lsz > bmax:
        raise bad("corrupt input")
    if fmt != 0 and lsz < 6:
        raise bad("corrupt input")
    if csz + hs > n:
        raise bad("corrupt input")
    var sp = src.unsafe_offset(hs)
    var sn = csz
    if typ == 2:
        var used = huf.read_table(sp, sn, dc.huf, dc.huf_log, dc.wts)
        if used >= sn:
            raise bad("corrupt input")
        sp = sp.unsafe_offset(used)
        sn -= used
    if len(dc.lit) < lsz + 64:
        dc.lit.resize(unsafe_uninit_length=lsz + 64)
    huf.decode(dc.huf, dc.huf_log, sp, sn, fmt != 0, dc.lit.unsafe_ptr(), lsz)
    dc.lit_ok = True
    lp = dc.lit.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[ImmUntrackedOrigin]()
    ln = lsz
    return hs + csz


def _seq_table(
    mut dc: Dctx, kind: Int, mode: Int, src: ImmPointer[UInt8, _], n: Int, max_sym: Int, max_log: Int
) raises -> Int:
    if mode == 0:
        dc.logs[kind] = 5 if kind == 1 else 6
        for i in range(1 << dc.logs[kind]):
            dc.cus[kind][i] = dc.dfl[kind][i]
        return 0
    if mode == 1:
        if n < 1:
            raise bad("corrupt input")
        var s = Int(src[unsafe_offset=0])
        if s > max_sym:
            raise bad("corrupt input")
        dc.cus[kind][0] = UInt64(dc.base[kind][s]) | (UInt64(dc.bits[kind][s]) << 56)
        dc.logs[kind] = 0
        return 1
    if mode == 3:
        if not dc.fse_ok:
            raise bad("corrupt input")
        return 0
    var log = 0
    var nsym = 0
    var used = read_ncount(src, n, max_sym, dc.norm, log, nsym)
    if log > max_log:
        raise bad("corrupt input")
    build_table(dc.norm, nsym, log, dc.cus[kind], dc.base[kind], dc.bits[kind])
    dc.logs[kind] = log
    return used


def decode_block(
    mut dc: Dctx, src: ImmPointer[UInt8, _], n: Int, dst: MutPointer[UInt8, _], op0: Int, lo: Int, bmax: Int, omax: Int, omax_raw: Int
) raises -> Int:
    """One compressed block src[0:n] appended at dst[op0:]. A match may reach back to dst[lo]. Compressed size and
    literals are limited to bmax, the output to omax (omax_raw when the literals are raw and read in place); dst needs 32 spare bytes past op0 + omax. Returns the new end."""
    if n > bmax:
        raise bad("corrupt input")
    var lp = src.unsafe_origin_cast[ImmUntrackedOrigin]()
    var ln = 0
    var direct = False
    var ip = _literals(dc, src, n, bmax, lp, ln, direct)
    if ip >= n:
        raise bad("corrupt input")
    var nseq = Int(src[unsafe_offset=ip])
    ip += 1
    if nseq > 127:
        if nseq == 255:
            if ip + 2 > n:
                raise bad("corrupt input")
            nseq = Int(src[unsafe_offset=ip]) + (Int(src[unsafe_offset=ip + 1]) << 8) + 0x7F00
            ip += 2
        else:
            if ip >= n:
                raise bad("corrupt input")
            nseq = ((nseq - 128) << 8) + Int(src[unsafe_offset=ip])
            ip += 1
    var op = op0
    if nseq == 0:
        if ip != n:
            raise bad("corrupt input")
        unsafe_memcpy(dest=dst.unsafe_offset(op), src=lp, count=ln)
        return op + ln
    if ip + 1 > n:
        raise bad("corrupt input")
    var modes = Int(src[unsafe_offset=ip])
    if modes & 3 != 0:
        raise bad("corrupt input")
    ip += 1
    ip += _seq_table(dc, 0, modes >> 6, src.unsafe_offset(ip), n - ip, 35, 9)
    ip += _seq_table(dc, 1, (modes >> 4) & 3, src.unsafe_offset(ip), n - ip, 31, 8)
    ip += _seq_table(dc, 2, (modes >> 2) & 3, src.unsafe_offset(ip), n - ip, 52, 9)
    var bd = BitD(src.unsafe_offset(ip), n - ip)
    dc.fse_ok = True
    var llt = dc.cus[0].unsafe_ptr()
    var oft = dc.cus[1].unsafe_ptr()
    var mlt = dc.cus[2].unsafe_ptr()
    var lls = bd.read(dc.logs[0])
    _ = bd.reload()
    var ofs = bd.read(dc.logs[1])
    _ = bd.reload()
    var mls = bd.read(dc.logs[2])
    _ = bd.reload()
    var r0 = dc.rep0
    var r1 = dc.rep1
    var r2 = dc.rep2
    var oend = op0 + (omax_raw if direct else omax)
    var litp = 0
    for k in range(nseq):
        var lc = llt[unsafe_offset=lls]
        var mc = mlt[unsafe_offset=mls]
        var oc = oft[unsafe_offset=ofs]
        var ll = Int(lc & 0xFFFFFFFF)
        var ml = Int(mc & 0xFFFFFFFF)
        var llb = Int(lc >> 56)
        var mlb = Int(mc >> 56)
        var ofb = Int(oc >> 56)
        var offset: Int
        if ofb > 1:
            offset = (1 << ofb) - 3 + bd.read(ofb)
            r2 = r1
            r1 = r0
            r0 = offset
        else:
            var ll0 = 1 if ll == 0 else 0
            if ofb == 0:
                offset = r1 if ll0 == 1 else r0
                if ll0 == 1:
                    r1 = r0
                    r0 = offset
            else:
                var code = 1 + ll0 + bd.read(1)  # repeat code 1..3
                var t: Int
                if code == 3:
                    t = r0 - 1
                elif code == 2:
                    t = r2
                else:
                    t = r1
                if t == 0:
                    t = -1
                if code != 1:
                    r2 = r1
                r1 = r0
                r0 = t
                offset = t
        if mlb > 0:
            ml += bd.read(mlb)
        if llb + mlb + ofb >= 31:
            _ = bd.reload()
        if llb > 0:
            ll += bd.read(llb)
        if k + 1 < nseq:
            lls = Int((lc >> 32) & 0xFFFF) + bd.read(Int((lc >> 48) & 0xFF))
            mls = Int((mc >> 32) & 0xFFFF) + bd.read(Int((mc >> 48) & 0xFF))
            ofs = Int((oc >> 32) & 0xFFFF) + bd.read(Int((oc >> 48) & 0xFF))
            _ = bd.reload()
            comptime if MUTANT == 1:
                if k == 2:
                    lls = lls ^ 1  # one FSE state off
        if ll > ln - litp or op + ll + ml > oend:
            raise bad("corrupt input")
        unsafe_memcpy(dest=dst.unsafe_offset(op), src=lp.unsafe_offset(litp), count=ll)
        litp += ll
        op += ll
        if offset > op - lo or offset <= 0:
            raise bad("corrupt input")
        var m = op - offset
        var cpy = op + ml
        if offset >= ml:
            unsafe_memcpy(dest=dst.unsafe_offset(op), src=dst.unsafe_offset(m).unsafe_origin_cast[MutUntrackedOrigin](), count=ml)
            op = cpy
        else:
            while op < cpy:
                dst[unsafe_offset=op] = dst[unsafe_offset=m]
                op += 1
                m += 1
    if not bd.at_end():
        raise bad("corrupt input")
    if ln - litp > oend - op:
        raise bad("corrupt input")
    unsafe_memcpy(dest=dst.unsafe_offset(op), src=lp.unsafe_offset(litp), count=ln - litp)
    dc.rep0 = r0
    dc.rep1 = r1
    dc.rep2 = r2
    return op + ln - litp
