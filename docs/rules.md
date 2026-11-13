# Rules

What broke, and the rule that stops it. Newest first.

- A stream's table indices passed 2^31 and the encoder crashed at level 18 and up: `rebase()` shifted two tables and forgot the third (hash3). -> Every table that holds indices is listed in `rebase()`; `tests/rebase.mojo` starts indices below 2^31 and runs levels 1, 3, 12, 19 in the gate.
- An RLE block with a regenerated size above the block limit wrote past the output buffer (found by bit-flip fuzzing, not by the 2000-case run). -> Every size read from a header is checked against the buffer before the first write. Fuzz decoders with every single-bit flip of small frames (`tools/oracle.py vec`), not only random corruption.
- `import zstd` picked up a stale `zstd.mojoc` that an earlier `mojo precompile` left in the working directory, and a fix looked like it did nothing. -> Precompile to `.work/`, never next to the scripts, and delete any `*.mojoc` before judging a build.
- A module named `match.mojo` does not parse (`match` is a keyword). -> Module names avoid Mojo keywords.
- decodecorpus was built inside another project's source tree and left object files there. -> Copy sources into `.work/` before building a C tool.
- A decoder's verdicts on corrupt input only matched libzstd after reading its source (one-pass path for small known-size frames, empty last block, fast Huffman loop): -> match a reference decoder on corrupt input by reading its source and fuzzing every bit, never by guessing from the spec.
- The stream gate allowed +1 MB RSS growth while its own comment measured runner noise up to 1.3 MB; the nightly matrix failed at +1072 KB (mojo-libs #4) -> a threshold sits above the measured noise with margin and below the defect size it guards (here ~128 MB).
- The oracle judges corrupted frames with the system libzstd: 1.5.5 on the Ubuntu 24.04 matrix runner accepts frames 1.5.7 rejects (mojo-libs #5). Swapping in zstandard's bundled 1.5.7 was wrong too: same version, different verdict on dc-z000003.f56 -> the oracle asserts the system libzstd is 1.5.7 and fails by name otherwise; CI runs on an image that ships it (ubuntu-26.04); an equivalence check covers every corpus the gate uses (gen and vec), not one.
