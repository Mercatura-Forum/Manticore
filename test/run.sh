#!/usr/bin/env bash
# Runs every test/*.test.mo twice: compiled to WASI and executed under wasmtime
# (Region memory available), and, for tests that need no Region, in the moc
# interpreter, requiring byte-identical output from both engines. A test passes
# when it exits 0; every test must print at least one line of the exact form
# "count: <what was examined> = <n>" and no such line may report zero, because a
# tool that examined zero records has failed its coverage requirement.
#
# The same runner shape as the journal's (thebes-ledger-core test/run.sh), so one
# gate governs both repositories.
set -u
cd "$(dirname "$0")/.."
MOC="${MOC:-$HOME/.cache/mops/moc/1.4.1/moc}"
PKGS="$(./tools/packages.sh)"
OUT="${TEST_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
fail=0
total=0
for t in test/*.test.mo; do
  name="$(basename "$t" .test.mo)"
  total=$((total+1))
  echo "=== $name (wasi)"
  if ! "$MOC" -wasi-system-api $PKGS -o "$OUT/$name.wasm" "$t" 2> "$OUT/$name.compile.log"; then
    echo "COMPILE FAILED: $name"; sed -n '1,20p' "$OUT/$name.compile.log"; fail=$((fail+1)); continue
  fi
  if ! wasmtime "$OUT/$name.wasm" > "$OUT/$name.wasi.log" 2>&1; then
    echo "FAILED (wasi): $name"; tail -20 "$OUT/$name.wasi.log"; fail=$((fail+1)); continue
  fi
  cat "$OUT/$name.wasi.log"
  if ! grep -Eq '^count: [^=]+ = [1-9][0-9]*$' "$OUT/$name.wasi.log"; then echo "FAILED: $name printed no 'count: ... = <n>' line"; fail=$((fail+1)); continue; fi
  if grep -Eq '^count: [^=]+ = 0$' "$OUT/$name.wasi.log"; then echo "FAILED: $name examined zero records on a count line"; fail=$((fail+1)); continue; fi
  # Region-free tests also run in the interpreter, unless marked "engine: wasi-only".
  if ! grep -q "Region" "$t" && ! grep -q "engine: wasi-only" "$t"; then
    echo "=== $name (interpreter)"
    if ! "$MOC" -r $PKGS "$t" > "$OUT/$name.interp.log" 2> "$OUT/$name.interp.err"; then
      cat "$OUT/$name.interp.err" >> "$OUT/$name.interp.log"
      echo "FAILED (interpreter): $name"; tail -20 "$OUT/$name.interp.log"; fail=$((fail+1)); continue
    fi
    if ! diff -q "$OUT/$name.wasi.log" "$OUT/$name.interp.log" > /dev/null; then
      echo "FAILED: $name output differs between wasi and interpreter"; diff "$OUT/$name.wasi.log" "$OUT/$name.interp.log" | head; fail=$((fail+1)); continue
    fi
    echo "(interpreter output identical to wasi)"
  fi
done

# The permission catalogue is a build gate, not a test: it is checked against the
# built Candid interface, and its own negative control proves it can fail.
echo "=== permission audit (built Candid interface)"
if ! "$MOC" --legacy-persistence $PKGS --idl -o "$OUT/bank.did" src/bank/Bank.mo 2> "$OUT/bank.idl.log"; then
  echo "FAILED: Bank.mo did not build an interface"; sed -n '1,20p' "$OUT/bank.idl.log"; fail=$((fail+1))
elif ! python3 tools/permission_audit.py "$OUT/bank.did" > "$OUT/permission-audit.log" 2>&1; then
  echo "FAILED: permission audit"; cat "$OUT/permission-audit.log"; fail=$((fail+1))
else
  cat "$OUT/permission-audit.log"
fi

echo "=================================================="
echo "test files: $total, failed: $fail, logs: $OUT"
[ "$fail" -eq 0 ]
