# Contributing to Rusty

Thank you for your interest in Rusty. This document covers two things: the
**legal terms** under which contributions are accepted, and the **technical
standards** every change must meet. Both exist for the same reason — Rusty makes
narrow, checkable claims about verified and deterministic behaviour, and neither
its licensing story nor its foundation can rest on sand.

---

## Contributor License Agreement (CLA)

Rusty is offered under a **dual license**: the [GNU Affero General Public License
v3 or later](./LICENSE) for the open-source community, and a separate commercial
license for those whose use the AGPL doesn't fit (see [COMMERCIAL.md](./COMMERCIAL.md)).
That dual model only works if a single party holds the right to relicense the
**entire** codebase. A contribution accepted under AGPL-only terms could not be
included in a commercial license — so, to keep the project whole, contributions
require the grant below.

**By submitting a contribution** (a pull request, patch, or any other change) to
this project, you agree that:

1. **You own the rights** to the contribution, or have the necessary permission
   to submit it under these terms — and it is your original work (or you have
   clearly identified any third-party material and its license).
2. **You grant Nicholas Vermeulen** a perpetual, worldwide, non-exclusive,
   royalty-free, irrevocable license to use, reproduce, modify, distribute, and
   **relicense** your contribution, including as part of Rusty under **both** the
   AGPL-3.0-or-later **and** any commercial license terms now or later offered.
3. **You retain copyright** to your contribution. This grant is a license, not an
   assignment — your name stays on your work, and you may use your own
   contribution however you like elsewhere.
4. Your contribution is provided **"as is"**, without warranty of any kind.

This grant is what lets the project remain dual-licensed as it grows. Without it,
a single merged change under AGPL-only terms would permanently fragment the
licensing of the file it touched.

---

## Technical standards

Rusty's value is that its claims are *checked*, not asserted. A change that
weakens that discipline weakens the whole project, so contributions are held to
the following — the same rules the maintainer holds themselves to:

- **Narrow claims only.** Say "proven on the declared domain", "sameness, never
  safety" — never "safe", "unbreakable", or "forgery-proof". A claim's own caveat
  marks where it's already known false; state the caveat, don't hide it.
- **Tests-first, real before/after.** A clean build is not evidence. Every new
  language behaviour needs a golden-test row (`tests/*.lisp` + the matching
  `tests/expected_*.txt`); every bug fix must reproduce the bug first. See
  [CLAUDE.md](./CLAUDE.md) and `run_tests.sh` for the golden-file harness (there
  is deliberately no `cargo test` suite).
- **Zero external runtime dependencies.** The engine depends only on the Rust
  standard library, ordinary Cargo crates, or `rustc` itself — never on an
  external *engine* (no Lean, TLA+, PyTorch, candle, or a WASM runtime).
  "Verification" and "ML" here mean a self-built equivalent, benchmarked against
  external systems, never depending on them. Adding a new outside crate is a
  maintainer decision — open an issue first.
- **Benchmarks are medians on one machine state**, with a checked-in reproduce
  script. Quoted absolutes rot; publish a ratio, a crossover, and the harness.
- **Match the surrounding code** — its idiom, naming, and comment density. New
  builtins and special forms go in `interp.rs`/`eval.rs` so every entry point
  (CLI, LSP, Python bridge) gets them.

The full architectural context lives in [CLAUDE.md](./CLAUDE.md) — read it before
proposing a change to the interpreter core.

---

## How to submit

1. Open an issue describing the change first for anything non-trivial — it saves
   both of us from work that doesn't fit the direction.
2. Keep pull requests focused: one concern per PR.
3. Run `./run_tests.sh` and make sure the golden suite passes before submitting.
4. By opening the PR, you agree to the CLA above.

Questions about contributing or licensing: **thelakeman@protonmail.com**.

☯ *In memory of my brother.*
