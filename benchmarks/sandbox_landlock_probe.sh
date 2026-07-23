#!/usr/bin/env bash
# Copyright (c) 2026 Nicholas Vermeulen
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sandbox_landlock_probe.sh — the KERNEL half of the sandbox (0.82.0).
#
# (sandbox-enable! root) applies a userspace check_* funnel (the guaranteed
# floor, every platform) AND, on Linux >=5.13, a best-effort Landlock ruleset
# that confines the process to `root` at the kernel — closing the two residuals
# the userspace floor alone could not: (1) the check-vs-open TOCTOU, and (2) a
# FORGOTTEN guard on some file builtin (save-model/load-model were exactly that
# gap before 0.82.0 — the kernel refused them while userspace let them through).
#
# This is NOT a golden: Landlock availability is kernel-dependent, so
# "FullyEnforced" cannot be a portable expected-output row.  Run it by hand on a
# Landlock-capable kernel to confirm the kernel layer is actually live and hasn't
# silently regressed to floor-only.  The deterministic FLOOR behaviour (out-of-box
# ops refused with a "refused" string, in-box ops allowed) is pinned portably by
# the golden tests/sandbox-test.lisp.
#
# Expected on a Landlock-capable Linux kernel (>=5.13):
#   * ll-status  : "landlock: FullyEnforced"  (the kernel accepted + enforces it)
#   * in-box     : an in-box write succeeds under confinement (not broken)
#   * out-of-box : refused (floor catches it first; kernel would too)
# On a kernel without Landlock the status reads NotEnforced/not-applied and ONLY
# the floor holds — that is the honest best-effort degrade, not a failure here.

set -u
RUSTY="${RUSTY:-./target/release/rusty}"
BOX="/tmp/rusty-ll-probe-box"
OUT="/tmp/rusty-ll-probe-outside.json"
rm -rf "$BOX" "$OUT"; mkdir -p "$BOX"

if [ ! -x "$RUSTY" ]; then echo "build first: cargo build --release"; exit 2; fi

SCRIPT="$(mktemp /tmp/rusty-ll-probe-XXXX.lisp)"
cat > "$SCRIPT" <<EOF
(sandbox-enable! "$BOX")
(define (refused? t) (try-catch (begin (t) #f) (e) (string-contains? e "refused")))
(display (list 'kernel-status (sandbox-kernel-status))) (newline)
(display (list 'in-box   (try-catch (begin (save-model "$BOX/m.json" 7) 'ok) (e) 'FAIL))) (newline)
(display (list 'out-box  (refused? (lambda () (save-model "$OUT" 1))))) (newline)
EOF

echo "== landlock status (stderr) =="
STATUS="$(RUSTY_SANDBOX_DEBUG=1 "$RUSTY" "$SCRIPT" 2>&1 1>/dev/null)"
echo "$STATUS"

echo "== behaviour (stdout) =="
RUSTY_SANDBOX_DEBUG=1 "$RUSTY" "$SCRIPT" 2>/dev/null

echo "== leak check =="
if [ -f "$OUT" ]; then echo "LEAK: out-of-box file was written!"; else echo "no leak (out-of-box write did not land)"; fi

echo "== verdict =="
if echo "$STATUS" | grep -q "FullyEnforced"; then
  echo "KERNEL LAYER LIVE: Landlock FullyEnforced on this kernel."
elif echo "$STATUS" | grep -qE "NotEnforced|not applied"; then
  echo "FLOOR ONLY: kernel lacks Landlock (or it is disabled) — best-effort degrade, floor still holds."
else
  echo "UNEXPECTED: could not read a Landlock status line (regression?)."
fi

rm -f "$SCRIPT"; rm -rf "$BOX" "$OUT"
