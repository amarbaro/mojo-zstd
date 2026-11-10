# Performance

Source: `scripts/bench.sh`, 32 MiB seeded text (`.work/corpus.txt`), 3 runs, level 3 / lz4 default, plus levels 1, 9, 19 on
the first 4 MiB once. Run it: `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 scripts/bench.sh`.
**The box was busy: load average 12.4 to 13.3 on 16 cores during the run below** (other agents' jobs), so read ratios,
not milliseconds. A quiet box (load 4) gave zstd compress 73 to 80 ms and decompress 43 ms for the Mojo side.

| | zstd c (ms) | zstd d (ms) | lz4 c (ms) | lz4 d (ms) | peak RSS |
|---|---|---|---|---|---|
| **native Mojo** (this version), 3 runs | 84, 86, 95 | 48, 73, 51 | 28, 37, 31 | 27, 41, 29 | 123 MB |
| Python oracle (libzstd 1.5.7, liblz4 1.9.4), same runs | 60, 87, 56 | 37, 50, 35 | 40, 46, 38 | 35, 38, 34 | 124 MB |
| *baseline: v0.1.1, Mojo calling the system libraries* | 61, 63, 179 (outlier) | 36, 34, 59 | 36, 37, 44 | 29, 31, 35 | 113 MB |

Sizes: zstd level 3 4410985 B against libzstd's 4372426 B (+0.9%), lz4 8819229 B, identical to python-lz4's.
The native lz4 is as fast as or faster than liblz4 here; the zstd encoder is 1.3 to 1.5x libzstd's time at level 3, the
decoder 1.2 to 1.4x.

| 4 MiB prefix | native c / d (ms) | native size | Python c / d (ms) | libzstd size |
|---|---|---|---|---|
| level 1 | 9 / 3 | 583253 | 8 / 4 | 583277 |
| level 9 | 49 / 3 | 455442 | 41 / 2 | 456977 |
| level 19 | 2750 / 3 | 312880 | 1328 / 1 | 313057 |

Higher levels cost about 2x libzstd's time (optimal parser, binary tree). Streaming: 128 MiB written and read back through
`ZstdWriter` / `ZstdReader` peaks at 14.2 MB, 1 MiB at 13.5 MB.

## Size against libzstd, every level

2 MiB of the seeded text, `zstd.compress(data, level)` against Python `zstandard` at the same level (both decode to the
source under Python). The gate holds every row of its fixtures to 5% (+16 B for tiny inputs); this table is the large-input
view. Worst gap over all 24 levels per input: text +0.9% (level 4), 870 KB of C sources +1.3% (level 3), 940 KB shared object
+0.8% (level 17), 2.5 MB binary slice +1.9% (level 13). Byte identity with libzstd is not a goal.

| level | native (B) | libzstd (B) | gap |
|---|---|---|---|
| -5 | 285333 | 291633 | -2.2% |
| -1 | 283216 | 286624 | -1.2% |
| 1 | 278650 | 278497 | +0.1% |
| 2 | 282944 | 282553 | +0.1% |
| 3 | 275369 | 272826 | +0.9% |
| 4 | 275365 | 272818 | +0.9% |
| 5 | 234639 | 234554 | +0.0% |
| 6 | 231906 | 231379 | +0.2% |
| 7 | 221214 | 221999 | -0.4% |
| 8 | 218180 | 218870 | -0.3% |
| 9 | 217940 | 218878 | -0.4% |
| 10 | 209379 | 209757 | -0.2% |
| 11 | 201979 | 202296 | -0.2% |
| 12 | 201979 | 202296 | -0.2% |
| 13 | 183390 | 194036 | -5.5% |
| 14 | 170019 | 180827 | -6.0% |
| 15 | 169991 | 173879 | -2.2% |
| 16 | 170186 | 170241 | -0.0% |
| 17 | 164658 | 164655 | +0.0% |
| 18 | 164134 | 164027 | +0.1% |
| 19 | 153161 | 153180 | -0.0% |
| 20 | 153161 | 153180 | -0.0% |
| 21 | 153161 | 153180 | -0.0% |
| 22 | 153161 | 153180 | -0.0% |

`src/` is 4025 lines: `wc -l src/*/*.mojo` (was 230 with the bindings).
