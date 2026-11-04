# Performance

Source: `scripts/bench.sh`, 32 MiB seeded text (`.work/corpus.txt`), 3 runs, level 3 / lz4 default.
Run it: `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 scripts/bench.sh`.

| | Mojo (ms) | Python oracle (ms) |
|---|---|---|
| zstd compress | 61, 63, 179 (outlier) | 61, 62, 66 |
| zstd decompress | 36, 34, 59 | 42, 41, 38 |
| lz4 compress | 36, 37, 44 | 44, 44, 44 |
| lz4 decompress | 29, 31, 35 | 40, 44, 42 |
| sizes | zstd 4372426 B, lz4 8819229 B | identical |
| peak RSS | 113 MB | 123 MB |

Both call the same C libraries; expect parity. Streaming: 128 MiB written and read back, peak RSS 13.7 MB (1 MiB: 13.7 MB).

`src/` is 230 lines: `wc -l src/*/*.mojo`.
