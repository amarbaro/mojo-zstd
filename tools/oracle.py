"""Oracle for the gate, Python zstandard + lz4 (dev group). Run as `.venv/bin/python -I tools/oracle.py`.
  gen DIR N SEED  fixtures + N seeded random cases + corrupted variants; writes jobs.txt, want.txt, ref/
  verify DIR      cases.mojo's out/ and our/ files against ref/ and the sources
  corpus FILE MB  seeded word-salad text, the bench input
  bench FILE      the work of tests/bench.mojo, in Python"""
import ctypes, os, random, resource, sys, time
import lz4.frame as L
import zstandard as Z

resource.setrlimit(resource.RLIMIT_AS, (3 << 30, 3 << 30))  # memory rule: a runaway oracle dies with MemoryError, not the host
MAX_FRAMES, MAX_OUT = 64, 1 << 28  # bounds for dec(): frames per input, decoded bytes


class _Buf(ctypes.Structure):
    _fields_ = [("p", ctypes.c_void_p), ("size", ctypes.c_size_t), ("pos", ctypes.c_size_t)]


def sysdec(b):
    """Every frame of b through the system libzstd.so.1, the library src/zstd loads; None when it calls b bad.
    A corrupted frame's verdict depends on the libzstd version (1.5.5 accepts frames 1.5.7 rejects), so
    corrupted variants are judged by the library the wrapper runs on; valid frames keep zstandard."""
    z = ctypes.CDLL("libzstd.so.1")
    z.ZSTD_createDStream.restype = ctypes.c_void_p
    z.ZSTD_decompressStream.restype = ctypes.c_size_t
    z.ZSTD_decompressStream.argtypes = [ctypes.c_void_p, ctypes.POINTER(_Buf), ctypes.POINTER(_Buf)]
    z.ZSTD_isError.argtypes = [ctypes.c_size_t]
    z.ZSTD_freeDStream.argtypes = [ctypes.c_void_p]
    ds, src, out, rc = z.ZSTD_createDStream(), ctypes.create_string_buffer(b, len(b)), [], 1
    dst = ctypes.create_string_buffer(1 << 16)
    i = _Buf(ctypes.cast(src, ctypes.c_void_p), len(b), 0)
    try:
        while i.pos < len(b) or rc != 0:
            o = _Buf(ctypes.cast(dst, ctypes.c_void_p), len(dst), 0)
            before = i.pos
            rc = z.ZSTD_decompressStream(ds, ctypes.byref(o), ctypes.byref(i))
            if z.ZSTD_isError(rc):
                return None
            out.append(dst.raw[:o.pos])
            if sum(map(len, out)) > MAX_OUT or (o.pos == 0 and i.pos == before):
                return None  # over the bound, or no progress: input ended inside a frame
    finally:
        z.ZSTD_freeDStream(ds)
    return b"".join(out)


def dec(b, kind):
    """Every frame of b, concatenated; None when Python calls the input bad."""
    out, first = [], True
    try:
        while first or b:
            if len(out) > MAX_FRAMES or sum(map(len, out)) > MAX_OUT:
                return None
            first = False
            d = Z.ZstdDecompressor().decompressobj() if kind == "zst" else L.LZ4FrameDecompressor()
            out.append(d.decompress(b))
            if not d.eof:
                return None
            b = d.unused_data
    except Exception:
        return None
    return b"".join(out)


def zenc(r, rng):
    c = Z.ZstdCompressor(level=rng.choice([-5, 1, 3, 3, 9, 19, 22]), write_checksum=rng.random() < .5,
                         write_content_size=rng.random() < .5)
    if rng.random() < .3:  # streaming encoder: no content size in the header
        o = c.compressobj()
        return o.compress(r) + o.flush()
    return c.compress(r)


def lenc(r, rng):
    return L.compress(r, compression_level=rng.choice([0, 0, 3, 9, 12]), block_size=rng.choice([0, 4, 5, 6, 7]),
                      content_checksum=rng.random() < .5, block_linked=rng.random() < .5, store_size=rng.random() < .5)


def body(rng, n):
    k = rng.randrange(5)
    if k == 0: return rng.randbytes(n)
    if k == 1: return bytes(n)
    if k == 2: return bytes(rng.choice(b"ab ") for _ in range(n))
    w = [rng.randbytes(rng.randrange(2, 9)) for _ in range(40)]
    s = bytearray()
    while len(s) < n:
        s += rng.choice(w) if k == 3 or rng.random() < .8 else rng.randbytes(3)
    return bytes(s[:n])


def bad(c, rng):
    k = rng.randrange(3)
    if k == 0 and c:
        i = rng.randrange(len(c)); return c[:i] + bytes([c[i] ^ (1 << rng.randrange(8))]) + c[i + 1:]
    if k == 1: return c[:rng.randrange(len(c) + 1)]
    return c + rng.randbytes(rng.randrange(1, 9))


def gen(d, n, seed):
    rng = random.Random(seed)
    for s in ("", "ref", "our", "out"):
        os.makedirs(f"{d}/{s}", exist_ok=True)
    raws = {"empty": b"", "one": b"x", "text": body(rng, 300000), "zeros": bytes(5 << 20), "noise": rng.randbytes(1 << 20),
            "mixed": b"".join(body(rng, 40000) for _ in range(50))}
    for i in range(n):
        raws[f"c{i:04d}"] = body(rng, int(2 ** rng.uniform(0, 17)) if i % 25 else 0)
    files = {}
    for name, r in raws.items():
        files[name + ".zst"], files[name + ".lz4"] = zenc(r, rng), lenc(r, rng)
        for k in range(2):
            files[f"{name}.bad{k}.zst"], files[f"{name}.bad{k}.lz4"] = bad(files[name + ".zst"], rng), bad(files[name + ".lz4"], rng)
    files["multi.zst"] = zenc(raws["text"], rng) + zenc(b"", rng) + zenc(raws["one"], rng)
    files["multi.lz4"] = lenc(raws["text"], rng) + lenc(raws["one"], rng)
    jobs, want = [], []
    for name, r in raws.items():
        open(f"{d}/{name}.raw", "wb").write(r)
        for k in ("zst", "lz4"):
            jobs.append(f"rt {name} {k}"); want.append(f"rt {name} {k} ok {len(r)}")
        jobs.append(f"stream {name}"); want.append(f"stream {name} ok {len(r)}")
    for f, c in files.items():
        open(f"{d}/{f}", "wb").write(c)
        o = sysdec(c) if ".bad" in f and f.endswith(".zst") else dec(c, f[-3:])
        r = "error" if o is None else f"ok {len(o)}"
        jobs.append(f"dec {f}"); want.append(f"dec {f} {r}")
        if f.endswith(".zst"):
            jobs.append(f"sdec {f}"); want.append(f"sdec {f} {r}")
        if o is not None:
            open(f"{d}/ref/{f}", "wb").write(o)
    open(f"{d}/jobs.txt", "w").write("\n".join(jobs) + "\n")
    open(f"{d}/want.txt", "w").write("\n".join(want) + "\n")
    print(f"gen: {len(raws)} sources, {len(files)} oracle files, {len(jobs)} jobs")


def verify(d):
    n = 0
    for line in open(f"{d}/want.txt").read().split("\n")[:-1]:
        op, name, *rest = line.split()
        if rest[0] == "error":
            continue
        if op == "dec":
            want, got = open(f"{d}/ref/{name}", "rb").read(), open(f"{d}/out/{name}", "rb").read()
        elif op == "sdec":
            want, got = open(f"{d}/ref/{name}", "rb").read(), open(f"{d}/out/{name}.s", "rb").read()
        else:  # rt / stream: what we wrote must decode under Python to the source
            kind = rest[0] if op == "rt" else "zst"
            f = f"{d}/our/{name}.{kind}" if op == "rt" else f"{d}/our/{name}.stream.zst"
            want, got = open(f"{d}/{name}.raw", "rb").read(), dec(open(f, "rb").read(), kind)
        if want != got:
            print(f"FAIL verify: {line}: bytes differ"); sys.exit(1)
        n += 1
    print(f"verify: {n} outputs byte-identical to the oracle's")


def corpus(p, mb):
    rng = random.Random(7)
    v = [bytes(rng.choice(b"abcdefghijklmnopqrstuvwxyz") for _ in range(rng.randrange(2, 10))) for _ in range(8000)]
    w = [v[min(int(rng.paretovariate(1.0)) - 1, 7999)] for _ in range(mb << 17)]
    open(p, "wb").write(b" ".join(w)[: mb << 20])


def bench(p):
    raw = open(p, "rb").read()
    t = time.perf_counter(); c = Z.ZstdCompressor(level=3, write_checksum=True).compress(raw)
    t1 = time.perf_counter(); Z.ZstdDecompressor().decompress(c)
    t2 = time.perf_counter(); lc = L.compress(raw, content_checksum=True, block_size=7)
    t3 = time.perf_counter(); L.decompress(lc)
    t4 = time.perf_counter()
    print("zstd c %d ms d %d ms (%d B); lz4 c %d ms d %d ms (%d B)" % ((t1 - t) * 1e3, (t2 - t1) * 1e3, len(c), (t3 - t2) * 1e3, (t4 - t3) * 1e3, len(lc)))


{"gen": lambda: gen(sys.argv[2], int(sys.argv[3]), int(sys.argv[4])), "verify": lambda: verify(sys.argv[2]), "corpus": lambda: corpus(sys.argv[2], int(sys.argv[3])), "bench": lambda: bench(sys.argv[2])}[sys.argv[1]]()
