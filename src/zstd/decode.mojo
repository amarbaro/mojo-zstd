"""zstd frame decoder: a push parser. parse() takes the bytes available and decodes every complete unit
(frame header, block, checksum) in them, so the caller can hand it a file chunk by chunk or a whole buffer."""
from std.memory import unsafe_memcpy, unsafe_memmove, unsafe_memset
from zstd.block import Dctx, decode_block
from zstd.fse import bad
from zstd.xxh64 import Xxh64

comptime _MAX_WINDOW = 1 << 27


@always_inline
def _le(p: ImmPointer[UInt8, _], i: Int, n: Int) -> Int:
    var v = 0
    for k in range(n):
        v |= Int(p[unsafe_offset=i + k]) << (8 * k)
    return v


struct Zdec(Movable):
    var dc: Dctx
    var out: List[UInt8]  # decoded bytes; out[:op] is valid, out[:rd] was handed to the caller
    var op: Int
    var rd: Int
    var lo: Int  # offsets may reach back to out[lo]
    var sliding: Bool  # keep one window of history and reuse the buffer, else keep everything
    var inframe: Bool
    var seen: Bool  # a whole frame or skippable frame was read
    var window: Int
    var bmax: Int  # largest block, from the window
    var omax: Int  # largest block output
    var hist: Int  # history the sliding buffer keeps
    var oneshot: Bool  # libzstd decodes this frame in one pass, with fewer limits
    var csize: Int  # declared content size, -1 if none
    var cksum: Bool
    var made: Int  # bytes decoded in this frame
    var skip: Int  # bytes left of a skippable frame
    var hash: Xxh64

    def __init__(out self, sliding: Bool) raises:
        self.dc = Dctx()
        self.out = List[UInt8](length=0, fill=0)
        self.op = 0
        self.rd = 0
        self.lo = 0
        self.sliding = sliding
        self.inframe = False
        self.seen = False
        self.window = 0
        self.bmax = 0
        self.omax = 0
        self.hist = 0
        self.oneshot = False
        self.csize = -1
        self.cksum = False
        self.made = 0
        self.skip = 0
        self.hash = Xxh64()

    def idle(self) -> Bool:
        """Between frames, not inside one."""
        return not self.inframe and self.skip == 0 and self.seen

    def _room(mut self):
        """Make out[op : op + omax + 32] writable."""
        var need = self.op + self.omax + 32
        if need <= len(self.out):
            return
        if not self.sliding:
            self.out.resize(unsafe_uninit_length=max(need, 2 * len(self.out)))
            return
        var cap = (self.hist if self.csize < 0 else min(self.hist, self.csize)) + self.omax + 32
        if len(self.out) < cap:
            self.out.resize(unsafe_uninit_length=cap)
            if need <= cap:
                return
        var keep = min(self.op, self.hist)
        var shift = self.op - keep
        if shift > 0:
            var o = self.out.unsafe_ptr()
            unsafe_memmove(dest=o, src=o.unsafe_offset(shift).unsafe_origin_cast[MutUntrackedOrigin](), count=keep)
            self.op = keep
            self.rd = max(self.rd - shift, 0)
            self.lo = max(self.lo - shift, 0)

    def parse(mut self, src: ImmPointer[UInt8, _], n: Int) raises -> Int:
        """Decodes what is complete in src[0:n]; returns the bytes consumed. Stops early when the caller must
        take output first (sliding mode)."""
        var ip = 0
        while True:
            if self.skip > 0:
                var k = min(self.skip, n - ip)
                self.skip -= k
                ip += k
                if self.skip > 0:
                    return ip
                self.seen = True
                continue
            if not self.inframe:
                if n - ip < 4:
                    return ip
                var magic = _le(src, ip, 4)
                if magic & 0xFFFFFFF0 == 0x184D2A50:
                    if n - ip < 8:
                        return ip
                    self.skip = _le(src, ip + 4, 4)
                    ip += 8
                    if self.skip == 0:
                        self.seen = True
                    continue
                if magic != 0xFD2FB528:
                    raise bad("unknown frame prefix")
                if n - ip < 6:
                    return ip
                var fd = Int(src[unsafe_offset=ip + 4])
                var single = (fd >> 5) & 1
                var fcs = fd >> 6
                var dsz = 0 if fd & 3 == 0 else (1 if fd & 3 == 1 else (2 if fd & 3 == 2 else 4))
                var csz = single if fcs == 0 else (2 if fcs == 1 else (4 if fcs == 2 else 8))
                var hn = 5 + (1 - single) + dsz + csz
                if n - ip < hn:
                    return ip
                if fd & 8 != 0:
                    raise bad("unsupported frame parameter")
                var q = ip + 5
                var wsz = 0
                if single == 0:
                    var wl = (Int(src[unsafe_offset=q]) >> 3) + 10
                    if wl > 31:
                        raise bad("window too large")
                    wsz = (1 << wl) + ((1 << wl) >> 3) * (Int(src[unsafe_offset=q]) & 7)
                    q += 1
                var dict = _le(src, q, dsz)
                q += dsz
                var fsize = -1
                if csz > 0:
                    fsize = _le(src, q, csz) + (256 if csz == 2 else 0)
                    if fsize < 0:  # 2^63 and up: known, and larger than anything
                        fsize = 1 << 62
                if single == 1:
                    wsz = fsize
                if dict != 0:
                    raise bad("dictionary mismatch")
                # libzstd decodes a frame of known small size in one pass, ahead of its window limit
                if wsz > _MAX_WINDOW and not (0 <= fsize <= 65536):
                    raise bad("frame requires too much memory")
                self.window = wsz
                self.bmax = min(wsz, 1 << 17)
                # libzstd decodes a frame of known small size in one pass: its window limit, the block size
                # limit on raw and RLE blocks and on the output of a block do not apply, the total must match
                self.oneshot = 0 <= fsize <= 65536
                self.omax = max(self.bmax + 32, fsize) if self.oneshot else self.bmax
                self.hist = max(wsz, fsize) if self.oneshot else wsz
                self.csize = fsize
                self.cksum = (fd >> 2) & 1 == 1
                self.made = 0
                self.hash = Xxh64()
                self.dc.new_frame()
                self.inframe = True
                self.lo = self.op
                ip += hn
                continue
            if self.sliding and self.rd < self.op:
                return ip
            if n - ip < 3:
                return ip
            var bh = _le(src, ip, 3)
            var last = bh & 1
            var typ = (bh >> 1) & 3
            var bsz = bh >> 3
            if typ == 3:
                raise bad("corrupt input")
            var take = 1 if typ == 1 else bsz
            if take > (self.bmax if typ == 2 else self.omax):
                raise bad("corrupt input")
            if typ == 2 and take == 0 and 0 <= self.csize <= 65536:
                # libzstd decodes a frame of known small size in one pass, which rejects an empty compressed
                # block (no literals section); its streaming path, taken otherwise, lets it through
                raise bad("corrupt input")
            if n - ip - 3 < take:
                return ip
            var made: Int
            if take == 0:
                made = 0
            else:
                self._room()
                var o = self.out.unsafe_ptr()
                var s = src.unsafe_offset(ip + 3)
                if typ == 0:
                    unsafe_memcpy(dest=o.unsafe_offset(self.op), src=s, count=bsz)
                    made = bsz
                elif typ == 1:
                    if bsz > self.omax:
                        raise bad("corrupt input")
                    unsafe_memset(o.unsafe_offset(self.op), s[unsafe_offset=0], bsz)
                    made = bsz
                else:
                    made = decode_block(self.dc, s, take, o, self.op, self.lo, self.bmax, self.bmax + 32 if self.oneshot else self.bmax, self.omax) - self.op
                if made > self.omax:
                    raise bad("corrupt input")
                if self.cksum:
                    self.hash.update(o.unsafe_offset(self.op), made)
                self.op += made
                self.made += made
            ip += 3 + take
            if last == 1:
                # libzstd's streaming path skips this check when the last block is empty
                if self.csize >= 0 and self.made != self.csize and not (take == 0 and self.csize > 65536):
                    raise bad("corrupt input")
                if self.cksum:
                    if n - ip < 4:
                        raise bad("truncated input")
                    if Int(self.hash.digest() & 0xFFFFFFFF) != _le(src, ip, 4):
                        raise bad("checksum mismatch")
                    ip += 4
                self.inframe = False
                self.seen = True
