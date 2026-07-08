---
name: verify
description: Confirm a Rusty (this repo) change actually works — run the golden-file test suite and exercise the specific behavior end-to-end.
---

# Verifying a Rusty change

1. Run the golden-file suite (builds release, then diffs the output of `tests.lisp` / `new-features.lisp` / `hello.lisp` against the matching `expected_*.txt`):
   ```bash
   ./run_tests.sh
   ```
2. For the specific behavior you changed, write a small scratch `.lisp` file that exercises it directly and run it (see the `run` skill) — reading stdout is the actual verification; a passing test suite alone doesn't confirm the change does what was intended.
3. When the change fixes a bug (capture/scoping issue, off-by-one, wrong output, etc.), reproduce the bug first: `git stash`, run the same scratch file to confirm the old behavior really is wrong, `git stash pop`, then re-run to confirm the fix. This is the only way to be sure the "fix" changed anything — see the macro-hygiene fix (`src/eval.rs`, `hygienic_rename`) for exactly this pattern (an arity-error crash before, clean output after).
4. If you touched `tests.lisp` or `new-features.lisp`, update the matching `expected_*.txt` (or add a new pair plus a `run_test` line in `run_tests.sh` for a new file) rather than hand-editing expected output to match whatever the interpreter currently prints.

Clean up scratch `.lisp` files when done; don't leave them in the repo root.
