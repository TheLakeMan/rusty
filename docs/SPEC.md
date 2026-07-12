# The Rusty Language Specification

**Version:** 1.0.0 · **Status:** normative for the 1.x series
**Conformance:** an implementation (or a change to this one) conforms iff
`./run_tests.sh` passes — its golden files are the executable test
suite for everything this document states.

This is a precise *operational* description of the dialect as implemented
(`src/lexer.rs` → `parser.rs` → `eval.rs`/`interp.rs` → `env.rs`), not a
mechanized formal semantics. Where this document and the implementation
disagree, the implementation is currently authoritative and the
disagreement is a bug in this document.

---

## 1. Lexical structure

- **Numbers** — IEEE-754 `f64` is the only numeric type. Literals:
  `42`, `-7`, `3.14`, and scientific notation `1e-20`, `2.5E+3`
  (an `e`/`E` not followed by `[+-]?digits` starts a symbol instead).
  Integral values display without a decimal point (`(+ 1 2)` prints `3`).
- **Strings** — double-quoted, `\n` `\t` `\"` `\\` escapes.
- **Booleans** — `#t`, `#f`.
- **Symbols** — any token that isn't the above; `- + * / < > = ! ? .`
  and most punctuation are legal symbol characters (`list->tensor`,
  `agents-idle?`, `set!`).
- **Comments** — `;` to end of line.
- **Reader sugar** — desugared at parse time, there are no AST nodes for
  them: `'x` → `(quote x)`, `` `x `` → `(quasiquote x)`, `,x` →
  `(unquote x)`, `,@x` → `(unquote-splicing x)`.

## 2. Values

`Number` · `Bool` · `String` · `Symbol` · `List` · `Nil` (the void /
JSON-`null` value; prints `()`) · `Lambda` (closure) · `Macro` · `Builtin` ·
`Tool` (2.3 agent tool; first-class callable) · `Tensor` (flat row-major f64 +
shape) · `Native` (a `defrust`-compiled function) · `NativeGrad` (a fused
training kernel). Lists and tensors are reference-counted — copying a
value is O(1) and never deep.

`Nil` and an empty `List` are **distinct** values: both print `()` and both
satisfy `null?`, but `type-of` tells them apart (`nil` vs `list`) and they are
not `equal?`. `Nil` is what a conditional with no matching branch, `(begin)`,
and JSON `null` produce; an empty `List` comes from list operations (`(list)`,
`cdr` of a one-element list, an exhausted `filter`). Both are truthy (§3) — the
distinction is preserved so JSON `null` round-trips distinctly from `[]`.

`type-of` names these: `number boolean string symbol list nil lambda
macro builtin tool tensor native native-grad`.

## 3. Truthiness

**`#f` is the only false value.** Everything else — including `()`, `0`,
and `""` — is true. `(if '() 1 2)` ⇒ `1`.

## 4. Equality

- `=` `<` `>` `<=` `>=` are **numeric only**; comparing non-numbers is an
  error. Boolean-valued propositions must compare with `equal?`.
- `equal?`/`eq?` are structural over numbers, booleans, strings, symbols,
  nil, lists (recursively), and tensors (shape + elements). Code values
  (lambdas, tools, natives) are never `equal?` to anything.

## 5. Evaluation model

- **Environments** are a parent-linked chain of frames; a lambda captures
  the environment of its *definition* (lexical scope). `define` binds in
  the current frame; `set!` mutates the nearest enclosing binding and is
  an error if none exists; `set` binds-or-mutates.
- **Application** evaluates the operator, then arguments **left to
  right**, then applies. Callables: lambdas, builtins, tools, natives,
  grad kernels. `apply` accepts all of these.
- **Tail calls are eliminated** — to arbitrary depth, guaranteed, in:
  the last body expression of `lambda`/`define`/`let`/`let*`/`letrec`/
  named-`let`/`begin`/tool bodies; both branches of `if`; `cond`/`match`
  arm bodies; the last argument position of `and`/`or`; `when`/`unless`
  bodies; `(eval datum)`. Non-tail recursion is stack-bounded (Rust
  stack); deep list recursion in *cons position* is the classic way to
  blow it.
- **Errors** are strings raised by builtins/special forms or `(error s)`;
  `(try-catch body (e) handler)` catches, binding the message to `e`.

## 6. Special forms

Binding & control:
`define` (both `(define x v)` and `(define (f a . rest) body…)`), `def`,
`lambda` (dotted rest params), `set!`, `set`, `let`, `let*`, `letrec`,
`letrec*`, named `let` (loops), `do`, `if`, `cond` (`else` arm),
`when`, `unless`, `and`, `or` (short-circuit, return the deciding value),
`begin`, `match`, `try-catch`, `load`, `load-relative`. **`load`
evaluates the file at top level** (the global environment) regardless of
where the call sits — a `load` inside a function defines durable
bindings, like Scheme.

Data & code:
`quote`, `quasiquote`/`unquote`/`unquote-splicing`,
**`eval`** — `(eval datum)` runs a *data value* as code **in the current
environment**, tail-called; code values inside the datum do not convert.
Contrast the `eval-string` builtin, which deliberately evaluates text in
a **fresh** environment (isolation for untrusted/LLM text).

Macros:
`defmacro`/`define-macro` (dotted rest; **no bare-symbol variadic
parameter**), `eval-when` (§7), `gensym` (builtin).

Compilation:
`defrust`, `defrust*` (§9); `checkpoint` (§10).

Agents & LLM:
`deftool`, `tool-call`, `list-tools`, `react-loop`, `llm` (§10).

## 7. Macros and hygiene

A macro body is evaluated in an environment where the parameters are
bound to the **unevaluated** argument expressions; its result is
evaluated in the caller's environment (tail-called).

**Hygiene is applied at definition time**: identifiers that a macro's own
quasiquote template *binds* via `let`/`let*`/`letrec`/`lambda`/`do`/
named-`let` are rewritten to fresh gensyms, so template-internal names
cannot capture or be captured by call-site code. Identifiers arriving
through `,x`/`,@x` are untouched. Free references in a template are *not*
resolved in the macro's definition environment — only standard unhygienic
free-identifier behavior is provided there.

A top-level `(eval-when (phase…) body…)` inside a `defmacro` runs once at
**definition** time in the environment that becomes the macro's closure;
anywhere else `eval-when` behaves like `begin`.

## 8. Numerics

All arithmetic is `f64`. `/` and `mod` raise on a zero divisor (compiled
`defrust` code diverges here: no error channel, so `(mod x 0)` is NaN and
`(/ x 0)` is ±inf). `min`/`max` are variadic. Builtins: `+ - * / mod expt
abs sqrt floor ceiling round min max`. Filesystem builtins (`file-read`,
`file-write`, `file-append`, `file-delete`, `file-exists?`, `dir-create`,
`dir-list` — the last sorted for determinism) and `string-split` exist
since 0.26.0 and are classified effectful by `check-effects`
(`string-split` excepted — it's pure). NaN compares false with everything
including itself — `(= x x)` is the NaN test.

## 9. Compiled subsets

- **`defrust`** compiles numbers, params, `let`/`let*` locals, `+ - * /`,
  `sqrt expt abs mod floor ceiling round min max`, `if`/`cond` with
  comparison/`and`/`or`/`not` conditions, and self-recursion to native
  code via `rustc`. **`defrust*`** compiles a group into one shared
  library so members may call each other. Everything is `f64`; no lists,
  strings, closures, or global capture. ABI: every compiled function is
  `extern "C" fn(args: *const f64, len: usize) -> f64`, cached under
  `~/.rusty/jit-cache/` keyed by source + compiler flags.
- **Graph IR** (`graph-ir`, `graph-eval`, `graph-compile`,
  `graph-grad`, `graph-compile-grad`) accepts the same scalar subset plus
  the tensor ops `tensor-add/sub/mul/div`, `matmul`, `transpose`,
  `tensor-sum`, `relu`. `graph-compile` fuses a scalar graph to one
  native function; `graph-compile-grad` fuses a whole forward+backward
  training graph, shape-specialized to its example arguments (ABI
  `extern "C" fn(*const f64, *mut f64)`).

## 10. Standard capability layers

These are libraries (std.lisp / repo-root `.lisp` files), not core
semantics, but their contracts are stable:

- **Verification** (2.x): `check-exhaustive` (a property over the
  cartesian product of finite domains — verification means *ran
  everywhere*), `check-types`, `check-effects`, `verify-candidate`
  (static gates always run before anything executes), `define-typed`.
- **Actors** (3.2): `agent-spawn`/`send!`/`run-agents` — deterministic
  cooperative scheduling, single-threaded by design.
- **Persistence** (3.1/3.2): `save-model`/`load-model` (data only, JSON
  envelope), `checkpoint` (global env as loadable Lisp source; code
  values that can't serialize are listed, never silently dropped),
  `remember`/`recall`/`forget` (`~/.rusty/memory.lisp`).
- **Tracing** (3.2): `trace-on/off/clear/report/dropped`, `trace-event`;
  reports are pure data.
- **Synthesis & proof** (4.x): `symreg` (GP over expression data),
  `synth-fill`/`synth-with-proposer` (sketch CEGIS), `prover.lisp`
  (bounded proof assistant — "proved" always means checked on every
  point of stated finite domains), `robot.lisp` (deterministic control +
  inductive safety).
- **Knowledge graph** (1.3): `kg-add!`/`kg-clear!`/`kg-count`/`kg-triples`
  over a native, insertion-ordered, deduped triple store; `kg-query`
  solves a list of `(s p o)` patterns conjunctively, `?`-prefixed
  symbols are variables shared across patterns, results are lists of
  binding alists in insertion order. `kg-save-ntriples`/
  `kg-load-ntriples` bridge to W3C N-Triples (symbols ↔ `urn:rusty:`
  IRIs, strings ↔ literals, numbers ↔ `xsd:double`) — RDF is treated
  as an interchange *format*; there is no external database. Rules
  (`kg-rule!`/`kg-infer!`, kg.lisp) forward-chain to fixpoint and
  return the count of newly derived triples.
- **LLM** (`llm`, `react-loop`): local llama-server-compatible endpoint;
  `RUSTY_MODEL`/`RUSTY_LLM_URL`/`RUSTY_SYSTEM`/`RUSTY_LLM_TIMEOUT_SECS`
  environment variables. LLM output is text/data until it passes the
  verification gates — nothing model-produced runs unverified in the
  2.1/4.2 loops.

## 11. Stability & compatibility policy

As of **v1.0.0** the language contracts below are **frozen**. Rusty follows
semver within the 1.x line:

- **Patch** (`1.0.Y`): fixes; no observable language change.
- **Minor** (`1.X.0`): additive only — new builtins, special forms, library
  layers, or an *additional* compiled-function entry point (e.g. a richer ABI
  alongside the current one). Existing programs and artifacts keep working;
  golden files change only by addition.
- **Breaking changes** — to evaluation rules, truthiness, equality, the
  special-form list, the `defrust` C ABI, the checkpoint format, or the
  `save-model` envelope — require a **major** version bump (2.0.0), a
  migration note, and an update to this document in the same commit.

The **C ABI** (§9) is frozen as specified: one fixed signature per compilation
path (`f64`-only, no error channel), symbol names `rusty_` + sanitized
identifier. External callers may rely on it. A richer ABI — structured in/out,
or an error/status channel — ships as a *new, additional* entry point in a 1.x
minor, never by changing this one.

The golden files under `run_tests.sh` are the compatibility suite:
any change that alters their expected output is by definition observable
behavior and must be classified under the rules above before it ships.

## 12. Deliberate non-features

No integers/bignums/rationals (f64 only) · no continuations · no threads
(single-threaded `Rc` runtime; concurrency = deterministic actor
interleaving) · no unwind-protect · no source locations in errors (known
gap) · Python bridge sessions replay history rather than persist an
environment · zero external runtime dependencies, forever (see
ROADMAP.md's Design Constraint).
