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
- [ ] **Proof-by-checker loop**: use `react-loop` to propose candidate implementations against a spec expressed as `defun-constrained` invariants plus `check-types`/`check-effects` constraints, rejecting any candidate the existing checkers can't verify. This is the self-contained replacement for "proof synthesis" — the "prover" is Rusty's own static/runtime checkers, not an SMT solver or Lean.
- [ ] **Bounded exhaustive checking**: for functions over small/finite/discrete state spaces (a robot's mode machine, a tool's argument enum), exhaustively verify a declared invariant holds across every reachable state via a self-built brute-force/BFS walk of the state space. This is the self-contained, narrower-scope replacement for "model checking" — it won't scale to continuous/infinite state spaces the way TLA+ does; that's the deliberate tradeoff for staying dependency-free, not an oversight.
- [x] **Cross-checker registry**: `define-typed`'s expansion now also calls `register-signature` (new builtin → `type_check::register_signature`, a thread-local name → (param types, return type) map), and `check-types` consults it when it hits a call it doesn't otherwise recognize — so static and runtime checking share one source of truth. Verified: a call to a `define-typed` function with a wrongly-typed arg is flagged statically; the declared *return* type flows onward (`(string-length (f x))` flagged when `f` is declared `: number`); unannotated positions register as `unknown` and are never flagged; plain `define`d functions behave exactly as before.
- **Deliverable:** A function whose safety was previously "trust the tests" gets a Rusty-native proof of a stated invariant, using only what Rusty already ships with.

### 2.2 Static Analysis & Type System
Everything here was already built self-contained, before "no external runtime dependencies" was written down explicitly above — it's the working example the constraint in the Vision section is describing, not a retrofit.
- [x] **Gradual typing**: `(define-typed (name (p1 : t1) (p2 : t2) untyped-p3 ...) : return-type body...)` (std.lisp, `define`/`lambda` themselves untouched — opt-in). `ti`/`return-type` name an existing `<type>?` predicate; checked as **runtime contracts at call time** (not static analysis — see the two items below, which are the actual static half of this section and remain undone). Verified: correct calls pass through untyped, a wrong param type and a wrong return type both raise a clear "expected X, got a different type" instead of silently miscomputing. Hit and fixed a real bug along the way: the macro's own `__result` temp crossed an `unquote` boundary in a way the hygiene pass (1.1) couldn't see through, so it renamed the binding but not a reference generated by a helper function — fixed the same way `swap!`/`repeat` already do, with `(gensym "result")` computed once and spliced everywhere via unquote instead of a literal template binding.
- [x] **Flow-sensitive analysis**: `(check-types (lambda (params...) expr) '((param type)...))` (`src/type_check.rs`) — a static checker that walks the body *without executing it*, tracking each variable's known type through `if`/`let`/`let*`: narrows on a recognized `<type>?` predicate test in an `if` condition (in the then-branch), propagates through `let`/`let*` init expressions, and reports any operation it can *prove* runs on the wrong type. Deliberately conservative — an undeterminable type is `Unknown` and is never flagged, so it only reports provable mismatches, never guesses. Verified: flags `(string-length x)` when `x` is declared `number`; does *not* flag the same call inside a `(let ((y (+ x 1))) ...)` when it's actually `string-length` on `y` that's wrong (propagation); and — the key flow-sensitive proof — narrowing from `(if (number? x) (+ x 1) ...)` *overrides* an outer declared type of `string` for `x` within that branch, so no false positive there. v1 cuts (each an extension point): only `if`/`let`/`let*` understood, no union types, and user-defined function calls always return `Unknown` — *the last of these was closed by 2.1's cross-checker registry; `define-typed` functions now check statically.*
- [x] **Effect tracking**: `(check-effects (lambda (params...) body...))` (`src/effect_check.rs`) walks every body statement *without executing them* and reports each operation it can prove is effectful, from a fixed classification (`set!`/`set` mutate; `print`/`println`/`display`/`newline` do I/O; `shell`/`shell-run` run commands; file ops touch the filesystem; `llm`/`tool-call`/`react-loop` call external services; `remember`/`recall`/`forget`/`memory-list` touch persistent memory; `gensym` is non-deterministic; `load`/`load-relative` execute another file) or `'pure` if none are found. Same conservative philosophy as `check-types` — an unrecognized/user-defined call is never flagged, since purity can't be proven either way for it without whole-program analysis. `(effectful? 'name)` exposes the same classification as a simple query. Correctly distinguishes `quote`d data (inert, never flagged even if it looks like `(set! ...)`) from `quasiquote`'s `unquote`/`unquote-splicing` parts (which *are* evaluated and are checked) — verified for both.
- **Deliverable:** Type checker that catches common agent errors (e.g., passing wrong arg types to tools) — satisfied by `define-typed` (runtime) and `check-types` (static) above.

### 2.3 Tool Registry with Specifications
- [ ] **Tool specifications**: Formal signatures + invariants for all tools
- [ ] **Contract enforcement**: Runtime checks + static verification — reuse `define-typed`/`check-types`/`check-effects` (2.2) against `deftool` signatures rather than building a second, parallel contract system
- [ ] **Tool dependency graphs**: Track dependencies and execution order constraints
- **Deliverable:** Safety certification for agent tool chains (provably safe execution) — "provable" via the self-contained checkers above, same as 2.1

---

## Phase 3: Native ML Capability (Months 24–36)

**Goal:** Make Rusty capable of real numeric/ML workloads on its own — benchmarked *against* PyTorch/JAX, never dependent *on* them.

### 3.1 Native Tensor & Autodiff
- [ ] **Native tensor type**: a Rusty-owned tensor value (flat buffer + shape/strides) and Graph IR ops over it, extending `graph_ir.rs`'s scalar `Op`s to vectors/matrices — no PyTorch/JAX/candle/burn dependency. (Even Rust-native ML crates are still an external dependency to avoid here — the point is Rusty carries its own weight.)
- [ ] **C ABI export, not a bridge**: `defrust`/`grad`-generated functions already compile to a plain `extern "C"` function (`rust_jit.rs`) — anything, including PyTorch via `ctypes` or a custom op, can already call *into* Rusty-compiled code. Rusty doesn't need to depend on PyTorch for that to work in the other direction, so there's no "bridge" to build here, just documentation of what already works.
- [ ] **Model serialization**: save/load Rusty agent + tensor/Graph-IR state together in Rusty's own format, using `serde` (already a dependency) — no external format required.
- **Deliverable:** A Rusty-native tensor workload (e.g. a small neural layer's forward+backward pass) benchmarked against PyTorch on the same hardware — Rusty doesn't call PyTorch to produce the result, it's compared to it after the fact.

### 3.2 Distributed Agent Orchestration
- [ ] **Message passing**: Spawn multiple agent instances, coordinate via Lisp message queue
- [ ] **Checkpoint / restore**: Serialize agent state (environments, tool results) for fault tolerance, via `serde` — no external store required
- [ ] **Tracing & observability**: Rusty's own lightweight execution-trace format, extending the macro profiler's approach (`eval::macro_profile`) to general agent/tool execution — optionally exportable to OpenTelemetry or similar by whoever consumes it, but Rusty itself doesn't depend on an OTel collector to produce a trace
- **Deliverable:** Multi-agent system where agents coordinate symbolic reasoning

### 3.3 Performance & Optimization
- [ ] **JIT compilation**: this is `defrust` (`rust_jit.rs`, Phase 1.2) — this item is now "extend it" (support more of the language, not "build it")
- [ ] **Kernel fusion**: wire Graph IR (`graph_ir.rs`, Phase 1.2) into `defrust`'s codegen so an optimized graph compiles to one fused native function instead of interpreting the DAG node-by-node — the integration explicitly deferred when Graph IR shipped
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

**Last updated:** July 2026 | **Status:** Phase 1 complete; Phase 2.2 complete; Phase 2.1/2.3, Phase 3 open

🦀 *In memory of the brother who inspired this journey.*
