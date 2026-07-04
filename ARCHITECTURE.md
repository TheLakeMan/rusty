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

**Key methods:**
- `Lexer::new(code: &str) → Self`
- `tokenize() → Vec<Token>` — Convert input to tokens, skipping whitespace & comments (`;`)

**Assumptions:**
- Comments start with `;` and extend to end of line
- Strings are double-quoted; backslash escapes work (`\"`, `\\`, `\n`)
- Numbers are parsed as `f64` (floating point)
- Symbols are case-sensitive identifiers

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

**Key methods:**
- `Parser::new(tokens: Vec<Token>) → Self`
- `parse() → Vec<Expr>` — Parse top-level expressions
- `parse_one() → Expr` — Parse a single expression (recursive descent)

**Parsing rules:**
- `(a b c)` → `List([a, b, c])`
- `'x` → `List([Symbol("quote"), Symbol("x")])`
- `` `x `` → `List([Symbol("quasiquote"), Symbol("x")])`
- `,x` → `List([Symbol("unquote"), Symbol("x")])`
- `,@x` → `List([Symbol("unquote-splicing"), Symbol("x")])`

**Error handling:** Returns string errors; panics are avoided.

---

### 3. Environment (`src/env.rs`)

**Purpose:** Manage lexical scoping, variable bindings, and closures.

**Key types:**
```rust
pub type Env = Rc<RefCell<EnvFrame>>;

pub struct EnvFrame {
    pub vars: HashMap<String, Value>,
    pub parent: Option<Env>,
}

pub enum Value {
    Number(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    List(Vec<Value>),
    Nil,
    Lambda {
        params: Vec<String>,
        rest: Option<String>,    // for `(lambda (x . rest) ...)`
        body: Vec<Expr>,
        env: Env,                // closure over definition environment
    },
    Macro {
        params: Vec<String>,
        rest: Option<String>,
        body: Vec<Expr>,
        env: Env,
    },
    Tool {
        name: String,
        description: String,
        params: Vec<String>,
        body: Vec<Expr>,
        env: Env,
    },
    Builtin(String, fn(&[Value]) -> Result<Value, String>),
}
```

**Key methods:**
- `EnvFrame::new(parent: Option<Env>) → Env` — Create a new scope
- `EnvFrame::get(env: &Env, name: &str) → Option<Value>` — Look up a variable (walks parent chain)
- `EnvFrame::set(env: &Env, name: String, value: Value)` — Bind a variable (shadows parent)
- `EnvFrame::set_existing(env: &Env, name: &str, value: Value) → bool` — Mutate existing binding; returns false if not found
- `EnvFrame::extend(env: &Env, params: &[String], rest: Option<&String>, args: Vec<Value>) → Result<Env, String>` — Create child env with parameters bound to arguments

**Design notes:**
- Environments use `Rc<RefCell<>>` for shared mutable state (interior mutability)
- Closures capture their definition environment (lexical scoping)
- `set!` mutates only if variable already exists (strict mode)
- `set` creates or mutates (SimpleLisp-style compatibility)

---

### 4. Evaluator (`src/eval.rs`)

**Purpose:** Execute expressions. The heart of Rusty.

**Key structure:**
```rust
pub struct Evaluator;

impl Evaluator {
    pub fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, String>
}
```

**Core algorithm: TCO Trampoline Loop**

```rust
pub fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, String> {
    let mut cur = expr.clone();
    let mut env = env.clone();

    loop {  // ← Trampoline: explicit loop for tail calls
        match &cur {
            // Base cases: return immediately
            Expr::Number(n) => return Ok(Value::Number(*n)),
            Expr::Symbol(s) => return EnvFrame::get(&env, s)
                .ok_or_else(|| format!("Undefined: '{}'", s)),
            
            // Special forms: set `cur` and `env` and `continue` (tail call)
            Expr::List(list) if head == "if" => {
                if is_truthy(&test_val) {
                    cur = list[2].clone();  // ← Tail call: set cur, continue
                } else {
                    cur = list[3].clone();
                }
                continue;  // ← Don't return; loop again
            }
            
            // Function call: evaluate args, bind params, set body as cur
            Expr::List(list) => {
                let func = self.eval(&list[0], &env)?;  // ← Not a tail call
                let args: Vec<Value> = list[1..]
                    .iter().map(|a| self.eval(a, &env)).collect::<Result<_, _>>()?;
                
                if let Value::Lambda { params, rest, body, env: cenv } = func {
                    let child = EnvFrame::extend(&cenv, &params, &rest, args)?;
                    let last = body.len() - 1;
                    for e in &body[..last] {
                        self.eval(e, &child)?;  // ← Side effects, discarded
                    }
                    cur = body[last].clone();  // ← Tail call
                    env = child;
                    continue;  // ← Tail call optimization!
                }
            }
        }
    }
}
```

**Why TCO matters:**
- Without TCO, recursive loops (like `(sum-to 1000000 0)`) would overflow the stack
- By using an explicit loop and setting `cur` instead of recursing, we simulate tail calls
- The Rust function stack never grows; only `cur` and `env` change

**Special Forms Implemented:**

| Form | Handling |
|------|----------|
| `if` | Evaluate test, set `cur` to then/else, continue |
| `begin` | Evaluate all but last, set `cur` to last, continue |
| `lambda` | Create `Value::Lambda` with closure |
| `define` / `def` | Bind in environment, return `Nil` |
| `set!` | Mutate existing binding or error |
| `let` / `let*` / `letrec` | Create child env, evaluate bindings, continue |
| `defmacro` | Create `Value::Macro` |
| Macro invocation | Expand (evaluate macro body with args), set `cur` to result, continue |
| `deftool` | Create `Value::Tool` with captured environment |
| `tool-call` | Look up tool, call it, continue with result |
| `react-loop` | Multi-step agent loop (calls LLM, parses ACTION, executes tools) |
| `llm` | Async call to OpenAI-compatible API on localhost:8080 |

**Async handling:**
- LLM calls are blocking via `tokio::runtime::Runtime::block_on()`
- Not ideal for production; future improvement: make evaluator async

---

### 5. Interpreter (`src/interp.rs`)

**Purpose:** Builtin functions, stdlib management, and shared evaluation entry point.

**Key structure:**
```rust
pub fn make_env() -> Env {
    // Create global environment with 60+ builtins
    // Auto-load std.lisp
}

pub fn run_code(code: &str, env: &Env, eval: &Evaluator) -> Result<Value, String> {
    let tokens = lexer::Lexer::new(code).tokenize();
    let ast = parser::Parser::new(tokens).parse();
    eval.eval_all(&ast, env)
}
```

**Builtins (~60 functions):**
- **Arithmetic:** `+`, `-`, `*`, `/`, `mod`, `abs`, `sqrt`, `floor`, `ceiling`
- **Comparison:** `=`, `<`, `>`, `<=`, `>=`, `eq?`, `equal?`, `not`
- **Lists:** `cons`, `car`, `cdr`, `list`, `length`, `append`, `map`, `filter`, `foldl`, `foldr`
- **Strings:** `string-append`, `substring`, `string-length`, `format`, `string->number`, etc.
- **I/O:** `print`, `println`, `display`, `error`
- **Type checking:** `number?`, `string?`, `list?`, `symbol?`, `procedure?`, etc.
- **Filesystem:** `file-read`, `file-write`, `file-append`, `file-exists?`, `dir-create`, `dir-list`
- **Shell:** `shell` (run arbitrary shell command, capture output)
- **JSON:** `json-encode`, `json-decode`
- **Symbols:** `gensym`, `symbol->string`, `string->symbol`

**Standard Library (`std.lisp`):**
Automatically loaded on startup. Provides ~230 lines of Lisp utilities:
- Math helpers: `square`, `cube`, `inc`, `dec`, `average`, `clamp`
- List utilities: `last`, `flatten`, `zip`, `take`, `drop`, `range`, `iota`
- Functional: `compose`, `curry`, `identity`, `flip`, `memoize`
- Macros: `->`, `->>`, `dotimes`, `dolist`, `while`, `repeat`, `swap!`

---

### 6. Python Bridge (`src/lib.rs`)

**Purpose:** Expose Rusty to Python via PyO3.

**Key classes:**
```rust
#[pyclass(name = "Rusty")]
pub struct RustyInterp;  // Stateless

#[pyclass]
pub struct RustySession;  // Stateful
```

**Usage:**
```python
import rusty

# Stateless
print(rusty.eval("(+ 1 2)"))  # "3"

# Stateful
s = rusty.RustySession()
s.eval("(define (f x) (+ x 1))")
print(s.eval("(f 41)"))  # "42"
```

**Implementation detail:**
- `RustySession` stores a history of code strings
- Each `eval()` replays all history into a fresh environment
- Safe (no mutable state across thread boundaries) but not optimized for memory

---

## Data Flow Examples

### Example 1: Simple Expression

```lisp
(+ 1 2)
```

1. **Lexer:** `+ 1 2` → `[Symbol("+"), Number(1.0), Number(2.0)]`
2. **Parser:** `[Symbol("+"), Number(1.0), Number(2.0)]` → `List([Symbol("+"), Number(1.0), Number(2.0)])`
3. **Evaluator:**
   - Eval `Symbol("+")` → `Value::Builtin("+")`
   - Eval `Number(1.0)` → `Value::Number(1.0)`
   - Eval `Number(2.0)` → `Value::Number(2.0)`
   - Call builtin `+` with `[Number(1.0), Number(2.0)]`
   - Return `Value::Number(3.0)`

---

### Example 2: Tail-Call Recursion

```lisp
(define (sum-to n acc)
  (if (<= n 0) acc
      (sum-to (- n 1) (+ acc n))))

(sum-to 1000000 0)
```

1. **Evaluator:**
   - `sum-to` is bound as a `Lambda` in global env
   - Call `sum-to` with `[1000000, 0]`
   - Create child env: `{n: 1000000, acc: 0}`
   - Evaluate body (if test):
     - Test: `(<= 1000000 0)` → `false`
     - Set `cur = (sum-to (- 1000000 1) (+ 0 1000000))`
     - Set `env = child`
     - **Continue loop** (not recurse!)
   - Repeat ~1M times, never growing the Rust stack

---

### Example 3: Macro Expansion

```lisp
(defmacro my-when (test . body)
  `(if ,test (begin ,@body) ()))

(my-when (> x 5) (print "big") (+ x 1))
```

1. **Parser:** Sees `(my-when ...)`
2. **Evaluator:**
   - Look up `my-when` → `Value::Macro { params: [test], rest: Some(body), ... }`
   - Arguments (not evaluated): `[(> x 5), (print "big"), (+ x 1)]`
   - Expand macro:
     - Create macro env: `{test: (> x 5), body: [(print "big"), (+ x 1)]}`
     - Evaluate macro body (the quasiquote)
     - Substitute: `` `(if ,test (begin ,@body) ()) `` → `(if (> x 5) (begin (print "big") (+ x 1)) ())`
   - Set `cur` to expanded expression
   - Continue loop (evaluate expanded form)

---

### Example 4: Tool Call & Agent Loop

```lisp
(deftool create-dir (path)
  "Create a directory"
  (shell (format "mkdir -p ~a" path)))

(react-loop "Create a folder called data" 5)
```

1. **Tool Registration:**
   - `deftool` creates `Value::Tool { name: "create-dir", params: ["path"], body: [...], env: <current_env> }`
   - Stored in environment under key `"create-dir"`

2. **Agent Loop (react-loop):**
   - **Step 1:** Build system prompt with tool descriptions (calls `list-tools`)
   - **Step 2:** Call LLM with goal + tool list
   - **Step 3:** Parse LLM response:
     - If contains `FINAL:` → return result
     - If contains `ACTION:` → extract tool name + input
   - **Step 4:** Look up tool in environment
   - **Step 5:** Execute: create child env, bind params, eval tool body
   - **Step 6:** Capture observation (tool result)
   - **Step 7:** Feed back to LLM history, loop

---

## Key Design Decisions

### 1. Why `Rc<RefCell<EnvFrame>>`?

**Choice:** Use reference-counted interior mutability for environments.

**Rationale:**
- Multiple closures capture the same defining environment (shared ownership)
- Environments are mutated during `define`/`set!` (interior mutability)
- Avoids complex lifetime management and borrowing issues
- Trade-off: Slight runtime cost for GC + RefCell borrow checks

**Alternative:** Immutable environments with tree-structured updates (faster, harder to implement)

---

### 2. Why Clone Everything?

**Choice:** Clone expressions, environments, and values liberally.

**Rationale:**
- Simplifies evaluation logic (no lifetime annotations)
- Avoids complex borrow checker constraints
- Small expressions/values are cheap to clone
- Production optimization: Implement copy-on-write or persistent data structures

**Alternative:** Optimize with Rc<> wrapper around expensive data (future work)

---

### 3. Why Async Tokio Instead of Native Async/Await Evaluator?

**Choice:** Block current thread with `tokio::runtime::block_on()` for LLM calls.

**Rationale:**
- Evaluator logic remains synchronous (simpler to reason about)
- LLM latency is high anyway (100s of ms); thread blocking is acceptable
- Easier to serialize/checkpoint agent state

**Alternative:** Make evaluator fully async, but complicates the entire stack

---

### 4. Why TCO Trampoline Instead of Rust Recursion?

**Choice:** Explicit loop in `eval()` instead of recursive function calls.

**Rationale:**
- Rust stack is limited; deep recursion causes overflow
- Lisp traditionally supports unlimited recursion
- Trampoline is idiomatic for implementing TCO
- Transparent to user (no special syntax needed)

**Alternative:** Increase stack size (hacky, not portable)

---

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Variable lookup | O(depth) | Walks environment chain |
| Function call | O(1) | Just environment frame creation |
| List operations | O(n) | Standard functional list costs |
| Macro expansion | O(m) | m = macro body size |
| Tool lookup | O(1) | Hash table in environment |
| LLM call | O(1) | Actually ~500ms network latency |

**Bottlenecks:**
1. **Repeated cloning** — Every expression, every value, every environment is cloned liberally
2. **Environment chain walks** — Deep variable lookup can be slow
3. **Async LLM calls** — Blocking thread for 100s of ms

---

## Future Improvements

### Short-term (Phase 1)
- [ ] Implement `eval-when` for compile-time evaluation
- [ ] Add symbolic differentiation as macros
- [ ] Build computation graph IR prototype

### Medium-term (Phase 2)
- [ ] Gradual typing (optional type annotations)
- [ ] Lean/Coq formal verification integration
- [ ] JIT compilation for hot functions

### Long-term (Phase 3+)
- [ ] Persistent data structures (reduce cloning)
- [ ] Truly async evaluator
- [ ] Distributed agent orchestration

---

## Related Work

- **Scheme/Racket:** Influenced TCO design and macro system
- **Clojure:** Inspired Python bridge design
- **Lean 4:** Goal for formal verification integration
- **TVM/XLA:** Inspiration for computation graph IR

---

**Last updated:** July 2026

🦀
