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

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo "🎉 ALL PASSED" || exit 1
