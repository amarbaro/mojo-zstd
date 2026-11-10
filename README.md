# mojo-zstd

<!-- badges -->
[![ci](https://github.com/amarbaro/mojo-zstd/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarbaro/mojo-zstd/actions/workflows/ci.yml) [![latest release](https://img.shields.io/github/v/release/amarbaro/mojo-zstd)](https://github.com/amarbaro/mojo-zstd/releases/latest) [![license](https://img.shields.io/github/license/amarbaro/mojo-zstd)](https://github.com/amarbaro/mojo-zstd/blob/main/LICENSE) [![checks](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/amarbaro/mojo-zstd/badges/checks.json)](https://github.com/amarbaro/mojo-zstd/actions/workflows/ci.yml)
<!-- /badges -->

<!-- install -->
Install: `pixi workspace channel add https://conda.modular.com/max https://prefix.dev/amarbaro/amarbaro`, then `pixi add mojo-zstd` (import `lz4` and `zstd`). From source: `git clone https://github.com/amarbaro/mojo-zstd`, then `mojo run -I mojo-zstd/src app.mojo`.
Toolchains: Mojo 1.2 stable, and the nightly 1.3.0.dev2026110805 in the weekly [mojo-libs](https://github.com/amarbaro/mojo-libs) matrix (36 libraries on stable, 35 on nightly).

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

Read and write zstd and lz4 frames from Mojo, in pure Mojo: no C library, no foreign calls, no linker
flag. Both codecs are ports of the reference algorithms (4.0k lines in `src/`). Every result is
checked against Python `zstandard` and `lz4`, including bit-flipped, truncated and trailing-garbage
input: decoding agrees with libzstd and liblz4 on what is valid and on what is not, lz4 encoding is
byte for byte python-lz4's, zstd encoding decodes under Python and stays within 5% of libzstd's size
at every level.

This is `examples/quickstart.mojo`; `scripts/check.sh` runs it.

Requires Mojo 1.2. Nothing else: no system library, no `-dev` package.

## What you get

- `zstd.compress(data, level=3)`, `zstd.decompress(data)`: one frame out (content size and checksum), every frame in.
- `zstd.ZstdWriter(path, level)` and `zstd.ZstdReader(path)` / `ZstdReader(data=span)`: streaming through a 128 KiB buffer.
- `lz4.compress(data)`, `lz4.decompress(data)`: lz4 frame format.
- Corrupt, truncated or trailing input raises `zstd: ...` / `lz4: ...`; it never crashes.

API: [docs/api.md](docs/api.md). Design: [docs/design.md](docs/design.md). Numbers: [docs/perf.md](docs/perf.md).

## Performance

32 MiB text, `scripts/bench.sh`, level 3, on a busy box (load 12 to 13 on 16 cores): zstd compress 84 to 95 ms
(libzstd via Python 56 to 87), decompress 48 to 73 ms (35 to 50); lz4 compress 28 to 37 ms (38 to 46),
decompress 27 to 41 ms (34 to 38). Output size is within 5% of libzstd's at every level (worst 1.9% on four
test inputs); lz4 output is byte for byte python-lz4's. Peak RSS 123 MB against 124 MB. Streaming 128 MiB
through `ZstdWriter` and `ZstdReader` peaks at 14.2 MB, against 13.5 MB for 1 MiB. Details and the per-level
table: [docs/perf.md](docs/perf.md).

**Limits:** inputs under 2 GiB for `compress`. Not covered: dictionaries, multithreading, long-distance matching, the lz4 block format, lz4 levels.

## Checks

| Script | What |
|---|---|
| `scripts/check.sh` | 32136 verdict lines identical to `tools/oracle.py` (10851 corrupt inputs rejected by both), 21285 outputs byte-identical, zstd at 25 levels within 5% of libzstd, lz4 byte for byte, 12679 bit-flipped reference frames, 5 planted bugs rejected, indices past 2^31, streaming RSS, API errors, example |
| `scripts/bench.sh` | the speed numbers above, 3 runs each, peak RSS |
| `scripts/ci.sh` | install and gate, same on GitHub and a local VM |

## License

Apache-2.0.
