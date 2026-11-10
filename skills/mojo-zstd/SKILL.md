---
name: mojo-zstd
description: "zstd and lz4 frame compression for Mojo, pure Mojo with no C library: .zst and .lz4 files, in-memory buffers, bounded-memory streaming. Use when Mojo code must read or write zstd or lz4 data."
metadata:
  short-description: "zstd and lz4 frames for Mojo, pure Mojo, no C library; files, buffers, streaming"
---

# mojo-zstd

zstd and lz4 frames for Mojo 1.2, written in Mojo: no C library, no foreign calls, no linker flag, any
host Mojo runs on. Decoding matches libzstd and liblz4 on valid and corrupt input; lz4 encoding is byte for
byte python-lz4's; zstd encoding is valid zstd within 5% of libzstd's size at every level (not its bytes).

## When to use

Read or write `.zst` / `.lz4` data, in memory or streamed in bounded memory.
Not for dictionaries, threads, long-distance matching, the lz4 block format, lz4 levels.

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
lz4 bindings and libzstd's golden vectors, mutants, a bounded-memory stream, the README example). `scripts/bench.sh` for speed.
