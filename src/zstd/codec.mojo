"""zstd frames for Mojo. Decoding is pure Mojo; encoding still goes through libzstd until the native encoder lands."""
from std.ffi import OwnedDLHandle, external_call
from std.memory import unsafe_memcpy, unsafe_memmove
from zstd.compress import compress_all
from zstd.decode import Zdec

comptime _LIB = "libzstd.so.1"


def _chk(z: OwnedDLHandle, rc: Int) raises -> Int:
    if z.call["ZSTD_isError", UInt32](rc) != 0:
        var p = z.call["ZSTD_getErrorName", Pointer[UInt8, ImmutAnyOrigin]](rc)
        raise Error("zstd: ", String(unsafe_from_utf8=Span(unsafe_ptr=p, length=external_call["strlen", Int](p))))
    return rc


def _ints(a: Int, b: Int, c: Int) -> List[Int]:
    return [a, b, c]


def _cctx(z: OwnedDLHandle, level: Int) raises -> Int:
    """A compression context at `level` that writes a content checksum into every frame."""
    var c = z.call["ZSTD_createCCtx", Int]()
    if c == 0:
        raise Error("zstd: out of memory")
    try:
        _ = _chk(z, z.call["ZSTD_CCtx_setParameter", Int](c, Int32(100), Int32(level)))
        _ = _chk(z, z.call["ZSTD_CCtx_setParameter", Int](c, Int32(201), Int32(1)))
    except e:
        _ = z.call["ZSTD_freeCCtx", Int](c)
        raise e^
    return c


def compress(data: Span[UInt8, _], level: Int = 3) raises -> List[UInt8]:
    """One frame, with content size and checksum. Levels -131072..22 (clamped)."""
    return compress_all(data, level)


struct ZstdReader(Movable):
    """Decompresses a .zst file (or, via `data=`, a buffer) through a fixed 256 KiB input buffer:
    memory is the zstd window, whatever the file size. Frames are read back to back."""

    var d: Zdec
    var f: FileHandle
    var inb: List[UInt8]
    var ip: Int
    var ie: Int
    var data: ImmPointer[UInt8, ImmUntrackedOrigin]  # memory mode: the whole input
    var dn: Int
    var mem: Bool
    var eof: Bool

    def __init__(out self, path: String) raises:
        self.d = Zdec(True)
        self.f = FileHandle()
        self.inb = List[UInt8](length=1 << 18, fill=0)
        self.ip = 0
        self.ie = 0
        self.data = self.inb.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[ImmUntrackedOrigin]()
        self.dn = 0
        self.mem = False
        self.eof = False
        try:
            self.f = open(path, "r")
        except:
            raise Error("zstd: cannot open ", path)

    def __init__(out self, *, data: Span[UInt8, _]) raises:
        self.d = Zdec(True)
        self.f = FileHandle()
        self.inb = List[UInt8]()
        self.ip = 0
        self.ie = 0
        self.data = data.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[ImmUntrackedOrigin]()
        self.dn = len(data)
        self.mem = True
        self.eof = False

    def _more(mut self) raises -> Bool:
        """Decode more; False at the end of the input."""
        var before = self.d.op
        if self.mem:
            var c = self.d.parse(self.data.unsafe_offset(self.ip), self.dn - self.ip)
            self.ip += c
            if c > 0 or self.d.op != before:
                return True
            if self.ip < self.dn or not self.d.idle():
                raise Error("zstd: truncated input")
            return False
        var c = self.d.parse(self.inb.unsafe_ptr().unsafe_mut_cast[False]().unsafe_offset(self.ip), self.ie - self.ip)
        self.ip += c
        if c > 0 or self.d.op != before:
            return True
        if self.d.rd < self.d.op:
            return True
        if self.eof:
            if self.ip < self.ie or not self.d.idle():
                raise Error("zstd: truncated input")
            return False
        if self.ip > 0:
            unsafe_memmove(dest=self.inb.unsafe_ptr(), src=self.inb.unsafe_ptr().unsafe_offset(self.ip).unsafe_origin_cast[MutUntrackedOrigin](), count=self.ie - self.ip)
            self.ie -= self.ip
            self.ip = 0
        var k: Int
        try:
            k = self.f.read(Span(self.inb)[self.ie :])
        except:
            raise Error("zstd: read error")
        if k == 0:
            self.eof = True
        self.ie += k
        return True

    def read(mut self, buf: Span[mut=True, UInt8, _]) raises -> Int:
        """Fills buf from the start; returns the bytes written, 0 at the end. Raises on corrupt
        or truncated data."""
        var n = 0
        while n < len(buf):
            if self.d.rd < self.d.op:
                var k = min(len(buf) - n, self.d.op - self.d.rd)
                unsafe_memcpy(dest=buf.unsafe_ptr().unsafe_offset(n), src=self.d.out.unsafe_ptr().unsafe_offset(self.d.rd).unsafe_origin_cast[MutUntrackedOrigin](), count=k)
                self.d.rd += k
                n += k
            elif not self._more():
                break
        return n


def decompress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Every frame of data, concatenated. Raises on corrupt, truncated or trailing non-zstd data."""
    var d = Zdec(False)
    var p = data.unsafe_ptr().unsafe_mut_cast[False]()
    var ip = 0
    while True:
        var c = d.parse(p.unsafe_offset(ip), len(data) - ip)
        ip += c
        if c == 0:
            break
    if ip < len(data) or not d.idle():
        raise Error("zstd: truncated input")
    d.out.resize(unsafe_uninit_length=d.op)
    var res = List[UInt8]()
    swap(res, d.out)
    return res^


struct ZstdWriter(Movable):
    """Compresses into a .zst file through a fixed 128 KiB output buffer. close() writes the
    frame end and reports I/O errors; dropping the writer without close() leaves a cut-off file."""

    var z: OwnedDLHandle
    var c: Int  # ZSTD_CCtx*
    var f: Int  # FILE*
    var buf: List[UInt8]

    def __init__(out self, path: String, level: Int = 3) raises:
        self.z = OwnedDLHandle(_LIB)
        self.c = 0
        self.buf = List[UInt8](length=1 << 17, fill=0)
        var p = path.copy()
        var m = String("wb")
        self.f = external_call["fopen", Int](p.as_c_string_span().ptr(), m.as_c_string_span().ptr())
        if self.f == 0:
            raise Error("zstd: cannot open ", path)
        self.c = _cctx(self.z, level)

    def write(mut self, data: Span[UInt8, _]) raises:
        self._run(Int(data.unsafe_ptr()), len(data), 0)

    def close(mut self) raises:
        if self.f == 0:
            return
        self._run(0, 0, 2)
        if external_call["fclose", Int32](self.f) != 0:
            self.f = 0
            raise Error("zstd: close failed")
        self.f = 0

    def _run(mut self, src: Int, n: Int, op: Int32) raises:
        var i = _ints(src, n, 0)
        var o = _ints(Int(self.buf.unsafe_ptr()), len(self.buf), 0)
        while True:
            o[2] = 0
            var rc = _chk(self.z, self.z.call["ZSTD_compressStream2", Int](self.c, o.unsafe_ptr(), i.unsafe_ptr(), op))
            if external_call["fwrite", Int](self.buf.unsafe_ptr(), 1, o[2], self.f) != o[2]:
                raise Error("zstd: write error")
            if (rc == 0) if op == 2 else (i[2] == i[1]):
                break

    def __deinit__(deinit self):
        _ = self.z.call["ZSTD_freeCCtx", Int](self.c)
        if self.f != 0:
            _ = external_call["fclose", Int32](self.f)
