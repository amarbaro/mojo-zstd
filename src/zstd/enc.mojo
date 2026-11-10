"""zstd block encoder: the sequence store, literals and sequences sections, FSE and Huffman table choice and
reuse across blocks (RFC 8878; algorithms of libzstd's zstd_compress.c, BSD-3-Clause, Meta Platforms and Yann Collet)."""
from std.memory import unsafe_memcpy, unsafe_memset
from zstd.block import ll_norm, ml_norm, of_norm, Dctx
from zstd.entropy import BitC, FseC, HufC, fse_encode_all, normalize, optimal_log, write_ncount
from std.sys.defines import get_defined_int
from zstd.fse import hb

comptime MUTANT = get_defined_int["ZSTD_MUTANT", 0]()  # gate negative control: -D ZSTD_MUTANT=2 corrupts an FSE state


struct OptS(Movable):
    """Statistics and scratch of the optimal parser (zstd_opt.c: optState_t, price and match tables)."""

    var lfreq: List[Int]
    var llf: List[Int]
    var mlf: List[Int]
    var off_f: List[Int]
    var lsum: Int
    var llsum: Int
    var mlsum: Int
    var ofsum: Int
    var lbp: Int
    var llbp: Int
    var mlbp: Int
    var ofbp: Int
    var predef: Bool
    var price: List[Int]  # the nodes of the price table
    var noff: List[Int]
    var nml: List[Int]
    var nll: List[Int]
    var nr0: List[Int]
    var nr1: List[Int]
    var nr2: List[Int]
    var mlen: List[Int]  # matches found at one position, longest last
    var moff: List[Int]
    var h3: List[UInt32]
    var nupd3: Int

    def __init__(out self):
        self.lfreq = List[Int](length=256, fill=0)
        self.llf = List[Int](length=36, fill=0)
        self.mlf = List[Int](length=53, fill=0)
        self.off_f = List[Int](length=32, fill=0)
        self.lsum = 0
        self.llsum = 0
        self.mlsum = 0
        self.ofsum = 0
        self.lbp = 0
        self.llbp = 0
        self.mlbp = 0
        self.ofbp = 0
        self.predef = False
        self.price = List[Int]()
        self.noff = List[Int]()
        self.nml = List[Int]()
        self.nll = List[Int]()
        self.nr0 = List[Int]()
        self.nr1 = List[Int]()
        self.nr2 = List[Int]()
        self.mlen = List[Int]()
        self.moff = List[Int]()
        self.h3 = List[UInt32]()
        self.nupd3 = 0

    def alloc(mut self):
        var n = 4096 + 8
        self.price = List[Int](length=n, fill=0)
        self.noff = List[Int](length=n, fill=0)
        self.nml = List[Int](length=n, fill=0)
        self.nll = List[Int](length=n, fill=0)
        self.nr0 = List[Int](length=n, fill=0)
        self.nr1 = List[Int](length=n, fill=0)
        self.nr2 = List[Int](length=n, fill=0)
        self.mlen = List[Int](length=n, fill=0)
        self.moff = List[Int](length=n, fill=0)


def _enc_lits(h: HufC, src: ImmPointer[UInt8, _], n: Int, four: Bool, dst: MutPointer[UInt8, _]) -> Int:
    return h.encode4(src, n, dst) if four else h.encode(src, n, dst)


struct Enc(Movable):
    """Encoder state across the blocks of one frame."""

    # parameters (ZSTD_compressionParameters)
    var level: Int
    var wlog: Int
    var clog: Int
    var hlog: Int
    var slog: Int
    var mml: Int
    var tlen: Int
    var strat: Int  # 1 fast, 2 dfast, 3 greedy, 4 lazy, 5 lazy2, 6 btlazy2, 7 btopt, 8 btultra, 9 btultra2
    # match finder state
    var ht: List[UInt32]
    var ct: List[UInt32]
    var boff: Int  # table index of buffer position 0
    var upd: Int  # chain tables are filled up to this position
    var r0: Int
    var r1: Int
    var r2: Int
    # sequence store
    var sll: List[UInt32]
    var sof: List[UInt32]
    var sml: List[UInt32]
    var nseq: Int
    var lits: List[UInt8]
    var nlit: Int
    # entropy state of the previous compressed block
    var phuf: HufC
    var phuf_ok: Bool
    var pfse: List[FseC]  # 0 literal lengths, 1 offsets, 2 match lengths
    var pfse_ok: List[Bool]
    var dfse: List[FseC]  # predefined tables
    var pend_fse: List[FseC]  # tables of the block being built, valid after commit()
    var pend_ok: List[Bool]
    var llcode: List[UInt8]
    var mlcode: List[UInt8]
    var llbase: List[Int]
    var llb: List[Int]
    var mlb: List[Int]
    var pend_huf: HufC
    var o: OptS
    var first: Bool  # no block written yet in this frame
    var savings: Int  # input minus output bytes of the frame so far, header counted
    var mlbase: List[Int]

    def __init__(out self):
        self.level = 3
        self.wlog = 17
        self.clog = 16
        self.hlog = 17
        self.slog = 1
        self.mml = 5
        self.tlen = 0
        self.strat = 2
        self.ht = List[UInt32]()
        self.ct = List[UInt32]()
        self.boff = 0
        self.upd = 0
        self.r0 = 1
        self.r1 = 4
        self.r2 = 8
        self.sll = List[UInt32]()
        self.sof = List[UInt32]()
        self.sml = List[UInt32]()
        self.nseq = 0
        self.lits = List[UInt8]()
        self.nlit = 0
        self.phuf = HufC()
        self.phuf_ok = False
        self.pfse = [FseC(), FseC(), FseC()]
        self.pfse_ok = [False, False, False]
        self.dfse = [FseC(), FseC(), FseC()]
        self.pend_fse = [FseC(), FseC(), FseC()]
        self.pend_ok = [False, False, False]
        self.dfse[0].build(ll_norm(), 36, 6)
        self.dfse[1].build(of_norm(), 29, 5)
        self.dfse[2].build(ml_norm(), 53, 6)
        # code of a literal length / match length by scanning the base tables of the decoder
        self.llbase = List[Int](length=36, fill=0)
        self.llb = List[Int](length=36, fill=0)
        self.mlb = List[Int](length=53, fill=0)
        self.pend_huf = HufC()
        self.o = OptS()
        self.first = True
        self.savings = 0
        self.mlbase = List[Int](length=53, fill=0)
        self.llcode = List[UInt8](length=128, fill=0)
        self.mlcode = List[UInt8](length=128, fill=0)
        var dc = Dctx()
        for i in range(36):
            self.llbase[i] = Int(dc.base[0][i])
            self.llb[i] = Int(dc.bits[0][i])
        for i in range(53):
            self.mlbase[i] = Int(dc.base[2][i])
            self.mlb[i] = Int(dc.bits[2][i])
        for v in range(128):
            var c = 0
            while c < 35 and self.llbase[c + 1] <= v:
                c += 1
            self.llcode[v] = UInt8(c)
            c = 0
            while c < 52 and self.mlbase[c + 1] <= v + 3:
                c += 1
            self.mlcode[v] = UInt8(c)

    def reset_frame(mut self):
        self.r0 = 1
        self.r1 = 4
        self.r2 = 8
        self.phuf_ok = False
        self.pfse_ok = [False, False, False]
        self.nseq = 0
        self.nlit = 0
        self.first = True
        self.savings = 0
        self.o.lsum = 0
        self.o.llsum = 0
        self.o.mlsum = 0
        self.o.ofsum = 0
        self.o.nupd3 = 0

    def ll_code(self, ll: Int) -> Int:
        if ll < 128:
            return Int(self.llcode[ll])
        return hb(ll) + 19

    def ml_code(self, mb: Int) -> Int:
        if mb < 128:
            return Int(self.mlcode[mb])
        var c = 43
        while c < 52 and self.mlbase[c + 1] <= mb + 3:
            c += 1
        return c

    def rep_code(self, offset: Int, ll: Int) -> Int:
        """The offBase that codes this offset: a repeat code when one fits, else offset + 3."""
        if ll > 0:
            if offset == self.r0:
                return 1
            if offset == self.r1:
                return 2
            if offset == self.r2:
                return 3
        else:
            if offset == self.r1:
                return 1
            if offset == self.r2:
                return 2
            if offset == self.r0 - 1 and offset > 0:
                return 3
        return offset + 3

    def store(mut self, src: ImmPointer[UInt8, _], anchor: Int, ll: Int, offset: Int, ml: Int):
        """Appends the sequence: ll literals from src[anchor:], a match of ml bytes at distance offset."""
        var code = self.rep_code(offset, ll)
        if self.nseq == len(self.sll):
            var cap = max(1024, 2 * len(self.sll))
            self.sll.resize(unsafe_uninit_length=cap)
            self.sof.resize(unsafe_uninit_length=cap)
            self.sml.resize(unsafe_uninit_length=cap)
        if self.nlit + ll + 64 > len(self.lits):
            self.lits.resize(unsafe_uninit_length=max(self.nlit + ll + 64, 2 * len(self.lits)))
        unsafe_memcpy(dest=self.lits.unsafe_ptr().unsafe_offset(self.nlit), src=src.unsafe_offset(anchor), count=ll)
        self.nlit += ll
        self.sll[self.nseq] = UInt32(ll)
        self.sof[self.nseq] = UInt32(code)
        self.sml[self.nseq] = UInt32(ml - 3)
        self.nseq += 1
        if code > 3:
            self.r2 = self.r1
            self.r1 = self.r0
            self.r0 = offset
        else:
            var idx = code - 1 + (1 if ll == 0 else 0)
            if idx > 0:
                var cur = self.r0 - 1 if idx == 3 else (self.r1 if idx == 1 else self.r2)
                if idx >= 2:
                    self.r2 = self.r1
                self.r1 = self.r0
                self.r0 = cur

    # ---- literals section -------------------------------------------------------------------------

    def literals(mut self, dst: MutPointer[UInt8, _], mut commit_huf: Bool) -> Int:
        """The literals section for lits[:nlit] at dst; returns its size. commit_huf is set when a new table
        was written (it becomes the table a later block may repeat)."""
        var n = self.nlit
        var src = self.lits.unsafe_ptr().unsafe_mut_cast[False]()
        commit_huf = False
        if n == 0:
            dst[unsafe_offset=0] = 0
            return 1
        var cnt = List[Int](length=256, fill=0)
        for i in range(n):
            cnt[Int(src[unsafe_offset=i])] += 1
        var top = 0
        for s in range(256):
            top = max(top, cnt[s])
        if top == n and n > 1:  # one byte value
            return self._lit_small(dst, 1, n, Int(src[unsafe_offset=0]))
        var min_lit = 6 if self.phuf_ok else 8  # libzstd waits for 8 << (9 - strategy) bytes; trying is cheap and costs no ratio
        if n >= min_lit:
            var minlog = (self.strat - 1) if self.strat >= 8 else 6
            var gain = (n >> minlog) + 2
            var h = HufC()
            var have_new = h.build(cnt, 11)
            var new_cost = (h.stream_bytes(cnt) + 1 + (h.last + 1) // 2) if have_new else (1 << 30)  # header bound
            var hs = 0
            var htmp = List[UInt8](length=300, fill=0)
            if have_new:
                hs = h.header(htmp.unsafe_ptr())
                new_cost = hs + h.stream_bytes(cnt)
            var rep_cost = (self.phuf.stream_bytes(cnt)) if (self.phuf_ok and self.phuf.can_code(cnt)) else (1 << 30)
            if have_new or rep_cost < (1 << 30):
                var use_rep = rep_cost <= new_cost
                var best = rep_cost if use_rep else new_cost
                if best + 8 <= n - gain:
                    var four = n >= 256
                    var lh = 3 + (1 if n >= 1024 else 0) + (1 if n >= 16384 else 0)
                    var body = dst.unsafe_offset(lh)
                    var bs = 0
                    if not use_rep:
                        unsafe_memcpy(dest=body, src=htmp.unsafe_ptr().unsafe_mut_cast[False](), count=hs)
                        bs = hs
                    var cs: Int
                    if use_rep:
                        cs = _enc_lits(self.phuf, src, n, four, body.unsafe_offset(bs))
                    else:
                        cs = _enc_lits(h, src, n, four, body.unsafe_offset(bs))
                    if cs > 0:
                        var total = bs + cs
                        if total < n - gain and total < (1 << 18):
                            var ty = 3 if use_rep else 2
                            if lh == 3:
                                var v = ty | ((1 if four else 0) << 2) | (n << 4) | (total << 14)
                                dst[unsafe_offset=0] = UInt8(v & 255)
                                dst[unsafe_offset=1] = UInt8((v >> 8) & 255)
                                dst[unsafe_offset=2] = UInt8((v >> 16) & 255)
                            elif lh == 4:
                                var v = ty | (2 << 2) | (n << 4) | (total << 18)
                                for k in range(4):
                                    dst[unsafe_offset=k] = UInt8((v >> (8 * k)) & 255)
                            else:
                                var v = ty | (3 << 2) | (n << 4) | (total << 22)
                                for k in range(4):
                                    dst[unsafe_offset=k] = UInt8((v >> (8 * k)) & 255)
                                dst[unsafe_offset=4] = UInt8(total >> 10)
                            if not use_rep:
                                self.pend_huf = h^
                                commit_huf = True
                            return lh + total
        return self._lit_small(dst, 0, n, 0)

    def _lit_small(mut self, dst: MutPointer[UInt8, _], ty: Int, n: Int, byte: Int) -> Int:
        """Raw (ty 0) or RLE (ty 1) literals."""
        var lh = 1 + (1 if n > 31 else 0) + (1 if n > 4095 else 0)
        if lh == 1:
            dst[unsafe_offset=0] = UInt8(ty | (n << 3))
        elif lh == 2:
            var v = ty | (1 << 2) | (n << 4)
            dst[unsafe_offset=0] = UInt8(v & 255)
            dst[unsafe_offset=1] = UInt8((v >> 8) & 255)
        else:
            var v = ty | (3 << 2) | (n << 4)
            dst[unsafe_offset=0] = UInt8(v & 255)
            dst[unsafe_offset=1] = UInt8((v >> 8) & 255)
            dst[unsafe_offset=2] = UInt8((v >> 16) & 255)
        if ty == 0:
            unsafe_memcpy(dest=dst.unsafe_offset(lh), src=self.lits.unsafe_ptr().unsafe_mut_cast[False](), count=n)
            return lh + n
        dst[unsafe_offset=lh] = UInt8(byte)
        return lh + 1

    # ---- sequences section ------------------------------------------------------------------------

    def _choose(
        self, kind: Int, cnt: List[Int], nsym: Int, nseq: Int, max_log: Int, allowed: Bool, mut hdr: List[UInt8], mut hlen: Int, mut tab: FseC
    ) -> Int:
        """ZSTD_selectEncodingType: 0 predefined, 1 RLE, 2 new table (in tab, header in hdr), 3 repeat."""
        var top = 0
        for s in range(nsym):
            top = max(top, cnt[s])
        if top == nseq:
            return 0 if (allowed and nseq <= 2) else 1
        var basic = Float64(1e30)
        if allowed:
            basic = self.dfse[kind].cost(cnt, nsym)
        var rep = Float64(1e30)
        if self.pfse_ok[kind]:
            rep = self.pfse[kind].cost(cnt, nsym)
        var comp = Float64(1e30)
        var log = optimal_log(max_log, nseq, nsym - 1)
        var norm = List[Int](length=nsym, fill=0)
        if normalize(cnt, nseq, nsym, log, nseq >= 2048, norm):
            tab.build(norm, nsym, log)
            hlen = write_ncount(hdr.unsafe_ptr(), norm, nsym, log)
            comp = tab.cost(cnt, nsym) + Float64(hlen * 8)
        if basic <= rep and basic <= comp:
            return 0
        if rep <= comp:
            return 3
        return 2

    def sequences(mut self, dst: MutPointer[UInt8, _]) -> Int:
        """The sequences section for the stored sequences; returns its size. The tables it used wait in pend_*
        until commit() says the block was kept."""
        var n = self.nseq
        var op: Int
        if n < 128:
            dst[unsafe_offset=0] = UInt8(n)
            op = 1
        elif n < 0x7F00:
            dst[unsafe_offset=0] = UInt8((n >> 8) + 128)
            dst[unsafe_offset=1] = UInt8(n & 255)
            op = 2
        else:
            dst[unsafe_offset=0] = 255
            dst[unsafe_offset=1] = UInt8((n - 0x7F00) & 255)
            dst[unsafe_offset=2] = UInt8((n - 0x7F00) >> 8)
            op = 3
        if n == 0:
            return op
        var llc = List[Int](length=n, fill=0)
        var ofc = List[Int](length=n, fill=0)
        var mlc = List[Int](length=n, fill=0)
        var cnts = [List[Int](length=36, fill=0), List[Int](length=32, fill=0), List[Int](length=53, fill=0)]
        for i in range(n):
            llc[i] = self.ll_code(Int(self.sll[i]))
            ofc[i] = hb(Int(self.sof[i]))
            mlc[i] = self.ml_code(Int(self.sml[i]))
            cnts[0][llc[i]] += 1
            cnts[1][ofc[i]] += 1
            cnts[2][mlc[i]] += 1
        var modes_at = op
        op += 1
        var modes = 0
        var tabs = [FseC(), FseC(), FseC()]
        var kinds = [0, 0, 0]
        var hdr = List[UInt8](length=300, fill=0)
        for kind in range(3):
            var nsym = 36 if kind == 0 else (32 if kind == 1 else 53)
            var allowed = True
            if kind == 1:
                for s in range(29, 32):
                    if cnts[1][s] > 0:
                        allowed = False
            var hlen = 0
            var cand = FseC()
            var mode = self._choose(kind, cnts[kind], nsym, n, 8 if kind == 1 else 9, allowed, hdr, hlen, cand)
            if mode == 0 and not allowed:  # no predefined table covers these offset codes: build one
                var log = optimal_log(8, n, nsym - 1)
                var norm = List[Int](length=nsym, fill=0)
                if not normalize(cnts[kind], n, nsym, log, n >= 2048, norm):
                    mode = 1
                else:
                    cand.build(norm, nsym, log)
                    hlen = write_ncount(hdr.unsafe_ptr(), norm, nsym, log)
                    mode = 2
            kinds[kind] = mode
            if mode == 1:
                for s in range(nsym):
                    if cnts[kind][s] == n:
                        dst[unsafe_offset=op] = UInt8(s)
                op += 1
                self.pend_ok[kind] = False
            elif mode == 2:
                unsafe_memcpy(dest=dst.unsafe_offset(op), src=hdr.unsafe_ptr().unsafe_mut_cast[False](), count=hlen)
                op += hlen
                tabs[kind] = cand.copy()
                self.pend_fse[kind] = cand.copy()
                self.pend_ok[kind] = True
            elif mode == 3:
                tabs[kind] = self.pfse[kind].copy()
                self.pend_fse[kind] = self.pfse[kind].copy()
                self.pend_ok[kind] = True
            else:
                tabs[kind] = self.dfse[kind].copy()
                self.pend_ok[kind] = False
            modes |= kinds[kind] << (6 - 2 * kind)
        dst[unsafe_offset=modes_at] = UInt8(modes)
        # bitstream: the sequences backwards, the three states initialised from the last one
        var b = BitC(dst.unsafe_offset(op))
        var sl = 0
        var so = 0
        var sm = 0
        var last = n - 1
        if kinds[2] != 1:
            sm = tabs[2].init_state(mlc[last])
        if kinds[1] != 1:
            so = tabs[1].init_state(ofc[last])
        if kinds[0] != 1:
            sl = tabs[0].init_state(llc[last])
        comptime if MUTANT == 2:
            so = so ^ 1
        b.add(Int(self.sll[last]), self.llbits(llc[last]))
        b.add(Int(self.sml[last]), self.mlbits(mlc[last]))
        b.add(Int(self.sof[last]), ofc[last])
        b.flush()
        for i in range(n - 2, -1, -1):
            if kinds[1] != 1:
                tabs[1].put(b, so, ofc[i])
            if kinds[2] != 1:
                tabs[2].put(b, sm, mlc[i])
            if kinds[0] != 1:
                tabs[0].put(b, sl, llc[i])
            b.flush()
            b.add(Int(self.sll[i]), self.llbits(llc[i]))
            b.add(Int(self.sml[i]), self.mlbits(mlc[i]))
            b.flush()
            b.add(Int(self.sof[i]), ofc[i])
            b.flush()
        if kinds[2] != 1:
            b.add(sm, tabs[2].log)
            b.flush()
        if kinds[1] != 1:
            b.add(so, tabs[1].log)
            b.flush()
        if kinds[0] != 1:
            b.add(sl, tabs[0].log)
            b.flush()
        return op + b.close()

    def llbits(self, code: Int) -> Int:
        return Int(self.llb[code])

    def mlbits(self, code: Int) -> Int:
        return Int(self.mlb[code])

    # ---- block ----------------------------------------------------------------------------------

    def commit(mut self, huf_new: Bool, seqs: Bool):
        """The block just built was kept: its Huffman table and FSE tables become the ones to repeat."""
        if huf_new:
            swap(self.phuf, self.pend_huf)
            self.phuf_ok = True
        if seqs:
            for k in range(3):
                if self.pend_ok[k]:
                    self.pfse[k] = self.pend_fse[k].copy()
                self.pfse_ok[k] = self.pend_ok[k]

    def block(
        mut self, src: ImmPointer[UInt8, _], n: Int, dst: MutPointer[UInt8, _], last: Bool, r0: Int, r1: Int, r2: Int
    ) -> Int:
        """Writes the block holding src[0:n] (parsed into the store) with its 3-byte header at dst; returns the
        size. dst needs n + n / 8 + 1024 bytes. r0..r2 are the repeat offsets from before the block."""
        var lastbit = 1 if last else 0
        var body = dst.unsafe_offset(3)
        var csize = 0
        var ok = False
        var hnew = False
        if n > 0:
            var gain = (n >> ((self.strat - 1) if self.strat >= 8 else 6)) + 2
            var ls = self.literals(body, hnew)
            var bits = 0
            for i in range(self.nseq):
                bits += self.llbits(self.ll_code(Int(self.sll[i]))) + self.mlbits(self.ml_code(Int(self.sml[i]))) + hb(Int(self.sof[i])) + 26
            if ls + 4 + bits // 8 + 8 < n + n // 8 + 1000 - 3:
                var ss = self.sequences(body.unsafe_offset(ls))
                csize = ls + ss
                ok = csize < n - gain
        var same = n > 1
        if same and (not ok or (csize < 25 and not self.first)):
            for i in range(1, n):
                if src[unsafe_offset=i] != src[unsafe_offset=0]:
                    same = False
                    break
        else:
            same = False
        # a tiny compressed block of one repeated byte is better as an RLE block, except the first of a frame
        if ok and not (same and csize < 25 and not self.first):
            self.commit(hnew, self.nseq > 0)
            self.first = False
            var h = lastbit | (2 << 1) | (csize << 3)
            dst[unsafe_offset=0] = UInt8(h & 255)
            dst[unsafe_offset=1] = UInt8((h >> 8) & 255)
            dst[unsafe_offset=2] = UInt8((h >> 16) & 255)
            return 3 + csize
        self.first = False
        self.r0 = r0
        self.r1 = r1
        self.r2 = r2
        if same:
            var h = lastbit | (1 << 1) | (n << 3)
            dst[unsafe_offset=0] = UInt8(h & 255)
            dst[unsafe_offset=1] = UInt8((h >> 8) & 255)
            dst[unsafe_offset=2] = UInt8((h >> 16) & 255)
            dst[unsafe_offset=3] = src[unsafe_offset=0]
            return 4
        var h = lastbit | (n << 3)
        dst[unsafe_offset=0] = UInt8(h & 255)
        dst[unsafe_offset=1] = UInt8((h >> 8) & 255)
        dst[unsafe_offset=2] = UInt8((h >> 16) & 255)
        unsafe_memcpy(dest=dst.unsafe_offset(3), src=src, count=n)
        return 3 + n
