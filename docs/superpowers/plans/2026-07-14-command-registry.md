# Command Registry, Discovery & Coverage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One env-derived command registry that powers discovery (help/apropos/describe + a REPL `/` prefix) and a truth-standing coverage ratchet (runtime call-tracking; every command must be executed by the suite or be on a reasoned allowlist).

**Architecture:** A `(command-registry)` *special form* walks the global env at runtime and returns `(name kind signature category)` rows — names from the env + a shared special-forms const, kind/signature from the `Value` variant, category from a thread-local table filled by ~20 `cat!` section markers (builtins) and a `categorize!` table (std.lisp). Discovery helpers live in `std.lisp` (always available via the embedded fallback). Coverage is recorded at the one eval dispatch choke point and enforced by a `run_tests.sh` pass.

**Tech Stack:** Rust (interpreter), Rusty Lisp (`std.lisp`), bash golden tests (`run_tests.sh` + `expected_*.txt`).

## Global Constraints

- **Zero external runtime dependencies** — Rust stdlib, existing Cargo crates (`rustc-hash`, etc.), or `rustc` only. No new crates without cause.
- **Golden-file testing only** — no `cargo test`. A test is a `.lisp` file whose stdout is diffed against a checked-in `expected_*.txt`. Never put timings in golden output.
- **Version bump per behavior change** — bump `version` in `Cargo.toml` (minor `0.X.0` for this feature) AND the `**Version:**` line in `README.md`; rebuild so `Cargo.lock` matches; all in the same commit.
- **Bit-identical existing goldens** — all 12 existing checks in `run_tests.sh` must still pass unchanged.
- **Zero cost when coverage is off** — coverage recording must not measurably slow `fib(30)` / `list_bench` with `RUSTY_COVERAGE` unset (verify per the optimization discipline).
- **Never push; commit locally only** unless the owner asks.
- **Symbol is ☯**, dedication exactly "In memory of my brother." (unchanged, do not touch).

---

### Task 1: Shared special-forms constant (refactor)

Move the special-forms name list out of `lsp_main.rs` so the LSP, the registry, and `(help)` read one source.

**Files:**
- Modify: `src/eval.rs` (add `pub const SPECIAL_FORMS`)
- Modify: `src/lsp_main.rs:39` (delete local `SPECIAL_FORMS`, import the shared one)

**Interfaces:**
- Produces: `pub const SPECIAL_FORMS: &[&str]` in `crate::eval`.

- [ ] **Step 1: Add the shared const in `src/eval.rs`** (top of the file, after the `use` lines):

```rust
/// Every special-form / built-in-syntax name the evaluator recognizes as a
/// call head. Single source of truth — the LSP, the command registry, and
/// (help) all read this. Keep in sync with the `match head.as_str()` arms in
/// `eval` (the coverage test will flag a special form missing from the registry).
pub const SPECIAL_FORMS: &[&str] = &[
    "define", "def", "lambda", "fn", "λ", "set!", "set", "let", "let*",
    "letrec", "letrec*", "do", "if", "cond", "when", "unless", "and", "or",
    "begin", "match", "try-catch", "load", "load-relative", "quote",
    "quasiquote", "unquote", "unquote-splicing", "eval", "eval-when",
    "defmacro", "define-macro", "defrust", "defrust*", "checkpoint", "deftool",
    "tool-call", "list-tools", "react-loop", "llm",
];
```

- [ ] **Step 2: Replace the local const in `src/lsp_main.rs`.** Delete the `const SPECIAL_FORMS: &[&str] = &[ ... ];` block at line 39. At the two use sites (currently `SPECIAL_FORMS.iter()` near line 191 and `SPECIAL_FORMS.contains` near line 208) change `SPECIAL_FORMS` to `crate::eval::SPECIAL_FORMS`. (If `lsp_main` is its own binary that doesn't compile `eval`, instead move the const to a small shared `src/commands.rs` declared in both `main.rs` and `lsp_main.rs`; check `src/lsp_main.rs` `mod`/`use` lines first and follow whichever the crate layout allows.)

- [ ] **Step 3: Build**

Run: `cargo build --release 2>&1 | tail -2`
Expected: `Finished` with no errors.

- [ ] **Step 4: Verify the LSP test still passes**

Run: `python3 lsp-test.py ./target/release/rusty-lsp` (or however `run_tests.sh` invokes it — grep `lsp-test` in `run_tests.sh` for the exact command)
Expected: same output as before (completion still lists special forms).

- [ ] **Step 5: Commit**

```bash
git add src/eval.rs src/lsp_main.rs
git commit -m "refactor: share SPECIAL_FORMS const between eval and lsp"
```

---

### Task 2: Category table, `cat!` markers, `categorize!` builtin, and `(command-registry)`

Build the registry itself: a thread-local name→category table filled during builtin setup and std.lisp load, plus the `(command-registry)` special form that assembles rows from the live env.

**Files:**
- Modify: `src/interp.rs` (category thread-local; `b!`/`alias!` record category; ~20 `cat!` markers; `categorize!` builtin)
- Modify: `src/eval.rs` (add the `"command-registry"` special-form arm)
- Test: `discover-test.lisp` + `expected_discover.txt` (new)
- Modify: `run_tests.sh` (register the new golden)

**Interfaces:**
- Consumes: `crate::eval::SPECIAL_FORMS` (Task 1).
- Produces:
  - `crate::interp::category_of(name: &str) -> Option<String>` — reads the thread-local table.
  - `crate::interp::set_category(name: &str, cat: &str)` — writes it.
  - Special form `(command-registry)` → `Value::List` of rows `(name kind signature category)`, each a 4-element list: `name` string, `kind` symbol (`builtin`/`function`/`macro`/`special-form`), `signature` string, `category` symbol.

- [ ] **Step 1: Add the category thread-local to `src/interp.rs`** (near the top, after the imports):

```rust
use std::cell::RefCell;
thread_local! {
    // name -> category, filled by cat!() during setup_builtins and by the
    // `categorize!` builtin from std.lisp. Static per thread; overwriting on a
    // fresh env setup is idempotent.
    static CATEGORIES: RefCell<rustc_hash::FxHashMap<String, String>> =
        RefCell::new(rustc_hash::FxHashMap::default());
}
pub fn set_category(name: &str, cat: &str) {
    CATEGORIES.with(|c| { c.borrow_mut().insert(name.to_string(), cat.to_string()); });
}
pub fn category_of(name: &str) -> Option<String> {
    CATEGORIES.with(|c| c.borrow().get(name).cloned())
}
```

- [ ] **Step 2: Thread a current-category through `setup_builtins`.** Inside `setup_builtins`, just after the `macro_rules! b { ... }` / `alias!` definitions (around `src/interp.rs:360`), add a mutable current-category and a `cat!` marker macro, and make `b!`/`alias!` record it. Replace the existing `b!` macro body so every registration also tags the category:

```rust
    let mut cur_cat: &'static str = "other";
    macro_rules! cat { ($c:expr) => { cur_cat = $c; }; }
    macro_rules! b {
        ($name:expr, $f:expr) => {{
            EnvFrame::set(env, $name.to_string(), Value::Builtin($name, $f));
            crate::interp::set_category($name, cur_cat);
        }};
    }
    macro_rules! alias {
        ($from:expr, $to:expr) => {{
            if let Some(v) = EnvFrame::get(env, $to) {
                EnvFrame::set(env, $from.to_string(), v);
                crate::interp::set_category($from, cur_cat);
            }
        }};
    }
```

Note: `cat!` must be a statement macro so `cur_cat = ...` mutates; because macros can't easily see outer `let mut`, if the borrow checker complains, instead declare `cur_cat` as a `std::cell::Cell<&'static str>` and have `cat!`/`b!` use `cur_cat.set(...)` / `cur_cat.get()`. Verify which compiles.

- [ ] **Step 3: Place ~20 `cat!` markers** at the existing section-comment boundaries in `setup_builtins`. One per section, immediately under each `// ── … ──` header. Use these category names (match the existing section headers):

```rust
    // ── Arithmetic ──
    cat!("arithmetic");
    // ...existing b!("+", ...) etc...

    // ── Comparison ──
    cat!("comparison");
    // ── Strings ──
    cat!("strings");
    // ── Lists ──
    cat!("lists");
    // ── Types ──
    cat!("types");
    // ── I/O ──
    cat!("io");
    // ── Tensors ──
    cat!("tensors");
    // ── Knowledge graph ──
    cat!("kg");
    // ── Agents/trace ──
    cat!("agents");
    // ...one cat!() under each section header that exists in the file...
```

(Read the current section headers in `setup_builtins` and add a `cat!` under each; the exact set is whatever sections exist. Anything before the first marker stays `"other"`.)

- [ ] **Step 4: Add the `categorize!` builtin** for std.lisp functions. In `setup_builtins`, under a new `cat!("meta");` section near `help`:

```rust
    cat!("meta");
    b!("categorize!", |args| {
        // (categorize! 'category '(name1 name2 ...)) — tag std.lisp functions.
        let cat = match args.first() {
            Some(Value::Symbol(s)) => s.clone(),
            _ => return Err("categorize!: first arg must be a category symbol".into()),
        };
        match args.get(1) {
            Some(Value::List(names)) => {
                for n in names.iter() {
                    if let Value::Symbol(s) = n { crate::interp::set_category(s, &cat); }
                }
                Ok(Value::Nil)
            }
            _ => Err("categorize!: second arg must be a list of name symbols".into()),
        }
    });
```

- [ ] **Step 5: Add the `(command-registry)` special form to `src/eval.rs`.** In the `match head.as_str()` block (near the other arms, e.g. after `"checkpoint"`), add:

```rust
                            "command-registry" => {
                                // Walk to the root (global) frame.
                                let mut root = env.clone();
                                loop {
                                    let next = root.borrow().parent.clone();
                                    match next { Some(p) => root = p, None => break }
                                }
                                let mut rows: Vec<Value> = Vec::new();
                                for (name, val) in root.borrow().vars.iter() {
                                    let (kind, sig) = match val {
                                        Value::Builtin(..) => ("builtin", String::new()),
                                        Value::Lambda { params, rest, .. } =>
                                            ("function", fmt_sig(name, params, rest)),
                                        Value::Macro { params, rest, .. } =>
                                            ("macro", fmt_sig(name, params, rest)),
                                        Value::Tool { params, .. } =>
                                            ("function", fmt_sig(name, params, &None)),
                                        Value::Native { .. } | Value::NativeGrad { .. } =>
                                            ("function", String::new()),
                                        _ => continue, // plain data bindings aren't commands
                                    };
                                    let cat = crate::interp::category_of(name)
                                        .unwrap_or_else(|| "other".to_string());
                                    rows.push(crate::env::list(vec![
                                        Value::String(name.clone()),
                                        Value::Symbol(kind.to_string()),
                                        Value::String(sig),
                                        Value::Symbol(cat),
                                    ]));
                                }
                                for sf in crate::eval::SPECIAL_FORMS {
                                    rows.push(crate::env::list(vec![
                                        Value::String((*sf).to_string()),
                                        Value::Symbol("special-form".to_string()),
                                        Value::String(String::new()),
                                        Value::Symbol("special-form".to_string()),
                                    ]));
                                }
                                return Ok(crate::env::list(rows));
                            }
```

- [ ] **Step 6: Add the `fmt_sig` free helper to `src/eval.rs`** (near the other free helpers, e.g. by `sym_name`):

```rust
/// Format a callable's signature string, e.g. "(map fn lst)" or
/// "(foo a b . rest)". Used by the command registry.
fn fmt_sig(name: &str, params: &[String], rest: &Option<String>) -> String {
    let mut s = String::from("(");
    s.push_str(name);
    for p in params { s.push(' '); s.push_str(p); }
    if let Some(r) = rest { s.push_str(" . "); s.push_str(r); }
    s.push(')');
    s
}
```

- [ ] **Step 7: Write the failing golden test `discover-test.lisp`:**

```lisp
;;; discover-test.lisp — golden test for the command registry + discovery.
;;; NO LLM, deterministic.
(define reg (command-registry))
(define (kind-of name)
  (let loop ((r reg))
    (cond ((null? r) 'not-found)
          ((string=? (car (car r)) name) (cadr (car r)))
          (else (loop (cdr r))))))
(println (list 'total-is-plausible (> (length reg) 250)))
(println (list 'map-kind (kind-of "map")))
(println (list 'plus-kind (kind-of "+")))
(println (list 'if-kind (kind-of "if")))
(println (list 'defmacro-kind (kind-of "defmacro")))
(println "discover-test: done")
```

- [ ] **Step 8: Run it to see current output and capture the golden.**

Run: `cargo build --release 2>&1 | tail -1 && ./target/release/rusty discover-test.lisp`
Expected (verify each line is *correct* before saving): `map` → `function`, `+` → `builtin`, `if` → `special-form`, `defmacro` → `special-form`, total plausible `#t`. Then:

```bash
./target/release/rusty discover-test.lisp > expected_discover.txt
```

- [ ] **Step 9: Register the golden in `run_tests.sh`** (add after the `kg-test.lisp` line):

```bash
run_test "discover-test.lisp" "expected_discover.txt" "discover-test.lisp (command registry)"
```

- [ ] **Step 10: Run the full suite; confirm 13 pass, all prior goldens unchanged.**

Run: `./run_tests.sh 2>&1 | tail -20`
Expected: `discover-test.lisp` ✅ and all previously-passing checks still ✅.

- [ ] **Step 11: Commit**

```bash
git add src/interp.rs src/eval.rs discover-test.lisp expected_discover.txt run_tests.sh
git commit -m "feat: command registry — (command-registry) over the live env"
```

---

### Task 3: Discovery API in std.lisp (help / apropos / describe)

Pure-Lisp helpers over `(command-registry)`, added to `std.lisp` (embedded → always available in the installed binary, unlike a separately-`load`ed file). Overhaul `(help)` to be registry-driven.

**Files:**
- Modify: `std.lisp` (add helpers; add the `categorize!` table for stdlib functions)
- Modify: `src/interp.rs:1619` (make the `help` *builtin* defer to the Lisp `help`, or remove it — see Step 4)
- Modify: `discover-test.lisp` + `expected_discover.txt` (extend)

**Interfaces:**
- Consumes: `(command-registry)` (Task 2).
- Produces Lisp fns: `(apropos "str")`, `(describe 'name)`, `(help)`, `(help 'category)`, `(commands)`.

- [ ] **Step 1: Add the discovery helpers near the end of `std.lisp`** (before the agent-tools load block):

```lisp
;; ── Command discovery (registry-driven; single source of truth) ─────────────
(define (commands) (map car (command-registry)))
(define (reg-row name)
  (let loop ((r (command-registry)))
    (cond ((null? r) #f)
          ((string=? (car (car r)) name) (car r))
          (else (loop (cdr r))))))
(define (describe name)
  (let ((row (reg-row (if (symbol? name) (symbol->string name) name))))
    (if (not row) (println (format "~a: unknown command" name))
        (begin
          (println (format "~a  [~a]  ~a" (car row) (nth row 1) (nth row 3)))
          (if (> (string-length (nth row 2)) 0)
              (println (format "  ~a" (nth row 2))) ())))
    ()))
(define (apropos pat)
  (for-each
    (lambda (row)
      (if (string-contains? (car row) pat)
          (println (format "  ~a  [~a]  ~a"
                           (car row) (nth row 1)
                           (if (> (string-length (nth row 2)) 0) (nth row 2) (nth row 3))))
          ()))
    (command-registry))
  ())
;; (help) with no arg: category names + counts. (help 'cat): that category.
(define (help . opt)
  (if (null? opt) (help-categories) (help-category (car opt))))
(define (help-category cat)
  (let ((c (if (symbol? cat) (symbol->string cat) cat)))
    (for-each
      (lambda (row)
        (if (string=? (symbol->string (nth row 3)) c)
            (println (format "  ~a  ~a" (car row)
                             (if (> (string-length (nth row 2)) 0) (nth row 2) "")))
            ()))
      (command-registry))
    ()))
```

- [ ] **Step 2: Add `help-categories`** (counts per category — needs a small tally; keep it deterministic by sorting):

```lisp
(define (help-categories)
  (println (format "Rusty — ~a commands. (help 'category) drills in; (apropos \"x\") searches; (describe 'name)." (length (command-registry))))
  (let ((cats (uniq-sorted (map (lambda (r) (symbol->string (nth r 3))) (command-registry)))))
    (for-each
      (lambda (c)
        (println (format "  ~a (~a)" c
                         (length (filter (lambda (r) (string=? (symbol->string (nth r 3)) c))
                                         (command-registry))))))
      cats)
    ()))
;; uniq-sorted: dedup + string-sort a list of strings (deterministic output).
(define (uniq-sorted lst)
  (let ((s (sort-strings lst)))
    (let loop ((in s) (out '()))
      (cond ((null? in) (reverse out))
            ((and (pair? out) (string=? (car in) (car out))) (loop (cdr in) out))
            (else (loop (cdr in) (cons (car in) out)))))))
```

If `std.lisp` has no string sort, add `sort-strings` using the existing sort or a simple insertion sort over `string<?` (check `std.lisp` for an existing `sort`/`string<?`; reuse it — DRY. If none exists, add a minimal insertion sort here).

- [ ] **Step 3: Add the stdlib `categorize!` table near the discovery helpers**, grouping the ~94 std.lisp function names. Read the current `(define (...))` names in `std.lisp` and bucket them:

```lisp
(categorize! 'lists '(take drop range zip foldr for-each last flatten ...))
(categorize! 'strings '(str-trim string-join string-split ...))
(categorize! 'control '(when unless assert ...))
(categorize! 'agents '(agent-spawn send! run-agents ...))
;; ...cover every std.lisp define; anything left lands in 'other and the
;; coverage/registry test will show a large 'other count to chip away at.
```

(This is the ~10-line grouping table from the spec — bucket names, do not write prose.)

- [ ] **Step 4: Replace the static `help` builtin.** In `src/interp.rs:1619`, the `b!("help", ...)` prints a static list that `std.lisp`'s `(define (help ...))` will now shadow (std.lisp loads after builtins). Confirm shadowing works (define overrides the builtin binding). If it does, delete the `b!("help", ...)` block entirely (dead once shadowed) to avoid confusion. If load-order means the builtin wins, keep only a one-line builtin that says "loading…" — but verify: std.lisp `define` at top level should overwrite the global `help`. Test in the REPL: `(help)` should show categories, not the old static text.

- [ ] **Step 5: Extend `discover-test.lisp`** with deterministic discovery checks:

```lisp
(println "-- apropos map --")
(apropos "map")
(println "-- describe --")
(describe 'foldl)
(describe '+)
(println "-- help categories --")
(help-categories)
```

- [ ] **Step 6: Regenerate the golden and verify correctness by eye first.**

Run: `cargo build --release 2>&1 | tail -1 && ./target/release/rusty discover-test.lisp`
Inspect: apropos lists `map`, `flat-map`, etc.; `describe foldl` shows `[function] (foldl f acc lst)` (or its real params); category counts are sane. Then:

```bash
./target/release/rusty discover-test.lisp > expected_discover.txt
```

- [ ] **Step 7: Full suite green.**

Run: `./run_tests.sh 2>&1 | tail -20`
Expected: all ✅, `discover-test.lisp` included.

- [ ] **Step 8: Commit**

```bash
git add std.lisp src/interp.rs discover-test.lisp expected_discover.txt
git commit -m "feat: registry-driven help/apropos/describe in std.lisp"
```

---

### Task 4: Coverage recording (trace.rs + eval choke point + exit dump)

Record every command actually invoked, off by default, and dump the set on exit when `RUSTY_COVERAGE` is set.

**Files:**
- Modify: `src/trace.rs` (coverage thread-local + API)
- Modify: `src/eval.rs:158` (record the call-head symbol)
- Modify: `src/main.rs` (enable from env at startup; dump on exit)

**Interfaces:**
- Produces in `crate::trace`:
  - `pub fn coverage_set_enabled(on: bool)`
  - `pub fn coverage_enabled() -> bool`
  - `pub fn cover(name: &str)` — inserts if enabled
  - `pub fn coverage_names() -> Vec<String>` — snapshot

- [ ] **Step 1: Add the coverage machinery to `src/trace.rs`** (mirror the existing `ENABLED`/`record` pattern near line 36):

```rust
use std::collections::HashSet;
thread_local! {
    static COV_ON:    Cell<bool> = Cell::new(false);
    static COVERED:   RefCell<HashSet<String>> = RefCell::new(HashSet::new());
}
pub fn coverage_set_enabled(on: bool) { COV_ON.with(|c| c.set(on)); }
pub fn coverage_enabled() -> bool { COV_ON.with(|c| c.get()) }
pub fn cover(name: &str) {
    if !coverage_enabled() { return; }
    COVERED.with(|c| { c.borrow_mut().insert(name.to_string()); });
}
pub fn coverage_names() -> Vec<String> {
    COVERED.with(|c| c.borrow().iter().cloned().collect())
}
```

- [ ] **Step 2: Record at the eval choke point.** In `src/eval.rs`, immediately after `if let Expr::Symbol(head) = &lst[0] {` (line 158), before the `match head.as_str()`:

```rust
                    if let Expr::Symbol(head) = &lst[0] {
                        if crate::trace::coverage_enabled() { crate::trace::cover(head); }
                        match head.as_str() {
```

- [ ] **Step 3: Wire enable + exit-dump in `src/main.rs`.** Near startup (after arg parsing, before running the script):

```rust
    if std::env::var("RUSTY_COVERAGE").is_ok() {
        rusty::trace::coverage_set_enabled(true);
    }
```

After the script finishes running (end of the file-run path, before exit):

```rust
    if let Ok(path) = std::env::var("RUSTY_COVERAGE_FILE") {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            for n in rusty::trace::coverage_names() { let _ = writeln!(f, "{}", n); }
        }
    }
```

(Adjust the crate path — `rusty::trace` vs `crate::trace` — to match how `main.rs` refers to the lib; grep an existing `trace::` call in `main.rs`.)

- [ ] **Step 4: Verify recording works.**

```bash
cargo build --release 2>&1 | tail -1
COV=$(mktemp)
RUSTY_COVERAGE=1 RUSTY_COVERAGE_FILE="$COV" ./target/release/rusty -e '(map (lambda (x) (+ x 1)) (list 1 2 3))' 2>/dev/null || \
RUSTY_COVERAGE=1 RUSTY_COVERAGE_FILE="$COV" ./target/release/rusty discover-test.lisp >/dev/null
grep -qx 'map' "$COV" && grep -qx '+' "$COV" && echo "COVERAGE RECORDS OK"
rm -f "$COV"
```
Expected: `COVERAGE RECORDS OK`.

- [ ] **Step 5: Verify ZERO measurable cost when off** (constraint). Write `/tmp/fib.lisp` = `(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (print (fib 30))`.

```bash
for i in 1 2 3; do ( time ./target/release/rusty /tmp/fib.lisp ) 2>&1 | grep real; done
```
Compare against the pre-change binary (or the committed baseline). Expected: within noise (±2%). If there's a real regression, hoist the `coverage_enabled()` check so the common path is a single predictable branch; re-measure. Record the numbers in the commit message.

- [ ] **Step 6: Confirm existing goldens unchanged** (coverage is off by default, so output must be identical).

Run: `./run_tests.sh 2>&1 | tail -5`
Expected: all ✅.

- [ ] **Step 7: Commit**

```bash
git add src/trace.rs src/eval.rs src/main.rs
git commit -m "feat: off-by-default coverage recording at the eval call site"
```

---

### Task 5: The coverage ratchet (allowlist + check + run_tests.sh)

Enforce: every registry command is either exercised by the suite or on a reasoned allowlist — else the suite fails. Plus stale-allowlist detection.

**Files:**
- Create: `coverage-allowlist.lisp` (reasoned exemptions)
- Create: `coverage-check.lisp` (the checker)
- Create: `expected_coverage.txt` (golden = `COVERAGE OK`)
- Modify: `run_tests.sh` (coverage pass)

**Interfaces:**
- Consumes: `(command-registry)`, `$RUSTY_COVERAGE_FILE` (Task 4), `coverage-allowlist.lisp`.

- [ ] **Step 1: Create `coverage-allowlist.lisp`** — commands intentionally not golden-exercised, each with a reason comment. Start minimal; fill in after Step 5 shows the real uncovered set:

```lisp
;;; coverage-allowlist.lisp — commands intentionally NOT exercised by the
;;; golden suite. Each needs a reason. "We stand for truth": keep this minimal
;;; and honest; the check FAILS if an entry here is actually exercised (stale).
(define *coverage-allow* '(
  llm            ; needs a live model
  react-loop     ; LLM agent loop
  agent          ; LLM agent loop
  shell          ; side effects on the host
  checkpoint     ; writes a file snapshot; exercised elsewhere manually
  now-micros     ; wall clock (nondeterministic — kept out of goldens)
  ;; ...extend from the Step 5 report, each with a reason...
))
```

- [ ] **Step 2: Create `coverage-check.lisp`:**

```lisp
;;; coverage-check.lisp — the ratchet. Reads the accumulated exercised-names
;;; file ($RUSTY_COVERAGE_FILE), the registry, and the allowlist; prints
;;; "COVERAGE OK" or the violations. Deterministic (sorted) output.
(load "coverage-allowlist.lisp")
(define exercised
  (string-split (file-read (getenv "RUSTY_COVERAGE_FILE")) "\n"))
(define (exercised? name) (member name exercised))
(define (allowed? sym) (member sym *coverage-allow*))
(define all-names (map car (command-registry)))
;; uncovered commands not on the allowlist = FAILURE (new untested command)
(define offenders
  (filter (lambda (n) (and (not (exercised? n)) (not (allowed? (string->symbol n)))))
          all-names))
;; allowlisted commands that WERE exercised = stale exemption
(define stale
  (filter (lambda (s) (exercised? (symbol->string s))) *coverage-allow*))
(cond ((and (null? offenders) (null? stale)) (println "COVERAGE OK"))
      (else
        (if (not (null? offenders))
            (println (format "UNTESTED (add a test or allowlist w/ reason): ~a"
                             (sort-strings offenders))) ())
        (if (not (null? stale))
            (println (format "STALE ALLOWLIST (now exercised, remove): ~a" stale)) ())))
```

(`getenv`/`file-read`/`string-split` exist since 0.26.0 — confirm `getenv` name in `interp.rs`; if it's `env-var` or similar, use that.)

- [ ] **Step 3: Add the coverage pass to `run_tests.sh`** (after the last `run_test`, before the results tally):

```bash
# ── Coverage ratchet ────────────────────────────────────────────────────────
COVFILE="$(mktemp)"
export RUSTY_COVERAGE_FILE="$COVFILE"
for f in tests.lisp new-features.lisp hello.lisp swarm.lisp symreg-test.lisp \
         synth-test.lisp prover-test.lisp robot-test.lisp pkg-test.lisp \
         testkit-test.lisp kg-test.lisp discover-test.lisp; do
    RUSTY_COVERAGE=1 "$RUSTY" "$f" >/dev/null 2>&1
done
# check runs WITHOUT RUSTY_COVERAGE so it doesn't record itself
run_test "coverage-check.lisp" "expected_coverage.txt" "coverage-check.lisp (ratchet)"
unset RUSTY_COVERAGE_FILE
rm -f "$COVFILE"
```

- [ ] **Step 4: Generate the exercised set once and inspect the real uncovered list.**

```bash
cargo build --release 2>&1 | tail -1
COVFILE="$(mktemp)"; export RUSTY_COVERAGE_FILE="$COVFILE"
for f in tests.lisp new-features.lisp hello.lisp swarm.lisp symreg-test.lisp synth-test.lisp prover-test.lisp robot-test.lisp pkg-test.lisp testkit-test.lisp kg-test.lisp discover-test.lisp; do
  RUSTY_COVERAGE=1 ./target/release/rusty "$f" >/dev/null 2>&1
done
./target/release/rusty coverage-check.lisp
```
Inspect the `UNTESTED` list. For each: decide honestly — add it to an existing golden test (preferred) or to `coverage-allowlist.lisp` **with a reason**. Iterate until the checker prints exactly `COVERAGE OK`.

- [ ] **Step 5: Save the golden.**

```bash
echo "COVERAGE OK" > expected_coverage.txt
rm -f "$COVFILE"; unset RUSTY_COVERAGE_FILE
```

- [ ] **Step 6: Run the whole suite; confirm the ratchet passes.**

Run: `./run_tests.sh 2>&1 | tail -20`
Expected: all ✅ including `coverage-check.lisp (ratchet)`.

- [ ] **Step 7: Prove the ratchet bites** (sanity): temporarily add a throwaway builtin with no test, rebuild, run the suite, confirm `coverage-check.lisp` ❌ with the new name in `UNTESTED`, then revert. (Do not commit the throwaway.)

- [ ] **Step 8: Commit**

```bash
git add coverage-allowlist.lisp coverage-check.lisp expected_coverage.txt run_tests.sh
git commit -m "feat: truth-standing coverage ratchet — untested commands fail the suite"
```

---

### Task 6: REPL `/` prefix sugar + version bump + docs

The interactive affordance, plus the release chores.

**Files:**
- Modify: `src/main.rs` (REPL input handling)
- Modify: `Cargo.toml`, `README.md`, `Cargo.lock` (version)
- Modify: `docs/ARCHITECTURE.md` (one line) and CLAUDE.md if warranted

**Interfaces:**
- Consumes: `(apropos ...)` (Task 3).

- [ ] **Step 1: Find the REPL read-eval-print loop in `src/main.rs`** (grep for the prompt string / `readline` / the loop that reads a line and calls `eval`). At the point where a line has been read and trimmed, before it's parsed as Lisp:

```rust
    // `/foo` in the REPL is sugar for (apropos "foo").
    let trimmed = line.trim_start();
    if let Some(q) = trimmed.strip_prefix('/') {
        let expr = format!("(apropos \"{}\")", q.trim().replace('"', ""));
        // feed `expr` through the same eval path the loop uses for a normal line
        // (call whatever function the loop already uses; do not duplicate it)
        run_line(&expr);   // <- use the loop's existing eval-a-line function
        continue;
    }
```

(Match the loop's actual structure — reuse its existing "evaluate this string" path; the snippet shows intent, wire it to the real function.)

- [ ] **Step 2: Manually verify in the REPL.**

```bash
printf '/map\n(quit)\n' | ./target/release/rusty
```
Expected: the apropos listing for `map` prints, then exit. (Adapt the quit form to whatever the REPL uses.)

- [ ] **Step 3: Bump the version.** Set `version = "0.40.0"` in `Cargo.toml` and update the `**Version:** 0.39.0` line in `README.md` to `0.40.0`. Rebuild so `Cargo.lock` updates:

Run: `cargo build --release 2>&1 | tail -1 && grep -A1 '^name = "rusty"' Cargo.lock | head -2`
Expected: `version = "0.40.0"`.

- [ ] **Step 4: One-line docs.** Add a short bullet to `docs/ARCHITECTURE.md` (and the interp.rs section list in CLAUDE.md if that's where such things live) noting: `(command-registry)` special form + std.lisp discovery + the coverage ratchet (`run_tests.sh` coverage pass, `coverage-allowlist.lisp`).

- [ ] **Step 5: Final full suite + refresh installed binary.**

Run: `./run_tests.sh 2>&1 | tail -20`
Expected: all ✅. Then: `cargo install --path . --bin rusty --root ~/.local`

- [ ] **Step 6: Commit**

```bash
git add src/main.rs Cargo.toml Cargo.lock README.md docs/ARCHITECTURE.md CLAUDE.md
git commit -m "feat: REPL / apropos sugar; command registry & coverage ratchet (v0.40.0)"
```

---

## Self-review notes

- **Spec coverage:** C1 registry → Tasks 1–2. C2 discovery → Task 3. C3 `/` sugar → Task 6. C4 coverage (runtime tracking + hard ratchet + stale detection) → Tasks 4–5. Completeness golden (`discover-test.lisp`) → Task 2/3. Reasoned allowlist → Task 5. All spec sections mapped.
- **Load-order risk (Task 3 Step 4):** whether std.lisp's `(define (help …))` shadows the `help` builtin is verified live, not assumed; fallback stated.
- **Env access (Task 2):** resolved — `(command-registry)` is a special form walking `env.parent` to root, not a `fn(&[Value])` builtin.
- **Higher-order coverage gap:** commands used only as *arguments* (e.g. only ever `(apply + xs)`, never `(+ …)`) won't be recorded by head-site tracking → they surface in the `UNTESTED` list and get a direct test or a reasoned allowlist entry. Honest by construction; noted for the implementer at Task 5 Step 4.
- **Zero-cost-off:** explicitly measured in Task 4 Step 5 against the fib baseline.
