# UX Pass + Three Laws — Design

**Date:** 2026-07-15 · **Owner-approved framing:** three laws (loop excluded by owner decision — "the other three for sure")
**Goal:** Before pushing the unpushed window (main is 13 ahead at v0.40.0), make Rusty and the safety-suite flagships approachable: one-command install, friendlier errors, and a single identity page framing wuwei / shouzhong / mingjian as three machine-checked laws of robotics, each with a 60-second quickstart.

## Why

- GTM decision of record: "easy means one install of rusty + one offline command with a 60s wow." The v0.40.0 discovery feature (help/apropos/describe, `/` sugar) started the usability story; this pass finishes it.
- The Asimov contrast is the hook precisely because his laws failed on natural-language ambiguity, interpreted by the robot itself. Ours are executable predicates, checked exhaustively over finite domains, enforced outside the model. Three is the culturally resonant number.
- Standing rules that this design deliberately preserves:
  - **Zero demos in the Rusty repo** — runnable demos stay in the app repos; Rusty gets docs and pointers.
  - **loop is a different buyer** — it appears on the Laws page only as a one-line coda ("one promise kept to people rather than robots"), never bundled into safety GTM.
  - **Claim discipline** — every law is stated as its narrow, reproducible check; never "safe AI," never "unjailbreakable."

## Deliverable 1: `docs/LAWS.md` + README hook (Rusty repo)

A single page, three sections + coda:

- **Law I — Honest Tools** (wuwei): an agent may not call a tool whose declared effects don't match its body. Mechanism: `check-effects` certifies the tool registry effect-honest as a boot precondition; `safe-call` contract-checks every call before the body runs. Narrow claim: static effect classification over recognized ops + per-call preconditions — "the allowlist can't lie."
- **Law II — Proven Control** (shouzhong): a controller may not act outside bounds proven safe over every reachable state. Mechanism: `check-exhaustive` inductive safety over finite integer state domains (120,351 states for the 3-D drone), gated actuators, `defrust` proof transfer to native. Narrow claim: exhaustive check on the stated finite domain — the LLM plans, the proof gates the actuator.
- **Law III — Truthful Record** (mingjian): what the agent did must replay to the same result. Mechanism: for deterministic plants, replay IS the audit; any edited log names its own divergence per tick; audits are kg-queryable. Narrow claim: log⇔claim consistency for deterministic plants.
- Each law carries: one-paragraph claim, the hybrid Rust+Lisp mechanism (which Rust checker + which Lisp library), and a **60-second offline quickstart** (install one binary, clone the app repo, run one command, what you should see). Quickstarts must be copy-paste and verified on a fresh install; no LLM required (live-LLM variants mentioned as optional).
- **Coda (two lines):** loop — "Rusty also keeps one promise to people rather than robots" + link; the small-hardware thesis — these laws ride on the device, not in the cloud.
- **README hook:** a short "Three Laws" section near the top of README.md linking to docs/LAWS.md and the three app repos. Docs-only; no version bump.

## Deliverable 2: Install path

- **Release binaries:** GitHub Releases with `rusty` + `rusty-lsp` for `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu` (musl if glibc-portability bites), plus `sha256sums.txt`. Built by a tag-triggered GitHub Actions workflow (`.github/workflows/release.yml`) beside the existing CI perf gate. `std.lisp` is embedded via `include_str!` so a bare binary works from any directory.
- **`install.sh` (repo root):** deliberately small and auditable (~40 lines): detect OS/arch → download the release binary + checksum → verify sha256 → install to `~/.local/bin` → print PATH hint. Fails loudly on unsupported platforms with the cargo fallback. README invites reading it first — the *verifiable* curl|sh, published checksums; this is a brand point, not an apology.
- **README install section rewrite**, in order: (1) curl|sh one-liner, (2) `cargo install --git https://github.com/TheLakeMan/rusty` , (3) from-clone build. Honest capability note: the binary alone runs the interpreter and all three law quickstarts; `defrust`/`graph-compile` JIT features additionally need `rustc` on PATH.
- **crates.io reservation (owner-approved 2026-07-15):** publish as **`rusty-lisp`** (`rusty` is name-squatted at 0.0.0). Package name `rusty-lisp`, binary names stay `rusty`/`rusty-lsp` (`cargo install rusty-lisp` installs both). Requires Cargo.toml metadata (`description`, `license = "AGPL-3.0-or-later"`, `repository`, `readme`) and an owner-side crates.io account/token; publish is permanent (yank-only). Prerequisite check before publishing: a `cargo install`ed binary must work from an arbitrary cwd — verify the std.lisp embedded fallback AND whether agent-tools.lisp (loaded from disk by std.lisp) degrades gracefully outside the repo; fix packaging (embed or graceful skip) if not.
- Non-goals: no Homebrew/AUR packaging, no Windows/macOS binaries in this pass (cargo path covers them).

## Deliverable 3: Did-you-mean errors (Rusty v0.41.0)

- On an `Undefined: 'name'` error (symbol lookup failure at eval time), two paths:
  - Close match exists → `Undefined: 'filtr' — did you mean 'filter'?`
  - No close match but the name is hyphenated → `Undefined: 'string-upcase' (try (apropos "string"))` (hint = prefix before the first `-`).
  - Neither → message unchanged.
- Candidates: every binding in the env chain + `SPECIAL_FORMS`; nearest by Levenshtein distance (cutoff 2, or 1 for names ≤3 chars so short typos don't match nonsense); ties broken lexicographically.
- **Zero cost on the happy path:** computed only when the error is being raised. Error path may walk the env; that is acceptable.
- Deterministic: ties broken by lexicographic order so golden tests are stable.
- Tests: extend `tests.lisp` or `new-features.lisp` with a try-catch capturing the suggestion text; goldens updated. All 15 existing checks stay green; the coverage ratchet polices any new command surface automatically.
- Version: minor bump to 0.41.0 (behavior change), same-commit Cargo.lock + README version line per convention.

## Deliverable 4: Per-app quickstart alignment (app repos)

- wuwei, shouzhong, mingjian READMEs each carry the same 60-second block the Laws page quotes (or the Laws page quotes what's already there — wuwei's demo-sandbox 60s lead exists; shouzhong/mingjian get theirs aligned).
- Each block verified end-to-end on a fresh install (binary from Deliverable 2, clean clone) before the docs claim it.
- App repos are separate commits/pushes; owner authorizes each push as usual.

## Release posture (owner decision 2026-07-15)

Tag **v0.41.0** for this pass; **hold v1.0.0** until external battle-testing (Hermes path) or a deliberate signal moment. Reserve the crates.io name now (see Deliverable 2). If 1.0 comes later, the one outstanding pre-tag item from the v0.37.0 freeze audit still applies: bless the defrust C ABI as f64-only + infallible for all of v1.

## Sequencing

1. Deliverables 1–3 land in the Rusty repo on the current unpushed window (branch per plan discipline).
2. Owner pushes Rusty first — shouzhong's pushed HEAD already requires Rusty ≥0.36.0, and the Laws page/quickstarts reference the release install.
3. Tag v0.41.0 → release workflow produces binaries; verify install.sh against the real release; owner publishes `rusty-lisp` to crates.io (needs owner's account/token).
4. Deliverable 4 in the app repos afterward, each verified against the released binary.

## Verification

- `./run_tests.sh` green (15 checks + whatever this adds) at every commit.
- Did-you-mean: golden-tested suggestion text; fib-class benchmark unchanged (error path only).
- install.sh: run against the real GitHub release on this machine (x86_64); aarch64 binary at minimum spot-checked for existence/checksum (no aarch64 hardware assumed).
- Each quickstart: executed verbatim from a scratch directory with only the installed binary on PATH.
- Laws page claims: every number/claim on the page must be one already verified in the app repos' goldens or benchmarks (link them); no new unverified claims.

## Out of scope (explicitly deferred)

- Runtime error source positions (file:line in eval errors) — real engineering, its own spec/plan later.
- loop as a fourth law, TUI, crates.io, non-Linux binaries, any new demo files in Rusty.
