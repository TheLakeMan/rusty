# Rusty Architecture & Design

## Overview

Rusty is a Lisp interpreter implemented in Rust, optimized for **AI agent orchestration** and **symbolic reasoning**. The architecture is built around three core concepts:

1. **Evaluation as a trampoline loop** — Stack-safe recursion via explicit TCO
2. **Environments as immutable frames** — Lexical scoping with closure capture
3. **Tools as first-class values** — Agent capabilities registered and executed dynamically

---

## Core Pipeline

```
Source Code (.lisp or REPL input)
    ↓
[Lexer]  src/lexer.rs
    ↓ tokenize() → Vec<Token>
    ↓
[Parser]  src/parser.rs
    ↓ parse() → Vec<Expr> (AST)
    ↓
[Evaluator]  src/eval.rs
    ↓ eval(expr, env) → Value
    ↓ TCO trampoline loop
    ↓
[Interpreter]  src/interp.rs
    ↓ Builtin functions, stdlib loading
    ↓
[Result]
    ↓ REPL display or Python bridge
```

---

## Module Breakdown

### 1. Lexer (`src/lexer.rs`)

**Purpose:** Convert source text into tokens.

**Key types:**
```rust
pub enum Token {
    LParen, RParen, LBracket, RBracket,
    Symbol(String),
    Number(f64),
    String(String),
    Bool(bool),
    Quote, Quasiquote, Unquote, UnquoteSplicing,
}
```

---

### 2. Parser (`src/parser.rs`)

**Purpose:** Convert tokens into an abstract syntax tree (AST).

**Key types:**
```rust
pub enum Expr {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(Vec<Expr>),
    Nil,
}
```

---

### 3. Environment (`src/env.rs`)

**Purpose:** Manage lexical scoping, variable bindings, and closures.

**Key types:**
```rust
pub type Env = Rc<RefCell<EnvFrame>>;

pub enum Value {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(Vec<Value>),
    Nil,
    Lambda { params: Vec<String>, rest: Option<String>, body: Vec<Expr>, env: Env },
    Macro { params: Vec<String>, rest: Option<String>, body: Vec<Expr>, env: Env },
    Tool { name: String, description: String, params: Vec<String>, body: Vec<Expr>, env: Env },
    Builtin(String, fn(&[Value]) -> Result<Value, String>),
}
```

**Design:** Uses `Rc<RefCell<>>` for shared mutable state. Closures capture their definition environment (lexical scoping).

---

### 4. Evaluator (`src/eval.rs`)

**Purpose:** Execute expressions via TCO trampoline loop.

**Core algorithm:**
```rust
pub fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, String> {
    let mut cur = expr.clone();
    let mut env = env.clone();

    loop {
        match &cur {
            // Base cases: return immediately
            Expr::Number(n) => return Ok(Value::Number(*n)),
            
            // Special forms: set `cur` and continue (tail call)
            Expr::List(list) if head == "if" => {
                cur = if is_truthy(&test_val) { list[2].clone() } else { list[3].clone() };
                continue;  // ← No recursion!
            }
            
            // Function call: bind params, set body as cur
            Expr::List(list) => {
                let child = EnvFrame::extend(&cenv, &params, &rest, args)?;
                cur = body[last].clone();
                env = child;
                continue;  // ← Tail call optimization!
            }
        }
    }
}
```

**Why TCO matters:** Without TCO, deep recursion overflows the stack. By using an explicit loop and setting `cur` instead of recursing, we simulate tail calls. The Rust stack never grows.

**Special Forms:** `if`, `begin`, `lambda`, `define`, `defmacro`, `deftool`, `react-loop`, `llm`, etc.

---

### 5. Interpreter (`src/interp.rs`)

**Purpose:** Builtin functions (~60), stdlib management, shared evaluation entry point.

**Builtins:** Arithmetic, comparison, lists, strings, I/O, filesystem, shell, JSON, type checking

**Standard Library:** Threading macros (`->`, `->>`, `dotimes`, `dolist`, `while`), functional utilities

---

### 6. Python Bridge (`src/lib.rs`)

**Purpose:** Expose Rusty to Python via PyO3.

**Classes:**
- `RustyInterp` — Stateless interpreter
- `RustySession` — Stateful session (definitions persist across calls)

---

## Data Flow Examples

### Example 1: Simple Expression `(+ 1 2)`

1. **Lexer:** `[Symbol("+"), Number(1.0), Number(2.0)]`
2. **Parser:** `List([Symbol("+"), Number(1.0), Number(2.0)])`
3. **Evaluator:** Look up `+`, evaluate args, call builtin → `Value::Number(3.0)`

---

### Example 2: Tail-Call Recursion

```lisp
(define (sum-to n acc)
  (if (<= n 0) acc
      (sum-to (- n 1) (+ acc n))))

(sum-to 1000000 0)  ; Never overflows!
```

The trampoline loop allows unlimited recursion without stack growth.

---

### Example 3: Macro Expansion

```lisp
(defmacro my-when (test . body)
  `(if ,test (begin ,@body) ()))

(my-when (> x 5) (print "big"))
```

1. Look up `my-when` → `Value::Macro`
2. Expand: substitute arguments into macro body
3. Set `cur` to expanded expression
4. Continue loop (evaluate expanded form)

---

### Example 4: Agent Loop

```lisp
(react-loop "Create a folder" 5)
```

1. Build system prompt with tool descriptions
2. Call LLM (blocking via Tokio)
3. Parse response: extract ACTION/INPUT or FINAL
4. Execute tool or loop with observation

---

## Key Design Decisions

| Decision | Rationale | Trade-off |
|----------|-----------|----------|
| `Rc<RefCell<>>` for environments | Shared mutable state, handles closures | Runtime cost |
| Clone everything | Simplifies logic, avoids lifetimes | Performance |
| TCO trampoline | Stack-safe recursion, transparent to user | Extra complexity |
| Block on async LLM | Simpler state management | ~500ms latency |

---

## Performance Bottlenecks

1. **Repeated cloning** — Every expression/value cloned liberally
2. **Environment chain walks** — O(depth) variable lookup
3. **LLM calls** — Blocking thread for 100s of ms

---

## Subsystem Map (current, v0.25.0)

Everything the "Future Improvements" list above once promised has since
shipped (except Lean/Coq integration, deliberately replaced by self-built
verification — see ROADMAP's Design Constraint). The full system today:

| Subsystem | Where | One line |
|---|---|---|
| Evaluator (TCO trampoline) | `src/eval.rs` | every special form; tail calls rebind-and-continue |
| Environments + frame pool | `src/env.rs`, `src/arena.rs` | FxHash frames, recycled through a thread-local pool |
| Macros + hygiene | `src/eval.rs` | definition-time renaming of template-bound identifiers |
| Native codegen | `src/rust_jit.rs` | `defrust`/`defrust*` → rustc → dlopen; fixed C ABI |
| Graph IR + autodiff + fusion | `src/graph_ir.rs` | hash-consing CSE, fold, DCE; reverse-mode `backward`; `graph-compile`/`graph-compile-grad` kernels |
| Tensors | `src/env.rs`, `src/interp.rs` | flat row-major f64, Rc-backed |
| Static checkers | `src/type_check.rs`, `src/effect_check.rs` | conservative: only provable facts are flagged |
| Exhaustive oracle | `check-exhaustive` (`src/interp.rs`) | verification = ran on every domain point |
| Tracing | `src/trace.rs` | off-by-default event log; reports are pure data |
| Checkpoint/restore | `src/checkpoint.rs` | global env as loadable Lisp source |
| Model persistence | `src/interp.rs` | `save-model`/`load-model`, versioned JSON envelope |
| Actors | `std.lisp` | deterministic cooperative scheduler, pure Lisp |
| Proof loop / synthesis / prover | `std.lisp`, `synth.lisp`, `prover.lisp` | 2.1 gates → 4.2 CEGIS sketches → 4.3 tactics |
| Symbolic regression | `symreg.lisp` | GP over expression data; candidates compiled via `eval` |
| Control + safety | `robot.lisp` | deterministic loops; inductive safety via the oracle |
| Agent tools + ReAct | `agent-tools.lisp`, `src/eval.rs` | first-class tools; LLM output gated before running |
| Python bridge | `src/lib.rs` | PyO3; sessions replay history by design |

Semantics live in [SPEC.md](./SPEC.md); learning path in
[TUTORIAL.md](./TUTORIAL.md); per-subsystem design notes with measured
numbers in [ROADMAP.md](./ROADMAP.md)'s per-item annotations.

---

**Last updated:** July 2026 (v0.25.0) | [→ Full Roadmap](./ROADMAP.md)

☯
