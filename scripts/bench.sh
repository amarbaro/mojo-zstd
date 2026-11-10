#!/usr/bin/env bash
# tests/bench.mojo vs tools/oracle.py bench on the same 32 MiB text corpus, 3 runs each (levels 1, 9, 19 on
# 4 MiB once): each prints its own timed work in ms; peak RSS of the whole process from getrusage; the load
# average at the end says how much to trust the numbers.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
.venv/bin/mojo build -I src tests/bench.mojo -o .work/bench 2>.work/build.err || { echo "FAIL build: tests/bench.mojo"; cat .work/build.err; exit 1; }
IN=.work/corpus.txt
[[ -e $IN ]] || .venv/bin/python -I tools/oracle.py corpus $IN 32 || { echo "FAIL setup: corpus"; exit 1; }
run() {
  .venv/bin/python -I -c 'import resource, subprocess, sys
out = subprocess.run(sys.argv[2:], capture_output=True, text=True, check=True).stdout.strip()
print("%-7s %s, peak RSS %d MB" % (sys.argv[1], out, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024))' "$@" \
    || { echo "FAIL run: $1"; exit 1; }
}
for i in 1 2 3; do run mojo .work/bench "$IN"; run python .venv/bin/python -I tools/oracle.py bench "$IN"; done
run mojo .work/bench "$IN" levels   # levels 1, 9, 19 on the first 4 MiB, once
run python .venv/bin/python -I tools/oracle.py bench "$IN" levels
echo "load average at the end: $(cut -d" " -f1-3 /proc/loadavg)"
