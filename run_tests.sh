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

run_test "tests.lisp"        "expected_tests.txt"  "tests.lisp"
run_test "new-features.lisp" "expected_new.txt"    "new-features.lisp"
run_test "hello.lisp"        "expected_hello.txt"  "hello.lisp"
run_test "swarm.lisp"        "expected_swarm.txt"  "swarm.lisp (multi-agent synthesis)"
run_test "symreg-test.lisp"  "expected_symreg.txt" "symreg-test.lisp (equation discovery)"
run_test "synth-test.lisp"   "expected_synth.txt"  "synth-test.lisp (sketch synthesis)"
run_test "prover-test.lisp"  "expected_prover.txt" "prover-test.lisp (proof assistant)"
run_test "robot-test.lisp"   "expected_robot.txt"  "robot-test.lisp (safe control)"
run_test "pkg-test.lisp"     "expected_pkg.txt"    "pkg-test.lisp (package manager)"
run_test "testkit-test.lisp" "expected_testkit.txt" "testkit-test.lisp (testing framework)"
run_test "evolve-test.lisp"  "expected_evolve.txt"  "evolve-test.lisp (self-optimization with receipts)"
run_test "supervisor-test.lisp" "expected_supervisor.txt" "supervisor-test.lisp (certifiable supervision)"
run_test "kg-test.lisp"      "expected_kg.txt"     "kg-test.lisp (knowledge graph)"
run_test "discover-test.lisp" "expected_discover.txt" "discover-test.lisp (command registry)"
run_test "commands-test.lisp" "expected_commands.txt" "commands-test.lisp (command smoke)"
run_test "proc-test.lisp"    "expected_proc.txt"   "proc-test.lisp (multi-process seam)"

# rusty-lsp speaks framed JSON-RPC on stdio — a scripted session instead of a golden diff
if python3 lsp-test.py > /dev/null 2>&1; then
    echo "✅  lsp-test.py (language server)"
    PASS=$((PASS+1))
else
    echo "❌  lsp-test.py (language server)"
    FAIL=$((FAIL+1))
fi

# ── Coverage ratchet ────────────────────────────────────────────────────────
COVFILE="$(mktemp)"
export RUSTY_COVERAGE_FILE="$COVFILE"
for f in tests.lisp new-features.lisp hello.lisp swarm.lisp symreg-test.lisp \
         synth-test.lisp prover-test.lisp robot-test.lisp pkg-test.lisp \
         testkit-test.lisp kg-test.lisp discover-test.lisp commands-test.lisp \
         proc-test.lisp evolve-test.lisp supervisor-test.lisp; do
    RUSTY_COVERAGE=1 "$RUSTY" "$f" >/dev/null 2>&1
done
# check runs WITHOUT RUSTY_COVERAGE so it doesn't record itself
run_test "coverage-check.lisp" "expected_coverage.txt" "coverage-check.lisp (ratchet)"
unset RUSTY_COVERAGE_FILE
rm -f "$COVFILE"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo "🎉 ALL PASSED" || exit 1
