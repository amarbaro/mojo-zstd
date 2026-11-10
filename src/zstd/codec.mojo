"""zstd frames for Mojo, in pure Mojo: no C library, no foreign calls."""
from std.memory import unsafe_memcpy, unsafe_memmove
from zstd.compress import Zenc, compress_all
from zstd.decode import Zdec

comptime _LIB = "libzstd.so.1"


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
    """Compresses into a .zst file through a window buffer and a 128 KiB output buffer: memory is the zstd
    window, whatever the amount written. close() writes the frame end and reports I/O errors; dropping the
    writer without close() leaves a cut-off file."""

    var z: Zenc
    var f: FileHandle
    var live: Bool

    def __init__(out self, path: String, level: Int = 3) raises:
        self.z = Zenc(level)
        self.f = FileHandle()
        self.live = False
        try:
            self.f = open(path, "w")
        except:
            raise Error("zstd: cannot open ", path)
        self.live = True

    def write(mut self, data: Span[UInt8, _]) raises:
        self.z.write(data, self.f)

    def close(mut self) raises:
        if not self.live:
            return
        self.live = False
        self.z.finish(self.f)
        try:
            self.f.close()
        except:
            raise Error("zstd: close failed")
