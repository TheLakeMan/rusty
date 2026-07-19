#!/usr/bin/env bash
# Copyright (c) 2026 Nicholas Vermeulen
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# stress_crash_probe.sh — the native-stack cliffs found in the 2026-07-18
# crash-hunt.  On an UNGUARDED build each of these makes the binary ABORT with a
# "has overflowed its stack / fatal runtime error: stack overflow" core dump;
# four native recursion sites had no guard — the evaluator (non-tail positions),
# the recursive-descent parser, Value display, and Drop of a deeply *nested*
# list chain — and Rust aborts on stack overflow (it cannot be caught with
# catch_unwind).
#
# This is the dishonest-failure gap the "refuse cleanly" thesis rejects: a
# corrupt/deeply-nested .lisp file should be refused like a truncated one, not
# core-dump the process.  Fixed in 0.61.0 (eval guard is stack-adaptive, sized
# to `ulimit -s`; parser/display fixed caps; Drop is iterative) — every row
# below should now read a clean error or a bounded OK, never ABORT.  NOT a
# golden (a regression aborts by design); run by hand to confirm the fix holds
# and to re-measure thresholds.  Deterministic guard coverage lives in the
# golden suite (the rb-* rows in new-features.lisp).
#
# Usage:  ./benchmarks/stress_crash_probe.sh   (from the repo root)

set -u
BIN="${RUSTY_BIN:-./target/release/rusty}"
[ -x "$BIN" ] || { echo "build first: cargo build --release"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

probe() { # name  lisp-file  timeout_s
  local name="$1" f="$2" t="${3:-20}"
  timeout -s KILL "$t" "$BIN" "$f" >"$TMP/o" 2>"$TMP/e"; local code=$?
  local sig
  case $code in
    0)        sig="OK (clean)";;
    124|137)  sig="HANG@${t}s";;
    134|139)  sig="ABORT/SEGV (stack overflow)";;
    101)      sig="rust-panic";;
    *)        sig="clean-error(exit=$code)";;
  esac
  printf '%-28s %-30s | %s%s\n' "$name" "$sig" \
    "$(head -c 90 "$TMP/o" | tr '\n' ' ')" "$(head -c 90 "$TMP/e" | tr '\n' ' ')"
}

echo "== stress_crash_probe (expected: ABORT until a depth guard lands) =="

# 1. Evaluator, non-tail recursion — the MOST reachable cliff (~2k-5k depth).
printf '(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1))))) (print (sum 100000))\n' > "$TMP/a1"
probe "eval-nontail-rec-100k" "$TMP/a1" 15

# 2. Evaluator, deeply nested call expression (~2k-5k depth).
python3 -c "print('(car '*10000 + \"'(1)\" + ')'*10000)" > "$TMP/a2"
probe "eval-nested-car-10k" "$TMP/a2" 15

# 3. Non-tail stdlib fn (take) — same evaluator stack, hit by ordinary code.
printf '(print (length (take 50000 (range 0 100000))))\n' > "$TMP/a3"
probe "stdlib-take-50k" "$TMP/a3" 15

# 4. Recursive-descent parser (~20k-50k nesting depth).
python3 -c "print('(define d (quote ' + '('*80000 + ')'*80000 + ')) (print 1)')" > "$TMP/a4"
probe "parser-nest-80k" "$TMP/a4" 20

# 5. Value display / printer (~100k nesting depth).
printf '(define (nest n x) (if (= n 0) x (nest (- n 1) (list x)))) (print (nest 150000 1))\n' > "$TMP/a5"
probe "display-deepnest-150k" "$TMP/a5" 20

# 6. Drop of a deeply *nested* list dropped mid-program (unbound expr result).
#    Built by a tail-recursive loop (fine), the recursive Drop overflowed.
printf '(define (nest n x) (if (= n 0) x (nest (- n 1) (list x)))) (nest 500000 1) (print (quote ok))\n' > "$TMP/a6"
probe "drop-nested-500k" "$TMP/a6" 20

echo "== done =="
