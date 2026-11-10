# API

Import with `import zstd` and `import lz4`. All errors are `Error` with prefix `zstd: ` or `lz4: `.

## zstd

| Item | Does | Raises |
|---|---|---|
| `compress(data: Span[UInt8, _], level: Int = 3) -> List[UInt8]` | One frame with content size and checksum. Level -131072..22, clamped. | zstd error |
| `decompress(data: Span[UInt8, _]) -> List[UInt8]` | Every frame of `data`, concatenated. | corrupt, truncated or trailing non-zstd data |
| `ZstdReader(path: String)` | Open a `.zst` file for streaming. | cannot open |
| `ZstdReader(*, data: Span[UInt8, _])` | Stream from a buffer you keep alive. | out of memory |
| `ZstdReader.read(mut buf: Span[mut=True, UInt8, _]) -> Int` | Fills `buf` from the start; returns bytes written, 0 at the end. Frames read back to back. | corrupt or truncated data, read error |
| `ZstdWriter(path: String, level: Int = 3)` | Create a `.zst` file; 128 KiB output buffer. | cannot open |
| `ZstdWriter.write(mut self, data: Span[UInt8, _])` | Compress `data` into the file. | zstd error, write error |
| `ZstdWriter.close(mut self)` | Write the frame end, close the file. Without it the file is cut off. | write or close error |

## lz4

| Item | Does | Raises |
|---|---|---|
| `compress(data: Span[UInt8, _]) -> List[UInt8]` | One frame, 4 MiB blocks, content size and checksum. | lz4 error |
| `decompress(data: Span[UInt8, _]) -> List[UInt8]` | Every frame of `data`, concatenated. | corrupt, truncated or trailing non-lz4 data |
