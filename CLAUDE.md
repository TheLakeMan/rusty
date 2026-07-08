# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
cargo build              # debug
cargo build --release    # release (used by run_tests.sh)

# Run
cargo run                        # REPL
cargo run -- path/to/script.lisp # run a .lisp file
cargo run -- agent.lisp          # agent/tool demo

# Test — golden-file comparison, no cargo test harness
./run_tests.sh            # builds release, diffs output of tests.lisp / new-features.lisp / hello.lisp
                           # against expected_tests.txt / expected_new.txt / expected_hello.txt
cargo run --release -- tests.lisp | diff - expected_tests.txt   # run a single golden file by hand

# Python bridge (optional `python` feature, enabled by default; needs maturin)
maturin develop            # install into active venv
python3 -c "import rusty; print(rusty.eval('(+ 1 2)'))"
```

There is no `cargo test` suite — correctness is checked by running a `.lisp` file and diffing stdout against a checked-in expected-output file. When adding new language behavior, extend `tests.lisp` (or `new-features.lisp`) and update the matching `expected_*.txt`, or add a new pair and a `run_test` line in `run_tests.sh`.

## Architecture

Two binary/library targets (`src/main.rs` for the CLI/REPL, `src/lib.rs` for the PyO3 Python module) both wrap the same core: `lexer.rs` → `parser.rs` → `eval.rs` + `interp.rs` → `env.rs`. Neither entry point should contain interpreter logic — new builtins/special forms go in `interp.rs`/`eval.rs` so both targets get them for free.

- **`src/lexer.rs` / `src/parser.rs`** — tokenizer and S-expression parser. Backtick/comma/comma-at desugar at parse time into `(quasiquote ..)` / `(unquote ..)` / `(unquote-splicing ..)` list forms — there's no separate AST node for them.
- **`src/eval.rs`** — the evaluator. `eval()` is a single trampoline `loop { match &cur { ... } }`: special forms and tail positions rebind `cur`/`env` and `continue` instead of recursing, which is what gives TCO to arbitrary depth. When adding a new special form, follow this pattern (rebind + `continue`) rather than calling `self.eval` recursively, or deep recursion won't be stack-safe.
- **`src/env.rs`** — `Env = Rc<RefCell<EnvFrame>>`, a parent-linked chain of `HashMap<String, Value>` frames (lexical scoping via closure-captured `Env`). `Value::List` is `Rc<Vec<Value>>` — cloning a list is an O(1) refcount bump, not a deep copy.
- **`src/interp.rs`** — builtins (`b!`/`alias!` macros register into the global `Env`), the stdlib loader (`std.lisp`, embedded via `include_str!` and used as a fallback if the file isn't found on disk), and the persistent `remember`/`recall`/`forget` Lisp-level memory system backed by `~/.rusty/memory.lisp` (auto-loaded by `make_env()` on every fresh environment — unrelated to Claude Code's own memory).
- **`src/arena.rs`** — a mark/sweep arena allocator that is **not wired into the evaluator**; `eval.rs` still allocates lists directly via `env::list()`. Dormant until intentionally integrated.
- **`src/llm.rs`** — **dead code**: not declared as a `mod` in either `main.rs` or `lib.rs`. The real LLM client (`call_llm`, used by the `llm` and `react-loop` special forms) lives inline in `eval.rs` and reads `RUSTY_MODEL` / `RUSTY_LLM_URL` / `RUSTY_SYSTEM` env vars, defaulting to a local `llama-server`-compatible endpoint at `localhost:8080`.
- **Macros** (`defmacro`/`define-macro`, `src/eval.rs`) expand via ordinary evaluation of the macro body in an env extended with its (unevaluated) argument expressions. Hygiene is enforced at *definition* time: `hygienic_rename`/`hygienic_rename_top` rewrite identifiers a macro's own `quasiquote` template binds via `let`/`let*`/`letrec`/`lambda`/`do`/named-`let` into fresh gensyms, so the template's internal names can't capture, or be captured by, call-site code — but identifiers supplied through `,x`/`,@x` are left untouched (and free-identifier references inside a template, like a bare `table` symbol, are *not* rewritten to resolve in the macro's closure env — only unquoted references are). `gensym` (builtin) and this rename pass share one counter, `env::gensym_name`. A top-level `(eval-when (phase...) ...)` in a macro's body runs once at definition time (not once per expansion) in the env that becomes the macro's closure, letting a macro precompute something (e.g. one shared `gensym`'d name) instead of redoing it on every call; outside `defmacro`, `eval-when` just runs its body immediately, like `begin`. Expansion can be profiled: `eval::macro_profile` is a thread-local, off-by-default counter/timer wrapped around every macro expansion; `(macro-profile-on)` / `(macro-profile-report)` / `(show-macro-profile)` (the last in `std.lisp`) expose it. It attributes each expansion separately even when a macro expands into another macro (e.g. `repeat` expanding into `dotimes` counts one hit each).
- **Tools/agents** (`deftool`, `tool-call`, `react-loop`, `src/eval.rs`) are a separate `Value::Tool` variant from `Lambda`; `agent.lisp` registers filesystem/shell/LLM tools and drives a ReAct loop (ACTION/INPUT/OBSERVATION/FINAL) against the LLM client above.
- **`src/rust_jit.rs`** — `defrust` compiles a *restricted* numeric subset (numbers, params, `+ - * /`, `if`, self-recursive calls only — no calls between separate `defrust` functions, that needs cross-`.so` linking) to real Rust: generates source with a fixed `extern "C" fn(*const f64, usize) -> f64` ABI (uniform regardless of arity), shells out to `rustc --crate-type cdylib -O` (cached by a hash of the generated source, under `~/.rusty/jit-cache/`), and loads the result with `libloading`. Lisp names get sanitized to valid Rust identifiers (`fib-native` → `rusty_fib_native`) — don't assume the Rust symbol matches the Lisp name literally. Backing storage is `Value::Native { lib: Rc<Library>, fn_ptr: *const () }`: `fn_ptr` is a function pointer detached from `libloading::Symbol`'s lifetime via a raw-pointer transmute (see `rust_jit::call`), kept valid only because the `Rc<Library>` clone inside the same `Value` is never dropped while it's in use. Measured real speedup on tree-walked vs. compiled `fib(30)`: ~8.2s vs. ~0.007s (cached) — see `docs/ROADMAP.md` 1.2.
- **Symbolic differentiation** (`grad` builtin, `interp.rs` → `eval::symbolic_derivative`) is AST rewriting via calculus rules (`+ - * / expt sqrt`, plus `if`), not numeric/tracing autodiff — `(grad (lambda (x) expr))` returns a new callable `Lambda` whose body is the derivative expression, differentiated with respect to the lambda's *first* parameter (other free variables are treated as constants).
- **`src/graph_ir.rs`** — a computation DAG (`Graph`/`Node`/`Op`) over the same restricted numeric subset as `defrust`, built via hash-consing (an `Interner` that dedups `(Op, args)` during construction — this *is* the CSE, not a post-hoc pass). `optimize()` then runs constant folding (`fold`, including pruning an `if` branch when its condition is constant — the untaken branch just becomes unreachable) and dead-code elimination (`dce`, mark-and-sweep from `Graph::output`, which is what actually removes what folding orphaned). No codegen backend yet: `graph-eval` runs the optimized IR through `eval_graph`, a small tree-walking interpreter over the DAG itself — wiring this into `rust_jit`'s codegen is separate future work, not done.
- **Python bridge** (`src/lib.rs`): `RustyInterp` is stateless (fresh `Env` per call). `RustySession` fakes statefulness by **replaying its entire eval history into a fresh `Env` on every call** rather than holding one persistent `Env` — a deliberate choice to avoid `Rc` across the PyO3 boundary, but it means side effects (e.g. `shell`, file I/O) replay too.

Development follows the phased checklist in `docs/ROADMAP.md` (see also `docs/ARCHITECTURE.md`, `docs/AI_AGENTS.md`); check it for what's next before assuming a feature is unplanned. Phase 1.3 ("Neuro-Symbolic Bridge Layer") is explicitly a *library* phase — `defun-constrained`/`logic-loss`/`implies` live in `std.lisp` as plain macros, not new Rust special forms; there was no need to touch the evaluator for them. Note `assert` is a macro there (not a function, as it might look at a glance) — it needs the literal unevaluated condition to build a useful default error message.
