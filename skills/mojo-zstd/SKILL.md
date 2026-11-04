---
name: mojo-zstd
description: "zstd and lz4 frame compression for Mojo through the system libzstd/liblz4: .zst and .lz4 files, in-memory buffers, bounded-memory streaming. Use when Mojo code must read or write zstd or lz4 data."
metadata:
  short-description: "zstd and lz4 frames for Mojo via system libzstd/liblz4; files, buffers, streaming"
---

# mojo-zstd

zstd and lz4 frames for Mojo 1.2 on Linux. Needs `libzstd.so.1` and `liblz4.so.1` on the host,
loaded at run time: no linker flag.

## When to use

Read or write `.zst` / `.lz4` data, in memory or streamed in bounded memory.
Not for dictionaries, threads, the lz4 block format or other OSes.

## Install

`mojo run -I src app.mojo` from a clone, or copy `src/zstd/` and `src/lz4/`.

## The calls

```mojo
import lz4
import zstd

def main() raises:
    var data = List[UInt8](length=100000, fill=65)
    var z = zstd.compress(data, 3)            # one frame, level 3
    var d = zstd.decompress(z)                # every frame, concatenated
    var l = lz4.decompress(lz4.compress(d))   # lz4 frame
    print(len(z), len(d), len(l))

    var w = zstd.ZstdWriter("a.zst", 3)       # streaming, fixed buffer
    w.write(data)
    w.close()
    var r = zstd.ZstdReader("a.zst")
    var buf = List[UInt8](length=1 << 16, fill=0)
    var n = r.read(buf)                       # 0 at end of stream
    print(n)
```

## Gotchas

- Call `w.close()`: dropping a `ZstdWriter` leaves a cut-off file.
- `ZstdReader(data=span)` reads from memory and keeps a raw pointer: keep the owner alive past the last `read`.
- `decompress` raises `zstd: ...` / `lz4: ...` on corrupt, truncated or trailing input. Catch it for untrusted data.
- Parameters are `Span[UInt8, _]`: pass a `List[UInt8]` or `s.as_bytes()` directly.
- `decompress` holds the whole result in memory: stream big files with `ZstdReader`.

## Gate

`scripts/check.sh` from the repo must end with `PASS all` (oracle comparison against Python's zstd and
lz4 bindings, mutants, a bounded-memory stream, the README example). `scripts/bench.sh` for speed.
