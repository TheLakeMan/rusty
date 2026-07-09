# Rusty 5-Year Roadmap

## Vision

**Rusty as the symbolic transformation layer for AI/ML infrastructure.**

Make Rusty the language people reach for when they need **computation that reasons about computation** — LLM as creative planner, Rusty as reliable executor with memory, symbolic reasoning, and verifiable correctness.

### North Star

In 5 years, Rusty will be:
- **Deeply embedded in AI/ML infrastructure** where symbolic computation bridges abstract mathematical logic and high-performance numerical execution
- **The canonical tool** for building neuro-symbolic systems that combine neural networks with logic-driven reasoning
- **Proven in production** across 2-3 high-impact domains (formal verification, robotics control, or scientific computing)

### Design Constraint: No External Runtime Dependencies

Rusty is a DSL, not a research platform accumulating a dependency graph. Every capability — code generation, verification, tensor/ML support — gets built **inside Rusty itself**, using only what it already ships with (the Rust toolchain at build time; no external services, toolchains, or heavyweight runtime dependencies). This is why `defrust` shells out to `rustc` — a build tool already required to build Rusty itself — rather than depending on Lean 4, TLA+, or a Python/PyTorch runtime at execution time: the constraint is what makes Rusty embeddable — on a robot, on constrained hardware, anywhere — without dragging in someone else's toolchain. Where a phase below reads like "integrate with X," read it as "build a self-contained equivalent of whatever X gives you, at whatever scope is honestly achievable without X" — external systems are fine as a *benchmark comparison* (Phase 1's PyTorch performance target) but not as a *dependency*.

---

## Phase 1: Symbolic Transformation Layer (Months 0–12)

**Goal:** Establish Rusty as a kernel for writing DSLs that compile to optimized computation graphs.

### 1.1 Macro System Enhancements
- [x] **Hygienic macro improvements**: `defmacro` templates auto-rename let/let*/letrec/lambda/do bindings they introduce to fresh gensyms, so macro-internal names can't capture or be captured by call-site identifiers (see `hygienic_rename` in `src/eval.rs`). Free-identifier capture in the reverse direction (use-site shadowing a macro's free reference) is not addressed.
- [x] **Compile-time evaluation**: `(eval-when (phase...) body...)` is a general special form (runs `body` immediately, like `begin` — Rusty has no separate compile/load phase so `phase` is accepted but unused outside macros). Inside a `defmacro` body specifically, a top-level `eval-when` runs once at *definition* time (not once per expansion), in the env that becomes the macro's closure — see `src/eval.rs`'s `defmacro` handler. A separate `const` special form was not added: `std.lisp` already defines `const` as the K-combinator (`(define (const x) (lambda args x))`, used in functional pipelines), so introducing a `const` keyword would have shadowed it.
- [x] **Symbol tables & gensym pool**: `gensym` and the hygiene pass now share one counter (`env::gensym_name`) for globally-unique names
- [x] **Macro profiler**: `(macro-profile-on)`/`(macro-profile-off)` toggle instrumentation around macro expansion (off by default, zero overhead when unused — see `eval::macro_profile` in `src/eval.rs`); `(macro-profile-report)` returns `(name call-count total-microseconds)` rows sorted by total time descending, `(show-macro-profile)` (std.lisp) pretty-prints them. Counts every expansion, including macros expanding into other macros (e.g. `repeat` expanding into `dotimes`), each attributed separately.
- **Deliverable:** Example DSL that generates optimized list operations (equivalent to JAX list comprehensions)

### 1.2 Code Generation & Symbolic Computation
- [x] **S-expression to Rust codegen**: `(defrust name (params...) body)` (`src/rust_jit.rs`) compiles a restricted numeric subset (numbers, params, `+ - * /`, `if` with comparisons/and/or/not, self-recursive calls) to real Rust, via `rustc --crate-type cdylib -O` shelled out as a subprocess, cached by a hash of the generated source, and dynamically loaded with `libloading`. Calling a `defrust` function marshals Lisp numbers across a fixed `extern "C" fn(*const f64, usize) -> f64` ABI. Measured: tree-walked `fib(30)` ~8.2s vs. the `defrust` version ~0.007s once compiled (~0.067s including the one-time compile) — real, not simulated, speedup. **Cut from v1** (deliberately, not an oversight): calls between *separate* `defrust` functions — that needs cross-`.so` linking, which is its own can of worms — so only self-recursion is supported, not composition.
- [x] **Symbolic differentiation**: `(grad (lambda (x) expr))` (`grad` builtin → `eval::symbolic_derivative`) differentiates `expr` via AST rewriting (sum/product/quotient/power/chain rules for `+ - * / expt sqrt`, plus `if`) with respect to the lambda's first parameter, returning a new callable Lambda — true symbolic differentiation, not numeric approximation or execution tracing. Verified against hand-computed derivatives for polynomial, reciprocal, sqrt, product-rule, quotient-rule, and conditional (abs-like) cases.
- [x] **Graph IR**: `src/graph_ir.rs` — a DAG (`Graph`/`Node`/`Op`) over the same restricted numeric subset as `defrust` (numbers, params, `+ - * /`, comparisons, `if`), built via hash-consing. Exposed to Lisp as `(graph-ir fn)` (inspect the optimized graph as data), `(graph-node-count fn)`, and `(graph-eval fn args...)` (execute the IR directly via a small tree-walking interpreter over the DAG — no codegen backend yet; wiring this into `rust_jit`'s codegen is separate future work).
- [x] **Graph optimization passes**: common-subexpression elimination falls out of the IR's hash-consing itself (structurally identical subexpressions collapse to one node during construction, not a separate pass — verified: `(+ (* x x) (* x x))` builds 3 nodes, not 5). Constant folding is a separate pass, including pruning an `if` branch whose condition is constant (verified: `(+ (* 2 3) x)` folds to 3 nodes; `(if (< 1 2) x (/ x 0))` prunes to 1 node, so the broken else-branch is never reachable, let alone evaluated). Dead-code elimination is mark-and-sweep from the output, cleaning up whatever folding/pruning orphaned.
- **Deliverable:** Benchmark showing rusty-generated code matches or exceeds PyTorch performance on a simple neural layer — the `defrust` fib benchmark is a first data point; a neural-layer-scale benchmark still needs Graph IR wired into codegen (not yet done — today Graph IR only has its own tree-walking `graph-eval` interpreter, not a compiled backend).

### 1.3 Neuro-Symbolic Bridge Layer (Library)
- [x] **Constraint embedding**: `(defun-constrained (name params...) (assert cond [msg])... body...)` (std.lisp) — like `define`, but leading `(assert ...)` forms are checked against the function's own arguments on every call before `body` runs, so a violated invariant fails loudly instead of silently computing a wrong result (verified: `(safe-sqrt -4)` raises `"Assertion failed: (>= x 0)"` instead of returning `NaN`). `assert` itself became a macro (was a 2-arg function) so it can capture the literal condition text for a default message when none is given — nothing else in the repo called bare `assert` (only the unrelated `assert-equal`/`assert-true` test helpers), so this was safe to change.
- [x] **Logic-driven loss functions**: `(implies p q)` and `(logic-loss formula)` (std.lisp, both trivial macros — `implies` ≡ `(or (not p) q)`, `logic-loss` is `0` if `formula` holds else `1`). This is **crisp propositional logic**, not fuzzy/differentiable logic — gradients don't flow through it. A soft-relaxed version usable in an actual gradient-based training loop is future work; today there's no training loop for it to plug into anyway.
- [ ] **Knowledge graph bindings**: Integration with external symbolic knowledge bases (RDF, property graphs) — **not started**, deliberately: this needs picking a real external system/format (RDF via which crate? a specific property-graph DB?) and probably a new network-facing dependency, which is a call for the project owner, not an autonomous one.
- **Deliverable:** Example system (e.g., a classification model that respects logical invariants) — not built; there's no classifier/training loop in Rusty yet for `logic-loss` to attach to.

---

## Phase 2: Verifiable AI Systems (Months 12–24)

**Goal:** Make Rusty the language for provably correct AI.

### 2.1 Self-Contained Verification
No external theorem prover, no external model checker. "Provably correct" here means Rusty's own contract/analysis system — `defun-constrained`/`logic-loss` (1.3) and `define-typed`/`check-types`/`check-effects` (2.2) already *are* that system — extended to cover more ground, plus reusing the LLM-agent loop Rusty already has (`llm`/`react-loop`, Phase 1) as a proposal mechanism with Rusty's own checkers as the verifier. Never a cloud API, never someone else's toolchain — this replaces the earlier "Lean 4 / TLA+" framing entirely, not just the implementation of it.
- [x] **Proof-by-checker loop**: `(synthesize-verified spec proposer max-attempts)` + `(verify-candidate f spec)` (std.lisp) — a proposer suggests candidate functions and only one passing every gate is accepted; per-attempt failure reasons are accumulated and fed back to the proposer. The spec is an alist of gates: `pure` (must pass `check-effects`), `types` (must pass `check-types`), `domains`+`invariant` (must pass `check-exhaustive`). **Static gates run first and never execute the candidate** — verified with a booby-trapped impure candidate that prints if it ever runs: it was rejected with zero output leaked. The loop is proposer-agnostic (tested end-to-end with a scripted proposer: impure candidate rejected → wrong candidate rejected with exact counterexamples → correct candidate accepted and returned as a working callable); `llm-proposer` (std.lisp, backed by the `llm` builtin + new `eval-string` builtin) plugs an LLM in as the proposer with verification feedback threaded into each retry prompt — **live-verified** against a local llama-server: `(synthesize-verified spec (llm-proposer "double a number") 3)` → `(verified #<lambda (x)>)`, i.e. a local model proposed the implementation and Rusty's own checkers proved it before handing it back. The "prover" is Rusty's own checkers, not an SMT solver or Lean, per the design constraint.
- [x] **Bounded exhaustive checking**: `(check-exhaustive property '((domain1...) (domain2...)...))` (builtin, `src/interp.rs`) runs `property` on *every* combination of the given finite domains and returns `'verified`, or a list of counterexamples — each `((args...) reason)` where reason is `"false"` or the raised error's message. Exhaustive proof over a finite state space, not sampling. Capped at 1,000,000 combinations (clear error, not a hang). Verified: a true property over 25 combos → `verified`; a false one reports its exact failing inputs; a runtime error (division by zero) is captured and attributed to its input; and the motivating case — a robot mode-machine's transition function exhaustively proven to only land in valid modes. Still the deliberate TLA+-scope tradeoff: finite/discrete domains only, dependency-free. (Also fixed en route: std.lisp's `range` was non-tail-recursive and blew the stack past ~200 elements; now accumulator-based so TCO applies. List-building via `cons` remains O(n²) — a separate, pre-existing interpreter-wide cost documented in ARCHITECTURE.md.)
- [x] **Cross-checker registry**: `define-typed`'s expansion now also calls `register-signature` (new builtin → `type_check::register_signature`, a thread-local name → (param types, return type) map), and `check-types` consults it when it hits a call it doesn't otherwise recognize — so static and runtime checking share one source of truth. Verified: a call to a `define-typed` function with a wrongly-typed arg is flagged statically; the declared *return* type flows onward (`(string-length (f x))` flagged when `f` is declared `: number`); unannotated positions register as `unknown` and are never flagged; plain `define`d functions behave exactly as before.
- **Deliverable:** A function whose safety was previously "trust the tests" gets a Rusty-native proof of a stated invariant, using only what Rusty already ships with. **Done** — the robot mode-machine transition function (see `check-exhaustive` above) is exhaustively proven to stay within valid modes, and `synthesize-verified` produces functions that arrive pre-verified against their spec. Section 2.1 complete.

### 2.2 Static Analysis & Type System
Everything here was already built self-contained, before "no external runtime dependencies" was written down explicitly above — it's the working example the constraint in the Vision section is describing, not a retrofit.
- [x] **Gradual typing**: `(define-typed (name (p1 : t1) (p2 : t2) untyped-p3 ...) : return-type body...)` (std.lisp, `define`/`lambda` themselves untouched — opt-in). `ti`/`return-type` name an existing `<type>?` predicate; checked as **runtime contracts at call time** (not static analysis — see the two items below, which are the actual static half of this section and remain undone). Verified: correct calls pass through untyped, a wrong param type and a wrong return type both raise a clear "expected X, got a different type" instead of silently miscomputing. Hit and fixed a real bug along the way: the macro's own `__result` temp crossed an `unquote` boundary in a way the hygiene pass (1.1) couldn't see through, so it renamed the binding but not a reference generated by a helper function — fixed the same way `swap!`/`repeat` already do, with `(gensym "result")` computed once and spliced everywhere via unquote instead of a literal template binding.
- [x] **Flow-sensitive analysis**: `(check-types (lambda (params...) expr) '((param type)...))` (`src/type_check.rs`) — a static checker that walks the body *without executing it*, tracking each variable's known type through `if`/`let`/`let*`: narrows on a recognized `<type>?` predicate test in an `if` condition (in the then-branch), propagates through `let`/`let*` init expressions, and reports any operation it can *prove* runs on the wrong type. Deliberately conservative — an undeterminable type is `Unknown` and is never flagged, so it only reports provable mismatches, never guesses. Verified: flags `(string-length x)` when `x` is declared `number`; does *not* flag the same call inside a `(let ((y (+ x 1))) ...)` when it's actually `string-length` on `y` that's wrong (propagation); and — the key flow-sensitive proof — narrowing from `(if (number? x) (+ x 1) ...)` *overrides* an outer declared type of `string` for `x` within that branch, so no false positive there. v1 cuts (each an extension point): only `if`/`let`/`let*` understood, no union types, and user-defined function calls always return `Unknown` — *the last of these was closed by 2.1's cross-checker registry; `define-typed` functions now check statically.*
- [x] **Effect tracking**: `(check-effects (lambda (params...) body...))` (`src/effect_check.rs`) walks every body statement *without executing them* and reports each operation it can prove is effectful, from a fixed classification (`set!`/`set` mutate; `print`/`println`/`display`/`newline` do I/O; `shell`/`shell-run` run commands; file ops touch the filesystem; `llm`/`tool-call`/`react-loop` call external services; `remember`/`recall`/`forget`/`memory-list` touch persistent memory; `gensym` is non-deterministic; `load`/`load-relative` execute another file) or `'pure` if none are found. Same conservative philosophy as `check-types` — an unrecognized/user-defined call is never flagged, since purity can't be proven either way for it without whole-program analysis. `(effectful? 'name)` exposes the same classification as a simple query. Correctly distinguishes `quote`d data (inert, never flagged even if it looks like `(set! ...)`) from `quasiquote`'s `unquote`/`unquote-splicing` parts (which *are* evaluated and are checked) — verified for both.
- **Deliverable:** Type checker that catches common agent errors (e.g., passing wrong arg types to tools) — satisfied by `define-typed` (runtime) and `check-types` (static) above.

### 2.3 Tool Registry with Specifications
- [x] **Tool specifications**: `(deftool-spec tool '((param type)...) '(allowed-effect-ops...) precondition deps)` (std.lisp, `*tool-specs*` registry) — declares param types, the effect *operations* the tool is allowed to perform (op names as `check-effects` knows them), an optional precondition lambda over the args, and dependencies on other tools. Enabled by making tools first-class callables (Rust: `Value::Tool` added to the eval call dispatch and `apply_value`, same shape as `Lambda`; new `tool-name` builtin; `check-effects` accepts tools).
- [x] **Contract enforcement**: `(safe-call tool args...)` checks arity, arg types, and precondition *before* the tool body runs — a violated contract raises instead of letting a system-touching tool fire on bad inputs (verified: wrong type, wrong arity, and failed precondition each refuse cleanly; valid calls pass through). Plus static *effect honesty*: `undeclared-effects` cross-checks a tool's declared effects against what `check-effects` actually finds in its body, without executing it.
- [x] **Tool dependency graphs**: specs carry deps; `(certify-tool-chain (list tool...))` walks an intended execution order and requires every tool's declared deps to appear earlier in the chain.
- **Deliverable:** Safety certification for agent tool chains — **done**: `certify-tool-chain` returns `'certified` only when every tool in the chain has a spec, is honest about its effects, and respects dependency order; verified flagging each failure mode individually (missing spec, `print`-ing tool that declared no effects, dependency listed after its dependent). "Provable" via the self-contained checkers, same as 2.1 — Phase 2 is now complete.

---

## Phase 3: Native ML Capability (Months 24–36)

**Goal:** Make Rusty capable of real numeric/ML workloads on its own — benchmarked *against* PyTorch/JAX, never dependent *on* them.

### 3.1 Native Tensor & Autodiff
- [x] **Native tensor type**: `Value::Tensor` (flat row-major `Rc<Vec<f64>>` + shape, `src/env.rs`) with builtins in `src/interp.rs`: `tensor` (nested-list construction with shape inference and ragged rejection), `zeros`/`ones`, `tensor-shape`/`tensor-ref`/`tensor->list` (round-trips through `equal?`), elementwise `tensor-add/sub/mul/div` with scalar broadcast in either order, `matmul` (rank-2, inner-dim checked), `transpose`, `tensor-map`, `tensor-sum`. No PyTorch/JAX/candle/burn — Rusty's own buffers, per the design constraint. Verified against hand-computed results throughout, ending with a linear-layer forward pass `y = xW + b` in pure Lisp.
- [x] **Graph IR tensor ops**: `graph_ir.rs` grew `TAdd/TSub/TMul/TDiv/MatMul/Transpose/TSum` ops and a `GVal` (number-or-tensor) runtime value for `eval_graph`, so `graph-ir`/`graph-node-count`/`graph-eval` accept tensor expressions and tensor arguments. The existing pipeline applies unchanged and shape-agnostically: hash-consing CSE (a shared `(matmul x w)` is interned once — 4 nodes vs 6 unshared, so the expensive matmul runs once), constant-`if` branch pruning + DCE (an untaken `matmul` branch is swept entirely). Constant folding stays scalar-only by construction — tensors have no literal form in the Expr subset, so they only enter graphs through `Param`s. Verified for result parity against the direct tensor builtins (linear layer `xW + b` identical through both paths) and clean shape/rank/type errors at eval time.
- [x] **C ABI export, not a bridge**: `defrust`/`grad`-generated functions already compile to a plain `extern "C"` function (`rust_jit.rs`) — anything, including PyTorch via `ctypes` or a custom op, can already call *into* Rusty-compiled code. Rusty doesn't need to depend on PyTorch for that to work in the other direction, so there was no "bridge" to build, just documentation of what already works — now in README's "C ABI export" section (cache path, `rusty_`-sanitized symbol name, the fixed `extern "C" fn(*const f64, usize) -> f64` signature, ctypes example). Verified live: `fib-native`'s cached `.so` called from Python ctypes with no Rusty process involved, `fib(20)=6765` / `fib(30)=832040` matching the Lisp side exactly.
- [x] **Model serialization**: `save-model`/`load-model` builtins (`src/interp.rs`) — Rusty's own format: a versioned JSON envelope (`{"rusty-model": 1, "value": ...}`) over *data* values via `serde_json` (already a dependency). Scalars/lists map to JSON directly; symbols and tensors are tagged objects (`{"t":"sym"}` / `{"t":"tensor","shape","data"}`) so they round-trip losslessly, unlike `json-encode` which flattens symbols to strings; serde_json's ryu printing makes finite f64s bit-exact across save/load. Graph IR state serializes as-is (it's already list data). Code values (lambda/tool/macro) are rejected by design — live-environment serialization is 3.2's checkpoint/restore, not model data — as are NaN/Inf (no JSON form) and files without the envelope tag. Verified: weights+metadata alist round-trips `equal?`, the reloaded tensors produce an identical linear-layer forward pass, symbol-vs-string distinction survives, and every rejection path errors cleanly.
- [x] **Tensor autodiff — reverse-mode over the Graph IR** (`graph_ir.rs::backward`, the `graph-grad` builtin): one reverse sweep emits gradient rules as more graph nodes into the same interner (forward/backward subexpressions CSE against each other for free), then multi-output fold+DCE (`optimize_outputs`) and a single `eval_graph_outputs` pass return the loss plus the gradient w.r.t. *every* parameter. New ops: `Relu` (with surface syntax + a `relu` builtin) and three gradient-only ops with no surface form — `Step` (relu's derivative), `SumTo` (undo scalar broadcast), `Expand` (`tensor-sum`'s gradient). Comparisons and data-dependent `if` refuse cleanly (constant-condition `if` is pruned before the pass and differentiates fine); non-scalar losses are rejected with a pointer to `tensor-sum`/mean. This is deliberately *not* an extension of the symbolic `grad` builtin — reverse-mode gives all gradients for one extra pass, symbolic per-parameter expressions don't scale and matrix calculus doesn't fit symbol-level rewriting.
- **Deliverable — done:** A Rusty-native tensor workload (a small neural layer's forward+backward pass) benchmarked against PyTorch on the same hardware — Rusty doesn't call PyTorch to produce the result, it's compared to it after the fact. **Correctness:** `graph-grad` gradients for `mean((relu(xW+b)−t)²)` match analytic formulas to <1e-9, finite differences to ~2e-10 on every element of W/b/x, and PyTorch float64 autograd **bit-for-bit (worst |Δ| = 0.0)** across loss+gW+gB. **Speed** (1-thread float64 PyTorch 2.12.1, same machine, identical inits, final losses matching to 12–14 significant digits): 8×16→8 layer, 1000 SGD steps: Rusty 49.5ms vs PyTorch 585.8ms (**~11.8× faster** — per-op dispatch overhead dominates PyTorch at tiny sizes); 64×256→64, 100 steps: Rusty 316ms vs PyTorch 433ms (**~1.4× faster**). Honest caveats: Rusty rebuilds+optimizes the graph every `graph-grad` call (caching/fusion is 3.3), its matmul is naive O(n³), and BLAS will win at larger sizes/float32/multithread — the gap is the motivation for 3.3's kernel fusion.

### 3.2 Distributed Agent Orchestration
- [x] **Message passing**: actor-model agents in pure Lisp (`std.lisp`, no evaluator changes — same library-phase pattern as 1.3): `agent-spawn` (named handler + FIFO mailbox), `send!` (enqueue; unknown-agent errors return as data), `run-agents` (deterministic scheduler — agents visited in spawn order, one message popped per step, handler runs to completion and may `send!` more; returns `(quiescent n)` or `(hit-max-steps n)`, default cap 10000 guards runaway ping-pong), plus `agent-names`/`mailbox-count`/`agents-step`/`agents-idle?`/`agent-reset!`. Handlers keep state by `set!`-ing enclosing bindings. Single-threaded cooperative by design — Rusty's runtime is `Rc`-based, so "concurrency" is interleaved message handling, not threads; LLM-backed agents are just handlers that call `llm`. Verified: 3-stage pipeline (10 seeds → square → collector) sums to 385 in exactly 20 steps, ping-pong countdown multi-hop, self-send (dequeue-before-handle), duplicate-spawn/unknown-agent errors as data, runaway echo pair stopped at the cap, reset to empty.
- [x] **Checkpoint / restore**: `(checkpoint "file.lisp")` special form (`src/checkpoint.rs`) snapshots the global env as **plain Lisp source** — one `define`/`defmacro`/`deftool` form per user binding — so restore is just `(load "file.lisp")` into a fresh interpreter: no separate format, human-readable, hand-editable. Skips a pristine baseline (builtins + std.lisp + memory) by name for code and by `value_equal` for data, so changed stdlib *data* like `*agents*`/`*mailboxes*` is captured (handler lambdas serialize as `(lambda ...)` source inside `(list ...)` rebuilds; mailbox queues as quoted data). Closures re-close over the restored global env — top-level defines round-trip faithfully; let-bound captures don't (checkpointable actors keep state in globals via `set!`, as the std.lisp examples do). `defrust` natives can't serialize (compiled `.so`) and are listed in a header comment. Verified cross-process: actor pipeline interrupted at 7/20 steps with 10 messages in flight, restored in a **new process**, ran the remaining 13 steps to the exact uninterrupted answer (385); macros/tools/tensors/escaped strings all round-trip.
- [x] **Tracing & observability**: `src/trace.rs` — thread-local, off-by-default event log, same philosophy as `eval::macro_profile` generalized. `(trace-on)`/`(trace-off)`/`(trace-clear)`/`(trace-report)`/`(trace-dropped)` builtins plus `(trace-event kind name [data])` for Lisp-side events (cheap no-op when off, so std.lisp's actor scheduler calls it unconditionally — `send` and `agent-handle` events). Interpreter-side events: `tool-call` with duration (via the `tool-call` form and `apply`), `tool-enter` without (the first-class call path is a TCO `continue` — its end isn't observable without breaking tail calls), `llm` (duration + prompt/response sizes, both the `llm` form and react-loop's internal calls), `shell` (duration + command), `react-step`. `(trace-report)` rows are `(seq t-micros kind name dur data)` — **pure data**, so it `save-model`s and `json-encode`s as-is; export to OTel or anything else is the consumer's job, Rusty produces traces with zero external dependencies. 100k-event cap with a dropped counter. Verified: all three tool paths emit the right kinds, durations exactly where promised, actor trace shows the scheduler's deterministic interleaving, report round-trips through `save-model`, timestamps monotonic, live `llm` event against the local server.
- **Deliverable — done:** Multi-agent system where agents coordinate symbolic reasoning — `swarm.lisp`, now a golden test (`expected_swarm.txt`, wired into `run_tests.sh`). Three agents coordinate **through messages alone**: a proposer (scripted candidate queues — swap in `llm-proposer` for a live model), a verifier whose brain is the Phase-2 proof machinery (static `check-effects`/`check-types` gates first — an impure candidate is rejected *without ever executing*, visible in the demo output — then `check-exhaustive` over the spec's domains), and a certifier recording results. Rejections loop feedback back to the proposer as messages. The run synthesizes `abs` (3 attempts: impure → wrong → verified) and `max` (2 attempts) **interleaved** — both tasks progress concurrently under the deterministic scheduler — with all 12 hops traced (`sends 12 handled 12`) and the certified functions demonstrably working. Every 3.2 capability shows up in one artifact: actors, tracing, the checkpointable global-state discipline.

### 3.3 Performance & Optimization
- [x] **JIT compilation**: this is `defrust` (`rust_jit.rs`, Phase 1.2) — this item is now "extend it" (support more of the language, not "build it"). Done (v0.18.0): the compiled subset gained `let`/`let*` locals (with correct parallel-vs-sequential semantics — `let` binds via Rust tuple destructuring so inits can't see each other; verified on a shadowing case where the two genuinely diverge, 12 vs 20, compiled matching interpreted on both), `cond` (requires a final `else` — every path must produce an f64), and the numeric builtins `sqrt expt abs mod floor ceiling round min max` mapped to their exact f64 counterparts (one documented divergence: `(mod x 0)` is NaN compiled vs an error interpreted — a compiled body has no error channel). And the big v1 limitation fell: **`defrust*` compiles a group of functions into ONE `.so`**, so calls between them are plain Rust calls — mutual recursion works (verified: Hofstadter F/M vs the interpreter on n=0..12, even?/odd? pair) with no cross-library linking needed. Still cut: no lists/strings/closures/global capture (everything is f64), no calls into interpreted code.
- [ ] **Kernel fusion**: wire Graph IR (`graph_ir.rs`, Phase 1.2) into `defrust`'s codegen so an optimized graph compiles to one fused native function instead of interpreting the DAG node-by-node — the integration explicitly deferred when Graph IR shipped. *Scalar half done (v0.19.0):* `(graph-compile (lambda ...))` emits the optimized DAG (CSE/folding/DCE already applied) as one straight-line Rust function — every node a `let`, `If` as the same eager select `eval_graph` uses — through the shared `rustc`/cache/`libloading` pipeline, returning a callable `Value::Native`. Measured on a 282-node kernel: tree-walk 192.6µs/call → fused 6.7µs/call (**~29×**, and the 6.7µs is almost entirely Lisp call dispatch — the kernel body is nanoseconds); `graph-eval` on the same lambda is 195µs/call because it rebuilds+optimizes the graph every call, which is exactly the overhead compiling once removes. Results bit-identical across all three paths. *Remaining:* the tensor half — shape-specialized fusion of `graph-grad`'s forward+backward graph for training loops.
- [ ] **Memory pooling**: `src/arena.rs` already exists as a dormant mark/sweep allocator (not wired into the evaluator) — this item is "activate and integrate it," not build a new one
- **Deliverable:** 10x speedup on agent benchmarks vs. naive interpretation

---

## Phase 4: Ecosystem & Libraries (Months 36–48)

**Goal:** Build killer applications proving Rusty's value.

### 4.1 Symbolic Regression
- [ ] **Genetic programming for equation discovery**: Find human-readable equations from data
- [ ] **Macro-based expression generation**: Use macros to explore solution space efficiently
- **Deliverable:** Library that outperforms symbolic regression benchmarks

### 4.2 Formal Program Synthesis
- [ ] **Sketch-based synthesis**: Fill holes in incomplete programs using constraint solving
- [ ] **LLM + constraint solver loop**: Use LLM to propose candidates, Rusty constraints to validate
- **Deliverable:** Example: synthesize sorting algorithms from spec

### 4.3 Theorem Proving Assistant
- [ ] **Interactive proof search**: tactics implemented natively over Rusty's own proof-obligation representation (extending the bounded-checking / proof-by-checker-loop work from 2.1) — not a Lean/Coq plugin
- [ ] **Proof strategy macros**: High-level proof patterns as Lisp macros
- **Deliverable:** Rusty-powered proof assistant for the invariants Rusty itself can express (not general mathematics — that scope genuinely needs a Lean/Coq-scale system, which is exactly what this roadmap's design constraint rules out)

### 4.4 Robotics / Autonomous Systems
- [ ] **Deterministic task execution**: Timing-aware execution guarantees for control loops
- [ ] **Safety verification**: Prove robot behavior respects safety constraints
- **Deliverable:** Rusty agent controlling a simulated robot safely

---

## Phase 5: Maturity & Adoption (Months 48–60)

**Goal:** Establish Rusty as a recognized standard.

### 5.1 Language Stability
- [ ] **Language specification**: Formal semantics for Rusty Lisp dialect
- [ ] **Backwards compatibility**: Stable ABI; no breaking changes without major version bump
- [ ] **Comprehensive documentation**: Tutorial, reference, best practices guides
- **Deliverable:** v1.0.0 release with semantic versioning

### 5.2 Ecosystem Maturity
- [ ] **Package manager**: Rusty package registry (like crates.io for Rust, PyPI for Python)
- [ ] **IDE support**: LSP server, debugger, profiler integrations
- [ ] **Testing framework**: Comprehensive testing utilities, benchmarking tools
- **Deliverable:** Full dev environment (editor, tests, CI/CD support)

### 5.3 Community & Advocacy
- [ ] **Flagship projects**: 2-3 open-source projects that showcase Rusty's power
- [ ] **Academic partnerships**: Collaborate with universities on AI/formal methods research
- [ ] **Production deployments**: Deploy Rusty in 1-2 companies' critical systems
- **Deliverable:** Recognition as a serious tool for symbolic AI

---

## Key Milestones & Checkpoints

| Phase | Timeline | Key Deliverable | Success Metric |
|-------|----------|-----------------|----------------|
| 1 | Q1–Q4 2025 | Symbolic DSL + code generation | Rusty-generated code ≥ PyTorch performance |
| 2 | Q1–Q2 2026 | Self-contained verification | Tool specifications verified via Rusty's own checkers (no external prover) |
| 3 | Q3–Q4 2026 | Native ML capability | Rusty-native tensor workload benchmarked against PyTorch |
| 4 | Q1–Q4 2027 | Killer app libraries | Symbolic regression outperforms SOTA |
| 5 | Q1 2028+ | Maturity | v1.0.0 release, 10+ production users |

---

## Near-Term Action Items (Next 3 Months)

This section is now stale relative to actual progress — most of it shipped in Phase 1/2.2 already, and one line below ("integrate with a simple ML framework") is exactly the external-dependency framing the Design Constraint above rules out. Left visible rather than deleted so it's clear what changed and why.

### Immediate (This Sprint)
- [ ] Complete ARCHITECTURE.md documenting evaluator and macro system
- [ ] Write 3 macro examples showing code generation potential
- [x] Benchmark current macro performance — `(macro-profile-on)`/`(macro-profile-report)`/`(show-macro-profile)`, Phase 1.1
- [ ] Set up CI/CD with performance regression detection

### Next Sprint (Month 2)
- [x] Implement compile-time evaluation (`eval-when`) — Phase 1.1
- [x] Build first symbolic differentiation macro — `grad`, Phase 1.2
- [x] Create computation graph IR prototype — `src/graph_ir.rs`, Phase 1.2 (further along than "prototype": has CSE/constant-folding/DCE, not just a data structure)
- [ ] Publish benchmark comparison vs. PyTorch — the `defrust` fib benchmark exists (Phase 1.2's deliverable note) but isn't published anywhere; a real PyTorch-comparable benchmark still needs Graph IR wired into `defrust` (Phase 3.3)

### Sprint 3 (Month 3)
- [x] Finalize graph optimization passes — Phase 1.2
- [x] Begin neuro-symbolic bridge library design — Phase 1.3 (`defun-constrained`/`logic-loss`)
- [ ] ~~Integrate with simple ML framework~~ — superseded by Phase 3.1's native tensor type; no ML framework dependency, per the Design Constraint above
- [ ] Write user-facing tutorial

---

## Resource Allocation

### Current (v0.10.0)
- 1 maintainer (TheLakeMan)
- Focus: Core language stability, tool system, ReAct integration

### Phase 1 (Target: v0.15–0.20)
- Need: +1 core developer (macro systems, DSL design)
- Need: +1 community contributor (testing, documentation)

### Phase 2 (Target: v0.25–0.30)
- Need: +1 formal-methods-literate contributor (self-built verification/checker design — no Lean interop needed, per the design constraint above)

### Phase 3+ (Target: v0.5–1.0)
- Need: Small team (3–5) for ML integration and performance

---

## Open Questions & Research Areas

1. **How to best represent computation graphs in Lisp?**
2. **Can we achieve production-grade safety without dependent types?**
3. **What's the right abstraction for agent memory persistence?**
4. **How to make Rusty visible to the broader AI/ML community?**

---

**Last updated:** July 2026 | **Status:** Phases 1 and 2 complete; 3.1 (Native Tensor & Autodiff) and 3.2 (Distributed Agent Orchestration) complete incl. deliverables; 3.3 (Performance & Optimization) in progress — defrust extensions done, kernel fusion next

☯ *In memory of my brother.*
