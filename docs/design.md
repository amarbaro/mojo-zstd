# Design

- **System libraries.** `OwnedDLHandle("libzstd.so.1")` and `"liblz4.so.1"` at run time: no linker flag, no vendored C, no `-dev` package. Cost: Linux only, and the library version is the host's.
- **Layout.** `src/zstd/codec.mojo` (162 lines), `src/lz4/codec.mojo` (66 lines). One function per C call site; `_chk` turns `ZSTD_isError` / `LZ4F_isError` into `Error`.
- **No struct mirrors.** C structs (`ZSTD_inBuffer`, `LZ4F_preferences_t`) are `List[Int]` of machine words, so field order is the only contract.
- **Memory.** One-shot calls size the output from the frame header (`ZSTD_getFrameContentSize`, lz4 content size) when it is below 1 GiB, else from 4x the input, and double on demand. Streaming holds a fixed 128 KiB buffer plus the zstd window: 128 MiB streamed peaks at 13.7 MB.
- **Untrusted input.** A header that claims a huge size cannot force an allocation above 1 GiB. Errors raise; the gate feeds 10851 corrupt inputs.
- **Oracle.** `tools/oracle.py` (Python `zstandard`, `lz4`) is a subprocess in the gate, never imported by the library. It is bounded: 3 GiB address space, 64 frames and 256 MiB output per input. All gate commands run under `systemd-run MemoryMax=4G`.
- **Not covered.** Dictionaries, multithreading, lz4 block format, lz4 levels, windows or macOS.
