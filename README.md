# mojo-zstd

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-zstd/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-zstd/actions/workflows/ci.yml) [![latest release](https://img.shields.io/github/v/release/amarbaro/mojo-zstd)](https://github.com/amarbaro/mojo-zstd/releases/latest) [![license](https://img.shields.io/github/license/amarbaro/mojo-zstd)](https://github.com/amarbaro/mojo-zstd/blob/main/LICENSE) [![checks](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/amarbaro/mojo-zstd/badges/checks.json)](https://github.com/amarbaro/mojo-zstd/actions/workflows/ci.yml)
<!-- /badges -->

<!-- install -->
Install: `pixi add mojo-zstd` once published. For now: `git clone https://github.com/amarbaro/mojo-zstd`, then `mojo run -I mojo-zstd/src app.mojo`.

```mojo
from std.os import remove
import lz4
import zstd


def main() raises:
    var text = ("the quick brown fox jumps over the lazy dog. " * 2000).as_bytes()
    var z = zstd.compress(text, 3)
    var l = lz4.compress(text)
    print("zstd", len(text), "->", len(z), "| lz4", len(text), "->", len(l))
    if zstd.decompress(z) != List(text) or lz4.decompress(l) != List(text):
        raise Error("round trip differs")
    var w = zstd.ZstdWriter("quickstart.zst")  # streaming, fixed memory
    w.write(text)
    w.close()
    var r = zstd.ZstdReader("quickstart.zst")
    var buf = List[UInt8](length=1 << 16, fill=0)
    var total = 0
    while True:
        var n = r.read(buf)
        if n == 0:
            break
        total += n
    print("streamed back", total, "bytes")
    remove("quickstart.zst")
```
<!-- /install -->

Read and write zstd and lz4 frames from Mojo. It calls the system `libzstd.so.1` and
`liblz4.so.1`, loaded at run time, so `mojo run` and `mojo build` need no linker flag.
230 lines in `src/`. Every result is checked against Python `zstandard` and `lz4` on 24075 jobs,
including bit-flipped, truncated and trailing-garbage input.

This is `examples/quickstart.mojo`; `scripts/check.sh` runs it.

Requires Mojo 1.2 on Linux, `libzstd.so.1` and `liblz4.so.1` (present on desktop and server
distros; no `-dev` package).

## What you get

- `zstd.compress(data, level=3)`, `zstd.decompress(data)`: one frame out (content size and checksum), every frame in.
- `zstd.ZstdWriter(path, level)` and `zstd.ZstdReader(path)` / `ZstdReader(data=span)`: streaming through a 128 KiB buffer.
- `lz4.compress(data)`, `lz4.decompress(data)`: lz4 frame format.
- Corrupt, truncated or trailing input raises `zstd: ...` / `lz4: ...`; it never crashes.

API: [docs/api.md](docs/api.md). Design: [docs/design.md](docs/design.md). Numbers: [docs/perf.md](docs/perf.md).

## Performance

32 MiB text, `scripts/bench.sh`, 3 runs: zstd level 3 compress 61 to 63 ms (Python 61 to 66),
decompress 34 to 36 ms (Python 38 to 42); lz4 compress 36 to 44 ms (Python 44), decompress
29 to 35 ms (Python 40 to 44). One mojo zstd run read 179 ms compress, a noisy outlier. Same
libraries underneath, so the claim is parity, not a faster codec. Peak RSS 113 MB against 123 MB.
Streaming 128 MiB through `ZstdWriter` and `ZstdReader` peaks at 13.7 MB, the same as 1 MiB.

## Checks

| Script | What |
|---|---|
| `scripts/check.sh` | 24075 verdict lines identical to `tools/oracle.py` (10851 corrupt inputs rejected by both), 13224 outputs byte-identical, 3 planted bugs rejected, streaming RSS, API errors, example |
| `scripts/bench.sh` | the speed numbers above, 3 runs each, peak RSS |
| `scripts/ci.sh` | install and gate, same on GitHub and a local VM |

## License

Apache-2.0.
