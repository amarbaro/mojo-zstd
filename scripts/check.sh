#!/usr/bin/env bash
# The gate. tools/oracle.py (Python zstandard + lz4) writes fixtures, 2000 seeded random cases and
# corrupted variants of each, with the oracle's verdict per job. tests/cases.mojo must print the same
# verdict line for every job (dec, sdec, rt, stream) and its output bytes must equal the oracle's;
# what it compresses must decode under Python to the source. Negative control: three planted bugs
# (CASES_MUTANT) must each fail the same comparison. Then bounded streaming memory, API, example.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
M=${MOJO:-.venv/bin/mojo}; PY=".venv/bin/python -I"
build() { $M build -I src "tests/$1.mojo" -o ".work/$1" 2>.work/build.err || { echo "FAIL build: tests/$1.mojo"; cat .work/build.err; exit 1; }; }
for t in cases api stream; do build $t; done
compare() {  # compare DIR: run tests/cases on DIR, diff its verdicts and bytes against the oracle's
  local d=$1
  rm -rf "$d/out" "$d/our"; mkdir "$d/out" "$d/our"
  ${CASES_BIN:-.work/cases} "$d" > "$d/got.txt" 2> "$d/got.err" || { echo "FAIL cases: crashed: $(head -c 300 "$d/got.err")"; return 1; }
  cmp -s "$d/got.txt" "$d/want.txt" || { echo "FAIL oracle: $(diff "$d/got.txt" "$d/want.txt" | head -3 | tr '\n' ' ')"; return 1; }
  $PY tools/oracle.py verify "$d"
}
rm -rf .work/fx .work/neg
$PY tools/oracle.py gen .work/fx 2000 1 || { echo "FAIL setup: oracle gen"; exit 1; }
compare .work/fx || exit 1
echo "oracle: $(grep -c '' .work/fx/want.txt) jobs, verdict lines identical ($(grep -c ' error$' .work/fx/want.txt) rejected as corrupt by both)"
rm -rf .work/vec
$PY tools/oracle.py vec .work/vec 200 tests/vectors/*.zst > /dev/null || { echo "FAIL setup: oracle vec"; exit 1; }
compare .work/vec || exit 1
echo "vectors: $(ls tests/vectors | wc -l) reference frames (zstd repo golden files, decodecorpus) and $(( $(grep -c '' .work/vec/want.txt) / 2 )) bit-flipped variants: verdicts and bytes identical"
$PY tools/oracle.py gen .work/neg 60 2 > /dev/null
for m in 1 2 3; do
  if CASES_MUTANT=$m compare .work/neg > .work/neg.out 2>&1; then echo "FAIL negative control: mutant $m passed the gate"; exit 1; fi
  echo "negative control: mutant $m rejected: $(head -c 100 .work/neg.out | head -1)"
done
$M build -D ZSTD_MUTANT=1 -I src tests/cases.mojo -o .work/cases_mut 2>.work/build.err || { echo "FAIL build: mutant decoder"; cat .work/build.err; exit 1; }
if CASES_BIN=.work/cases_mut compare .work/neg > .work/neg.out 2>&1; then echo "FAIL negative control: decoder with one FSE state off passed the gate"; exit 1; fi
echo "negative control: decoder with one FSE state off rejected: $(head -c 100 .work/neg.out | head -1)"
rss() { $PY -c 'import resource, subprocess, sys
o = subprocess.run(sys.argv[1:], capture_output=True, text=True, check=True).stdout.split()
print(o[1] == o[2], resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)' "$@"; }
# peak RSS of one process varies by about +-0.5 MB run to run (runner noise up to 1.3 MB): take the lowest of 3 per size
low() { local best="" ok r; for _ in 1 2 3; do read -r ok r <<< "$(rss .work/stream .work/s.zst "$1")" || return 1
  [[ $ok == True ]] || { echo "False 0"; return 0; }; [[ -z $best || $r -lt $best ]] && best=$r; done; echo "True $best"; }
read -r ok1 r1 <<< "$(low 1)" || { echo "FAIL stream: crashed"; exit 1; }
read -r ok2 r2 <<< "$(low 128)" || { echo "FAIL stream: crashed"; exit 1; }
[[ $ok1 == True && $ok2 == True ]] || { echo "FAIL stream: read-back checksum differs"; exit 1; }
(( r2 < 2 * r1 && r2 - r1 < 1024 )) || { echo "FAIL stream: peak RSS ${r1} KB for 1 MiB, ${r2} KB for 128 MiB; want < 2x and < +1 MB"; exit 1; }
echo "stream: 128 MiB written and read back through 128 KiB buffers, peak RSS ${r2} KB (${r1} KB for 1 MiB)"
.work/api || { echo "FAIL api: tests/api.mojo"; exit 1; }
$M run -I src examples/quickstart.mojo > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
diff <(sed -n '/^```mojo$/,/^```$/p' README.md | sed '1d;$d') examples/quickstart.mojo > /dev/null || { echo "FAIL doc-test: README example differs from examples/quickstart.mojo"; exit 1; }
echo "PASS all"
