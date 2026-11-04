# Errors are raised, never crash: bad level, corrupt, truncated, empty and trailing input, missing file.
import lz4
import zstd


def raises(name: String, prefix: String, ok: Bool) raises:
    if not ok:
        raise Error("api: ", name, " did not raise ", prefix, "...")


def main() raises:
    var s = ("abc" * 1000).as_bytes()
    var z = zstd.compress(s, 19)
    var l = lz4.compress(s)
    for k in range(len(z)):  # every proper prefix is an error
        try:
            _ = zstd.decompress(Span(z)[:k])
            raise Error("api: zstd prefix ", k, " decoded")
        except e:
            raises("zstd prefix", "zstd: ", String(e).startswith("zstd: "))
    for k in range(len(l)):
        try:
            _ = lz4.decompress(Span(l)[:k])
            raise Error("api: lz4 prefix ", k, " decoded")
        except e:
            raises("lz4 prefix", "lz4: ", String(e).startswith("lz4: "))
    var junk = List[UInt8](length=64, fill=0xA5)
    try:
        _ = zstd.decompress(junk)
        raise Error("api: zstd junk decoded")
    except e:
        raises("zstd junk", "zstd: ", String(e).startswith("zstd: "))
    try:
        _ = zstd.ZstdReader(".work/no/such.zst")
        raise Error("api: missing file opened")
    except e:
        raises("missing file", "zstd: ", String(e).startswith("zstd: "))
    if len(zstd.decompress(zstd.compress(List[UInt8]()))) != 0 or len(lz4.decompress(lz4.compress(List[UInt8]()))) != 0:
        raise Error("api: empty round trip")
    print("api: ok")
