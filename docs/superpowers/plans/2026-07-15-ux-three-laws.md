# UX Pass + Three Laws Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Rusty installable in one command, friendly on typos, and framed by a Three Laws identity page — everything landing in the current unpushed window so the owner pushes one coherent v0.41.0 release.

**Architecture:** Did-you-mean lives at the two `Undefined:` raise sites in `eval.rs` (error path only, registry-style env walk + Levenshtein). Release binaries come from a tag-triggered GitHub Actions workflow; `install.sh` is a tiny auditable fetch-verify-install script over those releases. `docs/LAWS.md` is docs-only and quotes quickstarts that live (and are verified) in the app repos.

**Tech Stack:** Rust (interpreter), Rusty Lisp goldens, GitHub Actions, POSIX sh.

**Spec:** `docs/superpowers/specs/2026-07-15-ux-three-laws-design.md` (owner-approved).

## Global Constraints

- Zero external runtime dependencies — Rust stdlib, existing crates, or `rustc` only. No new crates.
- Golden-file testing only; never timings in golden output; all 15 existing checks stay bit-identical except goldens this plan deliberately extends.
- Version: exactly one bump this pass, `0.40.0` → `0.41.0`, in Task 1 (Cargo.toml + Cargo.lock rebuilt + README `**Version:**` line, same commit).
- The coverage ratchet is live: new command surface must be exercised or reasoned into `coverage-allowlist.lisp` — prefer a test; never pad the allowlist.
- Zero demo files in the Rusty repo — runnable demos stay in the app repos.
- ☯ symbol and the dedication line "In memory of my brother." are untouchable.
- NEVER push, NEVER tag, NEVER `cargo publish` — those are the owner's post-plan checklist.
- Work on branch `ux-three-laws` off current `main` (`git checkout -b ux-three-laws`).

---

### Task 1: Did-you-mean errors (v0.41.0)

**Files:**
- Modify: `src/eval.rs` (helper + the two `Undefined:` raise sites at ~152 and ~168)
- Modify: `new-features.lisp`, `expected_new_features.txt`
- Modify: `Cargo.toml`, `Cargo.lock`, `README.md` (version bump)

**Interfaces:**
- Produces: `fn undefined_error(env: &Env, name: &str) -> String` in `eval.rs` (module-private). Both raise sites call it instead of `format!("Undefined: '{}'", s)`. Message contract (exact):
  - close match: `Undefined: 'filtr' — did you mean 'filter'?`
  - no match, hyphenated name: `Undefined: 'string-upcase' (try (apropos "string"))`
  - neither: `Undefined: 'zzqx'` (unchanged)

- [ ] **Step 1: Write the failing golden test.** Append to `new-features.lisp`:

```lisp
;; ── did-you-mean on Undefined (v0.41.0) ─────────────────────────────────
(println "-- did-you-mean --")
(println (try-catch (filtr even? (list 1 2)) (e) e))
(println (try-catch (defin x 5) (e) e))
(println (try-catch (string-upcase "hi") (e) e))
(println (try-catch (zzqx 1) (e) e))
```

- [ ] **Step 2: Run to verify current (old) messages** — `cargo build --release && ./target/release/rusty new-features.lisp | tail -5`. Expected: the four lines print the OLD plain `Undefined: '...'` messages (this is the RED state — the suite would fail against the new expected output).

- [ ] **Step 3: Implement.** In `src/eval.rs`, near the top (after `SPECIAL_FORMS`), add:

```rust
/// Plain two-row Levenshtein distance — only ever runs on the error path.
fn levenshtein(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for i in 1..=a.len() {
        cur[0] = i;
        for j in 1..=b.len() {
            let sub = prev[j - 1] + if a[i - 1] == b[j - 1] { 0 } else { 1 };
            cur[j] = sub.min(prev[j] + 1).min(cur[j - 1] + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// Build the Undefined error message, with a did-you-mean suggestion when a
/// bound name (or special form) is within edit distance 2 (1 for names ≤3
/// chars), ties broken lexicographically; else an apropos hint for hyphenated
/// names. Error path only — never runs on successful lookups.
fn undefined_error(env: &Env, name: &str) -> String {
    let cutoff = if name.len() <= 3 { 1 } else { 2 };
    let mut best: Option<(usize, String)> = None;
    let mut consider = |cand: &str| {
        if cand == name { return; }
        let d = levenshtein(name, cand);
        if d <= cutoff {
            let better = match &best {
                None => true,
                Some((bd, bn)) => d < *bd || (d == *bd && cand < bn.as_str()),
            };
            if better { best = Some((d, cand.to_string())); }
        }
    };
    for sf in SPECIAL_FORMS { consider(sf); }
    let mut frame = Some(env.clone());
    while let Some(f) = frame {
        for k in f.borrow().vars.keys() { consider(k); }
        let parent = f.borrow().parent.clone();
        frame = parent;
    }
    if let Some((_, s)) = best {
        return format!("Undefined: '{}' — did you mean '{}'?", name, s);
    }
    match name.split_once('-') {
        Some((prefix, _)) if !prefix.is_empty() =>
            format!("Undefined: '{}' (try (apropos \"{}\"))", name, prefix),
        _ => format!("Undefined: '{}'", name),
    }
}
```

Then replace BOTH raise sites (leaf fast path ~line 152 and trampoline ~line 168):

```rust
                return EnvFrame::get(env, s)
                    .ok_or_else(|| undefined_error(env, s));
```

(the trampoline site takes `&env`). Note the closure borrows `best` mutably — if the borrow checker objects to the closure form, inline it as a plain loop over an iterator chain; behavior contract above is what matters.

- [ ] **Step 4: Run and eyeball the four lines** — `cargo build --release && ./target/release/rusty new-features.lisp | tail -5`. Expected EXACTLY:

```
-- did-you-mean --
Undefined: 'filtr' — did you mean 'filter'?
Undefined: 'defin' — did you mean 'define'?
Undefined: 'string-upcase' (try (apropos "string"))
Undefined: 'zzqx'
```

If any line differs (e.g. a closer neighbor exists in the env than this plan predicted), STOP and report the actual output — do not silently accept different text without checking the neighbor really is nearer by the contract (distance, then lexicographic).

- [ ] **Step 5: Regenerate the golden and bump the version.** Update `expected_new_features.txt` by appending the verified lines (regenerate the file with `./target/release/rusty new-features.lisp > expected_new_features.txt` ONLY if the rest of the diff is empty — check with `git diff expected_new_features.txt` that nothing above the new block changed). Set `version = "0.41.0"` in Cargo.toml, update README.md's `**Version:** 0.40.0` line to `0.41.0`, `cargo build --release` so Cargo.lock syncs.

- [ ] **Step 6: Full suite** — `./run_tests.sh 2>&1 | tail -4`. Expected: `15 passed, 0 failed` (the ratchet is indifferent: no new commands were added).

- [ ] **Step 7: Commit**

```bash
git add src/eval.rs new-features.lisp expected_new_features.txt Cargo.toml Cargo.lock README.md
git commit -m "feat: did-you-mean suggestions on Undefined errors (v0.41.0)"
```

---

### Task 2: crates.io packaging readiness (rename to `rusty-lisp`)

**Files:**
- Modify: `Cargo.toml` (package name + metadata + include list), `Cargo.lock` (follows)

**Interfaces:**
- Produces: package publishable as `rusty-lisp`; binaries KEEP their names `rusty`/`rusty-lsp` (the `[[bin]]` names, not the package name, govern). `[lib] name = "rusty"` stays, so `use rusty::` paths and the PyO3 module are untouched.

- [ ] **Step 1: Update Cargo.toml `[package]`:**

```toml
[package]
name = "rusty-lisp"
version = "0.41.0"
edition = "2021"
description = "A modern Lisp interpreter in Rust with TCO, macros, JIT, verification checkers, and AI agent capabilities"
license = "AGPL-3.0-or-later"   # commercial licensing available on inquiry
repository = "https://github.com/TheLakeMan/rusty"
readme = "README.md"
default-run = "rusty"   # `cargo run` starts the REPL (not rusty-lsp)
include = ["src/**", "*.lisp", "Cargo.toml", "README.md", "LICENSE*", "docs/SPEC.md", "docs/TUTORIAL.md"]
```

(Keep every existing section below `[package]` unchanged. If there is no `LICENSE*` file at the repo root, STOP and report — crates.io needs `license` (present) but the tarball should carry the text too.)

- [ ] **Step 2: Rebuild + suite** — `cargo build --release && ./run_tests.sh 2>&1 | tail -3`. Expected: 15 passed. (Cargo.lock's package entry renames itself.)

- [ ] **Step 3: Verify the package contents** — `cargo package --list --allow-dirty | head -50` and check: `std.lisp`, `agent-tools.lisp`, `kg.lisp`, `symreg.lisp`, `synth.lisp`, `prover.lisp`, `robot.lisp`, `pkg.lisp`, `testkit.lisp` all present; `cargo package --allow-dirty 2>&1 | tail -3` builds clean and the reported tarball size is well under 10 MB. Do NOT `cargo publish`.

- [ ] **Step 4: Verify a cargo-installed binary works from an arbitrary cwd** —

```bash
cargo install --path . --bin rusty --root /tmp/rusty-cwd-test
cd / && printf '(println (+ 1 2))\n(println (car (command-registry)))\nquit\n' | /tmp/rusty-cwd-test/bin/rusty
```

Expected: banner, `3`, one registry row, no error about std.lisp (it's embedded via `include_str!`; `agent-tools.lisp` is skipped silently by std.lisp's try-catch — confirm no error line appears). Clean up: `rm -rf /tmp/rusty-cwd-test`.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml Cargo.lock
git commit -m "build: publish-ready packaging — package renamed rusty-lisp, metadata + include list (binaries stay rusty/rusty-lsp)"
```

---

### Task 3: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Produces: on pushing a tag `v*`, a GitHub Release containing `rusty-<tag>-x86_64-unknown-linux-gnu.tar.gz`, `rusty-<tag>-aarch64-unknown-linux-gnu.tar.gz`, and a matching `.sha256` file per tarball. Each tarball holds the `rusty` and `rusty-lsp` binaries. Task 4's install.sh consumes exactly these names.

- [ ] **Step 1: Write `.github/workflows/release.yml`:**

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

env:
  CARGO_TERM_COLOR: always

jobs:
  build:
    name: Build ${{ matrix.target }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - target: x86_64-unknown-linux-gnu
          - target: aarch64-unknown-linux-gnu
            linker: gcc-aarch64-linux-gnu
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust (stable)
        uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}

      - name: Install cross linker
        if: matrix.linker != ''
        run: |
          sudo apt-get update
          sudo apt-get install -y ${{ matrix.linker }}
          echo 'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc' >> "$GITHUB_ENV"

      - name: Build
        run: cargo build --release --target ${{ matrix.target }} --bins

      - name: Package
        run: |
          NAME="rusty-${GITHUB_REF_NAME}-${{ matrix.target }}"
          mkdir "$NAME"
          cp "target/${{ matrix.target }}/release/rusty" "target/${{ matrix.target }}/release/rusty-lsp" "$NAME/"
          tar czf "$NAME.tar.gz" "$NAME"
          sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"

      - name: Upload to release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            rusty-*.tar.gz
            rusty-*.tar.gz.sha256
```

- [ ] **Step 2: Validate the YAML** — `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"` (if PyYAML is missing, use `actionlint` if installed; if neither exists, report which check was skipped). Also sanity-build the host target locally: `cargo build --release --target x86_64-unknown-linux-gnu --bins 2>&1 | tail -1` → `Finished`.

- [ ] **Step 3: State the honest limit in the commit.** The aarch64 leg and the release upload can only be exercised by a real tag push (owner-gated) — say so in the commit body.

```bash
git add .github/workflows/release.yml
git commit -m "ci: tag-triggered release workflow — linux x86_64 + aarch64 tarballs with sha256s

aarch64 leg and release upload are exercised by the first real tag (owner-gated);
YAML validated and the x86_64 build verified locally."
```

---

### Task 4: install.sh

**Files:**
- Create: `install.sh` (repo root, mode 755)

**Interfaces:**
- Consumes: the release artifact names from Task 3.
- Produces: `curl -fsSL https://raw.githubusercontent.com/TheLakeMan/rusty/main/install.sh | sh` installs `rusty` + `rusty-lsp` to `~/.local/bin`. Overrides for testing/pinning: `RUSTY_VERSION` (tag, default = latest via GitHub API), `RUSTY_INSTALL_BASE` (default `https://github.com/TheLakeMan/rusty/releases/download`), `RUSTY_INSTALL_DIR` (default `$HOME/.local/bin`).

- [ ] **Step 1: Write `install.sh`:**

```sh
#!/bin/sh
# install.sh — fetch, VERIFY (sha256), and install the rusty binaries.
# Small on purpose: read it before you run it.
#   RUSTY_VERSION       tag to install (default: latest release)
#   RUSTY_INSTALL_BASE  release download base (default: GitHub releases)
#   RUSTY_INSTALL_DIR   install dir (default: ~/.local/bin)
set -eu

REPO="TheLakeMan/rusty"
BASE="${RUSTY_INSTALL_BASE:-https://github.com/$REPO/releases/download}"
DIR="${RUSTY_INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  TARGET="x86_64-unknown-linux-gnu" ;;
  Linux-aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
  *) echo "No prebuilt binary for $(uname -s)/$(uname -m)." >&2
     echo "Build from source instead: cargo install rusty-lisp" >&2
     exit 1 ;;
esac

VERSION="${RUSTY_VERSION:-$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)}"
[ -n "$VERSION" ] || { echo "Could not determine latest release tag." >&2; exit 1; }

NAME="rusty-$VERSION-$TARGET"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching $NAME.tar.gz ..."
curl -fsSL -o "$TMP/$NAME.tar.gz"        "$BASE/$VERSION/$NAME.tar.gz"
curl -fsSL -o "$TMP/$NAME.tar.gz.sha256" "$BASE/$VERSION/$NAME.tar.gz.sha256"

echo "Verifying checksum ..."
(cd "$TMP" && sha256sum -c "$NAME.tar.gz.sha256" >/dev/null)

tar xzf "$TMP/$NAME.tar.gz" -C "$TMP"
mkdir -p "$DIR"
install -m 755 "$TMP/$NAME/rusty" "$TMP/$NAME/rusty-lsp" "$DIR/"

echo "Installed rusty + rusty-lsp to $DIR"
case ":$PATH:" in
  *":$DIR:"*) ;;
  *) echo "NOTE: $DIR is not on your PATH — add: export PATH=\"$DIR:\$PATH\"" ;;
esac
echo "Note: the interpreter is fully self-contained; defrust/graph-compile (JIT) additionally need rustc on PATH."
"$DIR/rusty" --help >/dev/null 2>&1 || true
```

`chmod +x install.sh`.

- [ ] **Step 2: End-to-end test against a fake local release.** Build a fixture mimicking Task 3's layout and serve it:

```bash
S=/tmp/fake-release/v9.9.9 && mkdir -p "$S"
NAME="rusty-v9.9.9-x86_64-unknown-linux-gnu"
mkdir "/tmp/$NAME" && cp target/release/rusty target/release/rusty-lsp "/tmp/$NAME/"
tar czf "$S/$NAME.tar.gz" -C /tmp "$NAME"
(cd "$S" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
(cd /tmp/fake-release && python3 -m http.server 8931 >/dev/null 2>&1 &) && sleep 1
RUSTY_VERSION=v9.9.9 RUSTY_INSTALL_BASE=http://127.0.0.1:8931 RUSTY_INSTALL_DIR=/tmp/rusty-install-test sh install.sh
printf 'quit\n' | /tmp/rusty-install-test/rusty | head -1
```

Expected: `Verifying checksum ...` passes, `Installed rusty + rusty-lsp to /tmp/rusty-install-test`, and the banner line `☯ Rusty v0.41.0 — A Lisp in Rust`. Negative test: corrupt the tarball (`echo x >> "$S/$NAME.tar.gz"`) and re-run — the script MUST fail at the checksum step with nonzero exit. Kill the server and clean up `/tmp/fake-release /tmp/rusty-install-test "/tmp/$NAME"`.

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: verifiable install.sh — fetch, sha256-verify, install release binaries"
```

---

### Task 5: docs/LAWS.md + README (Three Laws hook + install rewrite)

**Files:**
- Create: `docs/LAWS.md`
- Modify: `README.md` (new Three Laws section near the top; install section rewritten around line 45)

**Interfaces:**
- Consumes: install.sh (Task 4) and the app repos at `~/projects/artifacts/wuwei`, `~/projects/artifacts/shouzhong`, `~/projects/artifacts/mingjian` (read their READMEs/demo files for the quickstart commands; wuwei has `demo-sandbox.lisp` with a 60-second README lead, mingjian has `demo-receipt.lisp`, shouzhong's README shows its offline demo/golden commands).

- [ ] **Step 1: Extract and VERIFY each flagship quickstart.** For each app repo: read its README's demo lead, then from a scratch directory run the demo command verbatim against `./target/release/rusty` (put it on PATH first: `export PATH="$PWD/target/release:$PATH"`), from a fresh `git clone` of the local repo (`git clone ~/projects/artifacts/wuwei /tmp/qs-wuwei` etc. — clone, don't cd into the working copies, so uncommitted state can't leak into what the docs claim). Record for each: the exact commands, and a 3–6 line output excerpt showing the money shot — wuwei: a gated call REJECTED; shouzhong: an out-of-bounds actuation refused by the gate; mingjian: a forged log's breach named. Each must run offline (no LLM) and exit 0. If any repo's demo needs anything beyond `rusty` + the clone, STOP and report rather than papering over it.

- [ ] **Step 2: Write `docs/LAWS.md`** with this exact structure (prose below is the approved copy; splice in the verified quickstart blocks from Step 1):

```markdown
# Three Laws, Machine-Checked

Asimov's Three Laws were fiction — natural language, interpreted by the robot
itself, and every story is about how that fails. These three are different on
both counts: they are executable predicates, checked exhaustively over finite
domains, enforced outside the model. The LLM can plan. It cannot overrule a law.

Each law is one small, public codebase built on [Rusty](../README.md) — a
zero-dependency Lisp interpreter in Rust whose verification checkers
(`check-effects`, `check-exhaustive`, `check-types`) are built in, not bolted on.
Every claim below is the narrow, reproducible one; nothing here says "safe AI."

## Law I — Honest Tools · [wuwei](https://github.com/TheLakeMan/wuwei)

**An agent may not call a tool whose declared effects don't match its body.**
At boot, `check-effects` statically certifies every tool in the registry is
effect-honest — the allowlist can't lie — and `safe-call` contract-checks each
call's preconditions before the body runs. Refuse-by-default.

[verified 60-second quickstart block]

## Law II — Proven Control · [shouzhong](https://github.com/TheLakeMan/shouzhong)

**A controller may not act outside bounds proven safe over every reachable state.**
`check-exhaustive` proves the safety property inductively over the full finite
state domain (120,351 states for the 3-D drone with gusts), and actuators are
gated: a command outside the proven envelope is refused before it actuates.

[verified 60-second quickstart block]

## Law III — Truthful Record · [mingjian](https://github.com/TheLakeMan/mingjian)

**What the agent did must replay to the same result.**
For deterministic plants, replay IS the audit: an edited log names its own
divergence, tick by tick. Audits are data — queryable through Rusty's built-in
knowledge graph.

[verified 60-second quickstart block]

---

These laws ride on the device, not in the cloud: one small static binary, no
external runtime dependencies, proofs re-checked in milliseconds when compiled.

Rusty also keeps one promise to people rather than robots:
[loop](https://github.com/TheLakeMan/loop), a memory vessel for the living.
```

- [ ] **Step 3: README hook.** Add after the README's opening/badges section (before the feature list):

```markdown
## The Three Laws

wuwei, shouzhong, and mingjian — three small codebases built on Rusty — frame
what this interpreter is for: **Honest Tools** (an agent may not call a tool
whose declared effects don't match its body), **Proven Control** (a controller
may not act outside bounds proven safe over every reachable state), and
**Truthful Record** (what the agent did must replay to the same result).
Machine-checked, not fictional: [docs/LAWS.md](docs/LAWS.md).
```

- [ ] **Step 4: README install rewrite.** Replace the current install snippet (the `cargo install --path .` block around line 45) with, in this order:

```markdown
### Install

```sh
# 1. Prebuilt binary (Linux x86_64 / aarch64) — small script, read it first:
curl -fsSL https://raw.githubusercontent.com/TheLakeMan/rusty/main/install.sh | sh

# 2. Via cargo (any platform with Rust):
cargo install rusty-lisp

# 3. From a clone:
cargo install --path . --bin rusty --root ~/.local
```

The binary is self-contained (stdlib embedded). The `defrust` / `graph-compile`
JIT features shell out to `rustc`, so they additionally need a Rust toolchain
on PATH — everything else, including all three Law quickstarts, runs without one.
```

Keep the ☯ header and the dedication line untouched; `git diff README.md` must show no changes to them.

- [ ] **Step 5: Verify docs.** `./run_tests.sh 2>&1 | tail -3` (docs-only — expect 15 passed, nothing regenerated). Check every relative link in LAWS.md and README resolves (`docs/LAWS.md` from README, `../README.md` from LAWS.md).

- [ ] **Step 6: Commit**

```bash
git add docs/LAWS.md README.md
git commit -m "docs: Three Laws page + README hook and install rewrite"
```

---

## Post-plan: OWNER-GATED release checklist (not agent tasks)

1. Merge `ux-three-laws` → `main`; owner pushes `main` (first push since b42e61f — shouzhong's pushed HEAD already needs Rusty ≥0.36.0, so Rusty going first is correct).
2. Owner tags: `git tag v0.41.0 && git push origin v0.41.0` → release workflow builds both tarballs; check the Actions run and the Release page (2 tarballs + 2 .sha256).
3. Verify install.sh against the REAL release on this machine: `curl -fsSL .../install.sh | sh` into a temp `RUSTY_INSTALL_DIR`, banner shows v0.41.0.
4. Owner publishes to crates.io (their account/token): `cargo login`, `cargo publish` — permanent; verify `cargo install rusty-lisp` afterward.
5. Deliverable 4 (app repos): align wuwei/shouzhong/mingjian READMEs with the LAWS.md quickstarts, re-verify each against the *released* binary, owner pushes each. (Small enough to run without its own plan; the verified blocks from Task 5 Step 1 are the source of truth.)
```
