# Streams argv[2] MiB of generated data through ZstdWriter into argv[1], then back through
# ZstdReader, one 128 KiB buffer each way. Prints "<mib> <written checksum> <read checksum>":
# memory stays flat whatever the size.
from std.sys import argv
import zstd


def fill(mut buf: List[UInt8], mut s: Int):
    for i in range(len(buf)):  # words from a 64-entry table: compressible, never periodic
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        buf[i] = UInt8(97 + ((s >> 16) & 7) + (i & 56 if (s >> 24) & 1 == 0 else 0))


def main() raises:
    var path = String(argv()[1])
    var n = Int(argv()[2]) * 8
    var buf = List[UInt8](length=1 << 17, fill=0)
    var s = 1
    var wsum = 0
    var w = zstd.ZstdWriter(path, 1)
    for _ in range(n):
        fill(buf, s)
        for i in range(len(buf)):
            wsum = (wsum * 31 + Int(buf[i])) & 0xFFFFFFFF
        w.write(buf)
    w.close()
    var r = zstd.ZstdReader(path)
    var rsum = 0
    while True:
        var k = r.read(buf)
        if k == 0:
            break
        for i in range(k):
            rsum = (rsum * 31 + Int(buf[i])) & 0xFFFFFFFF
    print(n // 8, wsum, rsum)
