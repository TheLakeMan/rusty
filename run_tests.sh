#!/usr/bin/env bash
# run_tests.sh — compare Rusty output against SimpleLisp golden outputs
# Usage: ./run_tests.sh

set -e
RUSTY="./target/release/rusty"
PASS=0
FAIL=0

run_test() {
    local file="$1"
    local expected="$2"
    local label="$3"

    actual=$("$RUSTY" "$file" 2>&1)
    if [ "$actual" = "$(cat "$expected")" ]; then
        echo "✅  $label"
        PASS=$((PASS+1))
    else
        echo "❌  $label"
        echo "    --- expected ---"
        cat "$expected" | sed 's/^/    /'
        echo "    --- got ---"
        echo "$actual" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    fi
}

echo "Building..."
cargo build --release 2>&1 | grep -E "^error|Finished"
echo

# Test drivers + golden expected outputs live under tests/. Libraries they load
# by name — std.lisp, swarm.lisp, kg.lisp, symreg.lisp, ... — stay at the repo
# root (load is CWD-relative and this script runs from root; std/pkg are also
# embedded via include_str! and ship in the crate). So a driver's file path is
# tests/… but a library run directly as a golden (swarm.lisp) keeps its root path.
run_test "tests/tests.lisp"        "tests/expected_tests.txt"  "tests.lisp"
run_test "tests/new-features.lisp" "tests/expected_new.txt"    "new-features.lisp"
run_test "tests/hello.lisp"        "tests/expected_hello.txt"  "hello.lisp"
run_test "swarm.lisp"              "tests/expected_swarm.txt"  "swarm.lisp (multi-agent synthesis)"
run_test "tests/symreg-test.lisp"  "tests/expected_symreg.txt" "symreg-test.lisp (equation discovery)"
run_test "tests/synth-test.lisp"   "tests/expected_synth.txt"  "synth-test.lisp (sketch synthesis)"
run_test "tests/prover-test.lisp"  "tests/expected_prover.txt" "prover-test.lisp (proof assistant)"
run_test "tests/robot-test.lisp"   "tests/expected_robot.txt"  "robot-test.lisp (safe control)"
run_test "tests/fsm-test.lisp"     "tests/expected_fsm.txt"    "fsm-test.lisp (verified state machines)"
run_test "tests/pkg-test.lisp"     "tests/expected_pkg.txt"    "pkg-test.lisp (package manager)"
run_test "tests/testkit-test.lisp" "tests/expected_testkit.txt" "testkit-test.lisp (testing framework)"
run_test "tests/evolve-test.lisp"  "tests/expected_evolve.txt"  "evolve-test.lisp (self-optimization with receipts)"
run_test "tests/supervisor-test.lisp" "tests/expected_supervisor.txt" "supervisor-test.lisp (certifiable supervision)"
run_test "tests/kg-test.lisp"      "tests/expected_kg.txt"     "kg-test.lisp (knowledge graph)"
run_test "tests/discover-test.lisp" "tests/expected_discover.txt" "discover-test.lisp (command registry)"
run_test "tests/commands-test.lisp" "tests/expected_commands.txt" "commands-test.lisp (command smoke)"
# the sentinel proves env-scrubbing: the parent has it, the isolated child must not
PROC_SANDBOX_SENTINEL=leaked run_test "tests/proc-test.lisp" "tests/expected_proc.txt" "proc-test.lisp (multi-process seam)"
run_test "tests/pcheck-test.lisp"  "tests/expected_pcheck.txt" "pcheck-test.lisp (parallel check-exhaustive)"

# rusty-lsp speaks framed JSON-RPC on stdio — a scripted session instead of a golden diff
if python3 tests/lsp-test.py > /dev/null 2>&1; then
    echo "✅  lsp-test.py (language server)"
    PASS=$((PASS+1))
else
    echo "❌  lsp-test.py (language server)"
    FAIL=$((FAIL+1))
fi

# ── Coverage ratchet ────────────────────────────────────────────────────────
COVFILE="$(mktemp)"
export RUSTY_COVERAGE_FILE="$COVFILE"
for f in tests/tests.lisp tests/new-features.lisp tests/hello.lisp swarm.lisp \
         tests/symreg-test.lisp tests/synth-test.lisp tests/prover-test.lisp \
         tests/robot-test.lisp tests/pkg-test.lisp tests/testkit-test.lisp \
         tests/kg-test.lisp tests/discover-test.lisp tests/commands-test.lisp \
         tests/proc-test.lisp tests/pcheck-test.lisp tests/evolve-test.lisp \
         tests/supervisor-test.lisp; do
    RUSTY_COVERAGE=1 "$RUSTY" "$f" >/dev/null 2>&1
done
# check runs WITHOUT RUSTY_COVERAGE so it doesn't record itself
run_test "tests/coverage-check.lisp" "tests/expected_coverage.txt" "coverage-check.lisp (ratchet)"
unset RUSTY_COVERAGE_FILE
rm -f "$COVFILE"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo "🎉 ALL PASSED" || exit 1
