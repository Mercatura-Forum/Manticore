#!/usr/bin/env bash
# Runs every test/*.test.mo twice: compiled to WASI and executed under wasmtime
# (Region memory available), and, for tests that need no Region, in the moc
# interpreter. A test passes when it exits 0; every test prints the number of
# records it examined, and a test that prints no count is a failure.
set -u
cd "$(dirname "$0")/.."
MOC="${MOC:-$HOME/.cache/mops/moc/1.4.1/moc}"
SOURCES="$(mops sources)"
OUT="${TEST_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
fail=0
total=0
for t in test/*.test.mo; do
  name="$(basename "$t" .test.mo)"
  total=$((total+1))
  echo "=== $name (wasi)"
  if ! "$MOC" -wasi-system-api $SOURCES -o "$OUT/$name.wasm" "$t" 2> "$OUT/$name.compile.log"; then
    echo "COMPILE FAILED: $name"; sed -n '1,20p' "$OUT/$name.compile.log"; fail=$((fail+1)); continue
  fi
  if ! wasmtime "$OUT/$name.wasm" > "$OUT/$name.wasi.log" 2>&1; then
    echo "FAILED (wasi): $name"; tail -20 "$OUT/$name.wasi.log"; fail=$((fail+1)); continue
  fi
  cat "$OUT/$name.wasi.log"
  # Coverage gate: every test must print at least one line of the exact form
  # "count: <what was examined> = <n>", and no such line may report zero.
  if ! grep -Eq '^count: [^=]+ = [1-9][0-9]*$' "$OUT/$name.wasi.log"; then echo "FAILED: $name printed no 'count: ... = <n>' line"; fail=$((fail+1)); continue; fi
  if grep -Eq '^count: [^=]+ = 0$' "$OUT/$name.wasi.log"; then echo "FAILED: $name examined zero records on a count line"; fail=$((fail+1)); continue; fi
  # Region-free tests also run in the interpreter, unless marked "engine: wasi-only"
  # (the core battery fingerprints the whole state on every rejection, which is
  # quadratic and takes over ten minutes in the interpreter).
  if ! grep -q "Region" "$t" && ! grep -q "JournalLog" "$t" && ! grep -q "engine: wasi-only" "$t"; then
    echo "=== $name (interpreter)"
    if ! "$MOC" -r $SOURCES "$t" > "$OUT/$name.interp.log" 2> "$OUT/$name.interp.err"; then
      cat "$OUT/$name.interp.err" >> "$OUT/$name.interp.log"
      echo "FAILED (interpreter): $name"; tail -20 "$OUT/$name.interp.log"; fail=$((fail+1)); continue
    fi
    # both engines must print identical output
    if ! diff -q "$OUT/$name.wasi.log" "$OUT/$name.interp.log" > /dev/null; then
      echo "FAILED: $name output differs between wasi and interpreter"; diff "$OUT/$name.wasi.log" "$OUT/$name.interp.log" | head; fail=$((fail+1)); continue
    fi
    echo "(interpreter output identical to wasi)"
  fi
done
echo "=================================================="
echo "test files: $total, failed: $fail, logs: $OUT"
[ "$fail" -eq 0 ]
