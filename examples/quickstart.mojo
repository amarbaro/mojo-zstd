import lz4
import zstd


def main() raises:
    var text = ("the quick brown fox jumps over the lazy dog. " * 2000).as_bytes()
    var z = zstd.compress(text, 3)
    var l = lz4.compress(text)
    print("zstd", len(text), "->", len(z), "| lz4", len(text), "->", len(l))
    if zstd.decompress(z) != List(text) or lz4.decompress(l) != List(text):
        raise Error("round trip differs")
    var w = zstd.ZstdWriter(".work/quickstart.zst")  # streaming, fixed memory
    w.write(text)
    w.close()
    var r = zstd.ZstdReader(".work/quickstart.zst")
    var buf = List[UInt8](length=1 << 16, fill=0)
    var total = 0
    while True:
        var n = r.read(buf)
        if n == 0:
            break
        total += n
    print("streamed back", total, "bytes")
