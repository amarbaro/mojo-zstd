"""zstd frames for Mojo through the system libzstd.so.1, loaded at run time (no linker flag)."""
from std.ffi import OwnedDLHandle, external_call

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
    """One frame, with content size and checksum. Levels -131072..22 (clamped by libzstd)."""
    var z = OwnedDLHandle(_LIB)
    var c = _cctx(z, level)
    var out = List[UInt8](unsafe_uninit_length=z.call["ZSTD_compressBound", Int](len(data)))
    var rc = z.call["ZSTD_compress2", Int](c, out.unsafe_ptr(), len(out), data.unsafe_ptr(), len(data))
    _ = z.call["ZSTD_freeCCtx", Int](c)
    out.resize(unsafe_uninit_length=_chk(z, rc))
    return out^


struct ZstdReader(Movable):
    """Decompresses a .zst file (or, via `data=`, a buffer) through a fixed 128 KiB input buffer:
    memory is the zstd window, whatever the file size. Frames are read back to back."""

    var z: OwnedDLHandle
    var d: Int  # ZSTD_DCtx*
    var f: Int  # FILE*, 0 when reading from memory
    var inb: List[Int]  # ZSTD_inBuffer {src, size, pos}
    var buf: List[UInt8]
    var rc: Int  # last ZSTD_decompressStream hint; nonzero = inside a frame

    def __init__(out self, path: String) raises:
        self.z = OwnedDLHandle(_LIB)
        self.d = self.z.call["ZSTD_createDCtx", Int]()
        self.buf = List[UInt8](length=1 << 17, fill=0)
        self.inb = _ints(Int(self.buf.unsafe_ptr()), 0, 0)
        self.rc = 1
        var p = path.copy()
        var m = String("rb")
        self.f = external_call["fopen", Int](p.as_c_string_span().ptr(), m.as_c_string_span().ptr())
        if self.f == 0 or self.d == 0:
            raise Error("zstd: cannot open ", path)

    def __init__(out self, *, data: Span[UInt8, _]) raises:
        self.z = OwnedDLHandle(_LIB)
        self.d = self.z.call["ZSTD_createDCtx", Int]()
        self.buf = List[UInt8]()
        self.inb = _ints(Int(data.unsafe_ptr()), len(data), 0)
        self.rc = 1
        self.f = 0
        if self.d == 0:
            raise Error("zstd: out of memory")

    def read(mut self, buf: Span[mut=True, UInt8, _]) raises -> Int:
        """Fills buf from the start; returns the bytes written, 0 at the end. Raises on corrupt
        or truncated data."""
        var o = _ints(Int(buf.unsafe_ptr()), len(buf), 0)
        while o[2] < o[1]:
            if self.f != 0 and self.inb[2] == self.inb[1]:
                self.inb[1] = external_call["fread", Int](self.buf.unsafe_ptr(), 1, len(self.buf), self.f)
                self.inb[2] = 0
                if self.inb[1] < len(self.buf) and external_call["ferror", Int32](self.f) != 0:
                    raise Error("zstd: read error")
            var before = self.inb[2] + o[2]
            var rc = _chk(self.z, self.z.call["ZSTD_decompressStream", Int](self.d, o.unsafe_ptr(), self.inb.unsafe_ptr()))
            if self.inb[2] + o[2] == before:  # no progress: input is used up
                if self.rc != 0:
                    raise Error("zstd: truncated input")
                break
            self.rc = rc
        return o[2]

    def __deinit__(deinit self):
        _ = self.z.call["ZSTD_freeDCtx", Int](self.d)
        if self.f != 0:
            _ = external_call["fclose", Int32](self.f)


def decompress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Every frame of data, concatenated. Raises on corrupt, truncated or trailing non-zstd data."""
    var r = ZstdReader(data=data)
    var n = r.z.call["ZSTD_getFrameContentSize", UInt64](data.unsafe_ptr(), len(data))
    var out = List[UInt8](unsafe_uninit_length=Int(n) + 1 if n < (1 << 30) else 4 * len(data) + 4096)
    var done = 0
    while True:
        done += r.read(Span(out)[done:])
        if done < len(out):
            break
        out.resize(unsafe_uninit_length=2 * len(out))
    out.resize(unsafe_uninit_length=done)
    return out^


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
