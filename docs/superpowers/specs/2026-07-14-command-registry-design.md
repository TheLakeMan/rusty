# Command registry, discovery & coverage — design

**Date:** 2026-07-14
**Status:** approved design, pre-implementation
**Repo:** rusty (the interpreter)

## Problem

Rusty exposes ~280 commands (~160 builtins, ~94 std.lisp functions, ~24 special
forms) and gives users two poor tools for them:

1. **Discovery.** `(help)` is a hand-maintained static cheat-sheet (13 `println`
   lines in `interp.rs`). It is already incomplete (no tensors, kg, autodiff,
   agents, trace, …) and silently drifts from the real command set. There is no
   search, no per-command lookup, no way to browse by area.
2. **Verification.** There is no systematic answer to "does every command
   work?" Golden tests cover behaviours, but nothing enumerates the command
   surface or reports which commands no test ever exercises.

Both problems share a root: there is no single, authoritative, non-drifting
map of "every command that exists." The interpreter already *has* that map at
runtime (the LSP harvests `genv.vars.keys()` + a special-forms list for
completion) — it is simply not exposed or used for help/coverage.

## Goal

One self-describing **command registry**, derived from the live interpreter
(not hand-authored), that is the single source of truth for both:

- **Navigation** — browse by category, search by name, describe one command.
- **Verification** — a truth-standing coverage ratchet: every command must be
  *actually executed* by the test suite, or be on an explicit reasoned
  allowlist, or the suite fails.

## Non-goals (YAGNI)

- **No hand-authored per-command prose docs.** The registry row leaves a slot
  for a doc line, but v1 does not populate 280 of them. Docs can be added
  incrementally later into the same structure; nothing is redone.
- **No source-file parsing** to derive metadata (the rejected "Approach B").
  Everything comes from the running env plus ~20 category tags.
- **No TUI / command palette.** The interactive affordance is a thin REPL `/`
  prefix, nothing more.
- **No auto-invocation of commands** to test them. Coverage measures what the
  existing suite executes; it does not fabricate calls.

## Architecture

Four components. C1 is the only non-trivial interpreter change; C2 is a library;
C3 is REPL sugar; C4 is verification plumbing.

### C1 — the registry (Rust, one builtin)

A new builtin `(command-registry)` returns all commands as plain Lisp data: a
list of rows

```
(name kind signature category doc)
```

- **name** — string. Sourced from `genv.vars.keys()` ∪ the special-forms list.
- **kind** — symbol: `builtin` | `function` | `macro` | `special-form`,
  read from the bound `Value` variant (the same distinction `macro?`/`procedure?`
  already make today); special forms come from the shared list, not the env.
- **signature** — string. For `function`s (std.lisp `Lambda`s) formatted from
  the value's `params`/`rest` (`(map fn lst)`, `(foo a b . rest)`) — free from
  the value, no parsing. `""` for builtins/special forms (arity not tracked).
- **category** — symbol (see below). `other` when untagged.
- **doc** — string, `""` in v1 (reserved slot).

**Categories** are the one thing not present in the env, added cheaply:

- *Builtins:* ~20 `cat!("Arithmetic")`-style markers placed at the existing
  section boundaries in `setup_builtins`. The `b!`/`alias!` macros record
  `(name → current-category)` into a side table as each command registers.
  Cost: ~20 lines, not 280.
- *std.lisp functions:* one small grouped table near the top/bottom of
  `std.lisp` (e.g. `(categorize! 'lists '(map filter foldl …))`), ~10 lines.
- Anything unlabelled falls into `other`; the coverage test (C4) reports the
  `other` count so it can be driven down over time, but `other` is not a failure.

**Shared special-forms list.** The special-forms names currently live in
`lsp_main.rs` as `SPECIAL_FORMS`. Move them to a shared location (e.g. a `pub
const` in `eval.rs` or a small `commands` module) so the LSP, the registry, and
`(help)` all read one list. This removes an existing duplication.

### C2 — discovery API (Lisp, new `discover.lisp`)

A pure-Lisp layer on top of `(command-registry)`, auto-loaded by `std.lisp` the
same way `agent-tools.lisp` is. No interpreter code.

- `(help)` — replaces the static 13-liner: prints each category with its command
  count and a one-line hint on drilling in.
- `(help 'lists)` — lists a category's commands, each with its signature.
- `(apropos "str")` — every command whose name contains `str` (substring),
  grouped by category, showing kind + signature.
- `(describe 'map)` — one command's kind, category, signature, and doc (when a
  doc exists).

### C3 — `/` REPL sugar (Rust, `main.rs`, small)

In the REPL only, a line whose first non-space char is `/` runs `apropos` on the
rest: `/map` → `(apropos "map")`. Does not affect script execution or the LSP.
May ship one commit after C1–C2; it is independent.

### C4 — coverage ratchet (truth-standing)

"Exercised by a test" is measured by **runtime call-tracking**, not static text
scanning — a name appearing in a comment or an un-executed quoted form must not
count as covered.

- **Coverage mode.** Extend the existing `trace.rs` thread-local machinery with
  a coverage set that, when enabled (env var, e.g. `RUSTY_COVERAGE=1`), records
  the name of every builtin / std.lisp function / special form **actually
  invoked**. Off by default → zero cost on normal runs (guard the record behind
  the same kind of `if enabled` check tracing already uses; do not add work to
  the hot path when off).
- **Accumulation across the suite.** Each golden `.lisp` file runs in its own
  process, so on interpreter exit (when coverage mode is on) the process appends
  its exercised-name set to `$RUSTY_COVERAGE_FILE`. `run_tests.sh` gains a
  coverage pass that sets the file, runs the existing golden files (which
  naturally exercise commands), then runs a final check.
- **The ratchet.** A checked-in, reasoned allowlist (`coverage-allowlist.lisp`)
  names the commands intentionally not golden-exercised, each with a one-line
  reason (`llm` — needs a live model; `shell` — side effects; `agent`,
  `react-loop` — LLM loop; `checkpoint`, `now-micros`, …). The final check
  computes `uncovered = all-commands − exercised` and:
  - **fails** if any `uncovered` command is **not** on the allowlist (a new
    untested command — the ratchet), listing the offenders;
  - **fails** if any allowlist entry **is** exercised (a stale exemption — keeps
    the allowlist honest, "stand for truth"), listing them for removal.
  Wired into `run_tests.sh` so it emits a stable `COVERAGE OK` line on success;
  a violation changes the output and fails the run.

## Data flow

```
setup_builtins (b! + cat! markers) ─┐
std.lisp defines + categorize! ─────┤→ live env + category side-table
special-forms shared const ─────────┘
                                     │
              (command-registry) ────┴──→ list of (name kind signature category doc)
                                            │
                    ┌───────────────────────┼───────────────────────┐
              discover.lisp             main.rs `/`             coverage check
           (help/apropos/describe)      (REPL sugar)        (registry − exercised
                                                             ⊆ allowlist ?)
```

## Testing

- **`discover-test.lisp` (new golden).** Asserts registry completeness (every
  env name + special form is present, so no command is ever invisible), prints
  deterministic category counts, and exercises `apropos`/`describe`/`help` on a
  few stable names. Locks the discovery API's behaviour.
- **Coverage check (new, in `run_tests.sh`).** The C4 ratchet; emits
  `COVERAGE OK` or a violation list. This is the "do they all work?" gate.
- Both are deterministic and fit the existing golden-file discipline. Neither
  prints timings.

## Files touched

- `src/interp.rs` — `(command-registry)` builtin; `cat!` marker + `b!`/`alias!`
  recording category; coverage-record hook at call sites (or via the existing
  builtin-dispatch path).
- `src/eval.rs` (or a new `src/commands.rs`) — shared special-forms const;
  special-form + lambda/macro coverage recording; kind classification helper.
- `src/trace.rs` — coverage set (enable/record/dump), reusing the thread-local
  pattern.
- `src/lsp_main.rs` — use the shared special-forms const (remove the local copy).
- `src/main.rs` — REPL `/` sugar.
- `std.lisp` — `categorize!` table; auto-load `discover.lisp`.
- `discover.lisp` (new) — help/apropos/describe.
- `coverage-allowlist.lisp` (new) — reasoned exemptions.
- `discover-test.lisp` + `expected_discover.txt` (new golden pair).
- `run_tests.sh` — register `discover-test.lisp`; add the coverage pass.
- `docs/*` — note the registry/coverage in ARCHITECTURE.md; retire the static
  `(help)` description.

## Decisions made (in brainstorming)

- One registry powering both goals, **derived from the live env** — not
  hand-authored, not source-parsed (Approach A).
- Row shape `(name kind signature category doc)`; docs slot reserved, empty in v1.
- Categories via ~20 builtin section tags + a small std.lisp grouping table.
- Coverage measured by **runtime call-tracking** (truthful), not static scan.
- **Hard ratchet now:** uncovered must ⊆ a reasoned allowlist, plus stale-entry
  detection. "We stand for truth."

## Open questions for implementation

- Exact `Value` variant for macros vs functions — confirm during implementation
  (mirror what `macro?` already does).
- Cheapest coverage-record insertion point that stays zero-cost when off:
  likely the builtin/lambda/special-form dispatch sites in `eval.rs`, guarded by
  the trace-style `enabled` flag. Verify no measurable hit on `fib`/`list_bench`
  with coverage OFF (per the optimization discipline).
- Whether `describe`/`apropos` output format needs to also feed LSP hover (nice
  future alignment; not required for v1).
