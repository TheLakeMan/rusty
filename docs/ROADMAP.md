# Rusty 5-Year Roadmap

## Vision

**Rusty as the symbolic transformation layer for AI/ML infrastructure.**

Make Rusty the language people reach for when they need **computation that reasons about computation** — LLM as creative planner, Rusty as reliable executor with memory, symbolic reasoning, and verifiable correctness.

### North Star

In 5 years, Rusty will be:
- **Deeply embedded in AI/ML infrastructure** where symbolic computation bridges abstract mathematical logic and high-performance numerical execution
- **The canonical tool** for building neuro-symbolic systems that combine neural networks with logic-driven reasoning
- **Proven in production** across 2-3 high-impact domains (formal verification, robotics control, or scientific computing)

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

### 2.1 Formal Reasoning Integration
**Deferred, not started** — every item here needs the project owner to pick a real external toolchain/format (which Lean 4 version and interop mechanism? TLA+ how, exactly?) plus likely a new network- or toolchain-facing dependency. Revisit once those choices are made; skipping ahead to 2.2/2.3, which are self-contained interpreter/library work like everything in Phase 1.
- [ ] **Lean 4 interop**: Call Lean proofs from Rusty code; verify Rusty functions in Lean
  - `(lean-verify (lambda (n) (< n 1000000)) "theorem_name")`
- [ ] **Proof synthesis**: Automatic proof generation for agent tool correctness
- [ ] **Model checking**: Bounded model checking for agent behavior (using tools like TLA+)
- **Deliverable:** A suite of tools with attached machine-readable proofs; agent that can verify its own actions are safe

### 2.2 Static Analysis & Type System
- [x] **Gradual typing**: `(define-typed (name (p1 : t1) (p2 : t2) untyped-p3 ...) : return-type body...)` (std.lisp, `define`/`lambda` themselves untouched — opt-in). `ti`/`return-type` name an existing `<type>?` predicate; checked as **runtime contracts at call time** (not static analysis — see the two items below, which are the actual static half of this section and remain undone). Verified: correct calls pass through untyped, a wrong param type and a wrong return type both raise a clear "expected X, got a different type" instead of silently miscomputing. Hit and fixed a real bug along the way: the macro's own `__result` temp crossed an `unquote` boundary in a way the hygiene pass (1.1) couldn't see through, so it renamed the binding but not a reference generated by a helper function — fixed the same way `swap!`/`repeat` already do, with `(gensym "result")` computed once and spliced everywhere via unquote instead of a literal template binding.
- [ ] **Flow-sensitive analysis**: Track value types through conditionals and let bindings — **not started**. This is real static type inference/narrowing (an abstract-interpretation pass over the AST — track a variable's possible type(s) through `if`/`let`, narrow on `number?`/`string?`-style predicate tests, join at merge points), a different and larger undertaking than the runtime contracts above; needs its own design pass (what does it report — warnings? a query API? a compile-time error?), not something to improvise inline.
- [ ] **Effect tracking**: Mark side-effecting operations; ensure pure functions remain pure — **not started**. Smaller than flow-sensitive analysis (mostly a pure/effectful classification of builtins plus an AST walk) but still deferred alongside it to keep this a single coherent follow-up rather than splitting static-analysis work across sessions.
- **Deliverable:** Type checker that catches common agent errors (e.g., passing wrong arg types to tools) — satisfied by `define-typed` above for the "wrong arg type" case; static (rather than runtime) checking still needs the two items above.

### 2.3 Tool Registry with Specifications
- [ ] **Tool specifications**: Formal signatures + invariants for all tools
- [ ] **Contract enforcement**: Runtime checks + static verification
- [ ] **Tool dependency graphs**: Track dependencies and execution order constraints
- **Deliverable:** Safety certification for agent tool chains (provably safe execution)

---

## Phase 3: Production ML Integration (Months 24–36)

**Goal:** Make Rusty a first-class component in ML infrastructure.

### 3.1 PyTorch / JAX Integration
- [ ] **Tensor interop**: Zero-copy exchange of ndarrays between Rusty and PyTorch/JAX
- [ ] **Autodiff bridge**: Call rusty-generated gradients from PyTorch
- [ ] **Model serialization**: Save/load Rusty agent + neural models together
- **Deliverable:** End-to-end example: PyTorch model + Rusty symbolic reasoning pipeline

### 3.2 Distributed Agent Orchestration
- [ ] **Message passing**: Spawn multiple agent instances, coordinate via Lisp message queue
- [ ] **Checkpoint / restore**: Serialize agent state (environments, tool results) for fault tolerance
- [ ] **Tracing & observability**: OpenTelemetry integration for agent execution traces
- **Deliverable:** Multi-agent system where agents coordinate symbolic reasoning

### 3.3 Performance & Optimization
- [ ] **JIT compilation**: Compile hot Rusty code paths to native machine code
- [ ] **Kernel fusion**: Combine adjacent operations into single efficient kernels
- [ ] **Memory pooling**: Reduce allocations for high-frequency agent loops
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
- [ ] **Interactive proof search**: Implement tactics for Lean / Coq in Rusty
- [ ] **Proof strategy macros**: High-level proof patterns as Lisp macros
- **Deliverable:** Rusty-powered proof assistant for formal mathematics

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
| 2 | Q1–Q2 2026 | Formal verification integration | Tool specifications verified via Lean |
| 3 | Q3–Q4 2026 | ML infrastructure integration | End-to-end PyTorch + Rusty pipeline |
| 4 | Q1–Q4 2027 | Killer app libraries | Symbolic regression outperforms SOTA |
| 5 | Q1 2028+ | Maturity | v1.0.0 release, 10+ production users |

---

## Near-Term Action Items (Next 3 Months)

### Immediate (This Sprint)
- [ ] Complete ARCHITECTURE.md documenting evaluator and macro system
- [ ] Write 3 macro examples showing code generation potential
- [ ] Benchmark current macro performance
- [ ] Set up CI/CD with performance regression detection

### Next Sprint (Month 2)
- [ ] Implement compile-time evaluation (`eval-when`)
- [ ] Build first symbolic differentiation macro
- [ ] Create computation graph IR prototype
- [ ] Publish benchmark comparison vs. PyTorch

### Sprint 3 (Month 3)
- [ ] Finalize graph optimization passes
- [ ] Begin neuro-symbolic bridge library design
- [ ] Integrate with simple ML framework
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
- Need: +1 formal methods specialist (Lean interop, verification)

### Phase 3+ (Target: v0.5–1.0)
- Need: Small team (3–5) for ML integration and performance

---

## Open Questions & Research Areas

1. **How to best represent computation graphs in Lisp?**
2. **Can we achieve production-grade safety without dependent types?**
3. **What's the right abstraction for agent memory persistence?**
4. **How to make Rusty visible to the broader AI/ML community?**

---

**Last updated:** July 2026 | **Status:** On track — Phase 1 in progress

🦀 *In memory of the brother who inspired this journey.*
