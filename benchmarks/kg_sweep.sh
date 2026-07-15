#!/usr/bin/env bash
# Copyright (c) 2026 Nicholas Vermeulen
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# kg_sweep.sh — bound the kg-vs-rdflib claim across SCALES, not at one point.
#
# The README/card quote load 10x, grandparent 22x, type+age 27x. Those were
# measured only at ~60k triples. A ratio at one size says nothing about any
# other size: it can shrink, hold, or invert. This sweeps several scales and
# prints the ratios so the claim can be stated with a range instead of a point.
#
# Both sides load the IDENTICAL generated file. rdflib is a yardstick, never a
# dependency. Timings, not golden output — NOT part of run_tests.sh.
#
# Usage: benchmarks/kg_sweep.sh [N ...]      (N = people, ~3 triples each)
set -uo pipefail
cd "$(dirname "$0")/.."

PY=${PY:-python3}
RUSTY=${RUSTY:-./target/release/rusty}
SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(200 2000 20000 100000)

command -v "$PY" >/dev/null || { echo "no $PY"; exit 1; }
[ -x "$RUSTY" ] || { echo "build first: cargo build --release"; exit 1; }

printf '%10s %10s | %9s %9s %6s | %9s %9s %6s | %9s %9s %6s\n' \
  people triples rdflib-ld rusty-ld "x" rdflib-gp rusty-gp "x" rdflib-ta rusty-ta "x"

num() { grep -oE '[0-9]+\.?[0-9]*' <<<"$1" | tail -1; }

for n in "${SIZES[@]}"; do
  # python generates the file AND times rdflib on it
  out=$("$PY" benchmarks/kg_rdflib_bench.py "$n" 2>/dev/null) || { echo "rdflib failed at $n"; continue; }
  triples=$(sed -n "s/.*'generated', \([0-9]*\).*/\1/p" <<<"$out")
  r_ld=$(num "$(grep "'loaded'" <<<"$out")")
  r_gp=$(num "$(grep 'grandparent-solutions' <<<"$out")")
  r_ta=$(num "$(grep 'type-age-join' <<<"$out")")

  # rusty loads the identical file
  rout=$("$RUSTY" benchmarks/kg_bench.lisp 2>/dev/null) || { echo "rusty failed at $n"; continue; }
  k_ld=$(num "$(grep 'loaded' <<<"$rout")")
  k_gp=$(num "$(grep 'grandparent-solutions' <<<"$rout")")
  k_ta=$(num "$(grep 'type-age-join' <<<"$rout")")

  # solution counts must match, or the two sides aren't running the same query
  rs=$(sed -n "s/.*'grandparent-solutions', \([0-9]*\).*/\1/p" <<<"$out")
  ks=$(sed -n 's/.*grandparent-solutions \([0-9]*\).*/\1/p' <<<"$rout")
  [ "$rs" = "$ks" ] || echo "  !! solution mismatch at $n: rdflib $rs vs rusty $ks"

  ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print "-"; else printf "%.1f", a/b }'; }
  printf '%10s %10s | %9s %9s %5sx | %9s %9s %5sx | %9s %9s %5sx\n' \
    "$n" "$triples" "$r_ld" "$k_ld" "$(ratio "$r_ld" "$k_ld")" \
    "$r_gp" "$k_gp" "$(ratio "$r_gp" "$k_gp")" \
    "$r_ta" "$k_ta" "$(ratio "$r_ta" "$k_ta")"
done
