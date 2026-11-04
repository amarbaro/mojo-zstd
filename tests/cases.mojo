# Runs a job list (tools/oracle.py gen writes it) and prints one result line per job, the line the
# oracle predicts in want.txt:
#   dec F | sdec F | rt NAME zst|lz4 | stream NAME  ->  "<job> ok <len>" or "<job> error"
# dec/sdec write the decoded bytes to DIR/out, rt/stream write what they compressed to DIR/our.
# CASES_MUTANT=1..3 plants a bug (gate negative control).
from std.sys import argv
from std.os import getenv
import lz4
import zstd


def load(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def save(path: String, data: Span[UInt8, _]) raises:
    with open(path, "w") as f:
        f.write_bytes(data)


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    return a == b


def stream_read(path: String, bs: Int) raises -> List[UInt8]:
    var r = zstd.ZstdReader(path)
    var out = List[UInt8]()
    var buf = List[UInt8](length=bs, fill=0)
    while True:
        var n = r.read(buf)
        if n == 0:
            return out^
        out.extend(Span(buf)[:n])


def run(d: String, job: List[String], mutant: Int, mut seed: Int) raises -> String:
    var op = job[0]
    var name = job[1]
    if op == "dec" or op == "sdec":
        var out: List[UInt8]
        try:
            if op == "sdec":
                out = stream_read(d + "/" + name, 1 + seed % 5000)
            elif name.endswith(".zst"):
                out = zstd.decompress(load(d + "/" + name))
            else:
                out = lz4.decompress(load(d + "/" + name))
        except e:
            return String("ok 0") if mutant == 1 else String("error")
        if mutant == 2 and len(out) > 0:
            out[0] ^= 1
        save(d + "/out/" + name + (".s" if op == "sdec" else ""), out)
        return String("ok ", len(out))
    var raw = load(d + "/" + name + ".raw")
    if op == "rt":
        var c = zstd.compress(raw) if job[2] == "zst" else lz4.compress(raw)
        if mutant == 3 and len(c) > 0:
            c.resize(len(c) - 1, 0)
        save(d + "/our/" + name + "." + job[2], c)
        var back = zstd.decompress(c) if job[2] == "zst" else lz4.decompress(c)
        return String("ok ", len(back)) if same(back, raw) else String("error")
    var w = zstd.ZstdWriter(d + "/our/" + name + ".stream.zst", 1 + seed % 19)
    var i = 0
    while i < len(raw):  # odd chunk sizes
        var n = min(1 + seed % 70000, len(raw) - i)
        w.write(Span(raw)[i : i + n])
        i += n
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    w.close()
    return String("ok ", len(raw)) if same(stream_read(d + "/our/" + name + ".stream.zst", 1 + seed % 90000), raw) else String("error")


def main() raises:
    var d = String(argv()[1])
    var mutant = Int(getenv("CASES_MUTANT", "0"))
    var seed = 12345
    var jobs = String(unsafe_from_utf8=load(d + "/jobs.txt"))
    for line in jobs.split("\n"):
        if line.byte_length() == 0:
            continue
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        var job = [String(p) for p in line.split(" ")]
        try:
            print(line, run(d, job, mutant, seed))
        except e:
            print(line, "error")
