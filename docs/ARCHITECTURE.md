# Rusty Architecture Guide

Comprehensive documentation of Rusty's internal design, implementation patterns, and extension points.

---

## Table of Contents

1. [Pipeline Overview](#pipeline-overview)
2. [Module Breakdown](#module-breakdown)
3. [Core Data Structures](#core-data-structures)
4. [Tail Call Optimization](#tail-call-optimization)
5. [Environment & Scoping](#environment--scoping)
6. [Special Forms](#special-forms)
7. [Adding New Features](#adding-new-features)
8. [Testing Strategy](#testing-strategy)

---

## Pipeline Overview

Rusty follows a classic interpreter pipeline:

```
Input (REPL or file)
    ↓
[Lexer] → Tokenize
    ↓
Tokens: Vec<Token>
    ↓
[Parser] → Parse S-expressions
    ↓
AST: Vec<Expr>
    ↓
[Evaluator] → Interpret (with TCO loop)
    ↓
Value: Result<Value, String>
    ↓
Output (REPL prints or file result)
```

### Entry Points

**File-based execution** (`src/main.rs`):
```rust
let code = std::fs::read_to_string(&args[1])?;
let tokens = Lexer::new(code).tokenize();
let ast = Parser::new(tokens).parse();
let result = eval.eval_all(&ast, &global);
```

**REPL** (`src/main.rs`):
```rust
loop {
    readline(prompt) → buffer
    check_complete(&buffer) → InputStatus
    if Complete:
        tokens = Lexer::new(&buffer).tokenize()
        ast = Parser::new(tokens).parse()
        result = eval.eval_all(&ast, &global)
        println!("{}", result)
}
```

---

## Module Breakdown

### 1. **Lexer** (`src/lexer.rs`)

**Purpose:** Convert source string → sequence of tokens.

**Token Types:**
```rust
pub enum Token {
    LParen, RParen,                // ( )
    Quote, Quasiquote,             // ' `
    Unquote, UnquoteSplice,        // , ,@
    Number(f64),                   // 42, 3.14, -5
    Bool(bool),                    // #t, #f
    String(String),                // "hello"
    Symbol(String),                // x, foo-bar, +
    EOF,
}
```

**Key Functions:**
- `Lexer::new(input: &str)` — Initialize with source
- `tokenize()` — Consume input, return token stream

**Parsing Rules:**
- **Whitespace:** Skipped (space, tab, newline, carriage return)
- **Comments:** `;` to end-of-line
- **Numbers:** `\d+\.?\d*` or `-\d+\.?\d*` (floats)
- **Strings:** `"..."` with escape sequences (`\n`, `\t`, `\r`, `\\`, `\"`)
- **Symbols:** Any sequence of non-whitespace, non-special chars
- **Special chars:** `(`, `)`, `'`, `` ` ``, `,`, `@` (for ``,@``)
- **Booleans:** `#t` (true), `#f` (false)

**String Escaping:**
```rust
loop {
    match self.advance() {
        None | Some('"') => break,         // End of string
        Some('\\') => match self.advance() {
            Some('n') => s.push('\n'),
            Some('t') => s.push('\t'),
            Some('r') => s.push('\r'),
            Some(c) => s.push(c),          // Pass through other escapes
            None => break,
        }
        Some(c) => s.push(c),              // Regular char
    }
}
```

### 2. **Parser** (`src/parser.rs`)

**Purpose:** Convert tokens → Abstract Syntax Tree (AST).

**AST Representation:**
```rust
pub enum Expr {
    Number(f64),                   // 42
    Bool(bool),                    // #t, #f
    String(String),                // "hello"
    Symbol(String),                // foo
    List(Vec<Expr>),               // (+ 1 2)
    Nil,                           // ()
}
```

**Parsing Logic:**
- **Recursive descent** — Each `parse_expr()` call consumes one top-level form
- **Prefix operators:** `'`, `` ` ``, `,`, `,@` expand to lists
  - `'x` → `(quote x)`
  - `` `x `` → `(quasiquote x)`
  - `,x` → `(unquote x)`
  - `,@x` → `(unquote-splicing x)`
- **Lists:** `(...)` parsed as `Vec<Expr>`
- **Multi-form files:** `parse()` repeatedly calls `parse_expr()` until EOF

**Example Parsing:**
```lisp
(+ 1 2)
↓
Tokens: [LParen, Symbol("+"), Number(1), Number(2), RParen, EOF]
↓
Expr::List([
  Expr::Symbol("+"),
  Expr::Number(1.0),
  Expr::Number(2.0),
])
```

### 3. **Environment** (`src/env.rs`)

**Purpose:** Manage variable bindings and lexical scoping.

**Data Structure:**
```rust
pub type Env = Rc<RefCell<EnvFrame>>;

pub struct EnvFrame {
    vars: HashMap<String, Value>,      // Local bindings
    parent: Option<Env>,                // Link to parent scope
}
```

**Why `Rc<RefCell<>>?`**
- **`Rc`** (reference counting) — Multiple closures can share the same environment
- **`RefCell`** — Interior mutability; allows borrowing environment without `&mut`
- **Linked list of frames** — Each scope points to its parent for lexical lookup

**Key Operations:**

```rust
// Create new top-level environment
EnvFrame::new(None) → Env

// Lookup a variable (walks up parent chain)
EnvFrame::get(env, "x") → Option<Value>

// Create or update local binding
EnvFrame::set(env, "x", value)

// Update existing binding (error if not found)
EnvFrame::set_existing(env, "x", value) → bool

// Extend environment with new frame (for function calls)
EnvFrame::extend(parent, params, rest, args) → Result<Env, String>
```

**Closure Capture:**
```lisp
(def make-adder (n)
  (lambda (x) (+ x n)))

(def add5 (make-adder 5))
```

When `(make-adder 5)` is called:
1. Create child environment with `n=5`
2. Evaluate `(lambda (x) (+ x n))`
3. Lambda captures **reference** to this environment
4. Later, `(add5 10)` creates new child, but can still see `n=5` via parent chain

**Mutation:**
```rust
(set! x 42)  // Error if x not in current scope or parents
(set x 42)   // Create or update x in current scope
```

### 4. **Evaluator** (`src/eval.rs`)

**Purpose:** Execute AST, implementing language semantics and TCO.

**Core Loop:**
```rust
pub fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, String> {
    let mut cur = expr.clone();
    let mut env = env.clone();
    
    loop {  // ← TCO: trampoline instead of recursion
        match &cur {
            Expr::Number(n) => return Ok(Value::Number(*n)),
            Expr::Bool(b) => return Ok(Value::Bool(*b)),
            
            Expr::Symbol(s) => {
                return EnvFrame::get(&env, s)
                    .ok_or_else(|| format!("Undefined: '{}'", s));
            }
            
            Expr::List(list) => {
                if list.is_empty() { return Ok(Value::Nil); }
                
                // Check for special forms
                if let Expr::Symbol(head) = &list[0] {
                    match head.as_str() {
                        "if" => {
                            let test = self.eval(&list[1], &env)?;
                            cur = if is_truthy(&test) {
                                list[2].clone()
                            } else if list.len() > 3 {
                                list[3].clone()
                            } else {
                                return Ok(Value::Nil);
                            };
                            continue;  // ← Loop, don't recurse!
                        }
                        // ... other special forms ...
                        _ => {}
                    }
                }
                
                // Regular function call
                let func = self.eval(&list[0], &env)?;
                let args: Result<Vec<_>, _> = list[1..]
                    .iter()
                    .map(|a| self.eval(a, &env))
                    .collect();
                
                match func {
                    Value::Builtin(_, f) => return f(&args?),
                    Value::Lambda { params, body, env: cenv, .. } => {
                        let child = EnvFrame::extend(&cenv, &params, &None, args?)?;
                        cur = body[last].clone();
                        env = child;
                        continue;  // ← Loop, don't recurse!
                    }
                    _ => return Err(format!("Not callable: {}", func)),
                }
            }
        }
    }
}
```

**Special Forms** (evaluated specially, not as function calls):
- `quote` — Return literal data without evaluation
- `quasiquote`, `unquote`, `unquote-splicing` — Template meta-programming
- `if` — Conditional (lazy in branches)
- `cond` — Multi-branch conditional
- `and`, `or` — Short-circuit logic
- `define`, `def` — Bind names
- `set!`, `set` — Mutate bindings
- `lambda` — Create function
- `begin` — Sequence expressions
- `let`, `let*`, `letrec` — Local scope
- `when`, `unless` — Conditional do-or-not
- `do` — Loop construct
- `defmacro` — Create macro

**Macro Expansion:**
```rust
if let Some(Value::Macro { params, rest, body, env: mac_env }) = 
    EnvFrame::get(&env, s)
{
    // Evaluate macro body in macro's environment with unevaluated args
    let arg_vals: Vec<Value> = list[1..].iter().map(expr_to_value).collect();
    let mac_child = EnvFrame::extend(&mac_env, &params, &rest, arg_vals)?;
    
    // Run macro body, get result
    let expanded = self.eval(&body[last], &mac_child)?;
    
    // Convert result back to Expr and re-evaluate
    cur = value_to_expr(&expanded);
    continue;  // Loop evaluates the expanded form
}
```

### 5. **Main & Builtins** (`src/main.rs`)

**Purpose:** REPL, I/O, and ~100 built-in functions.

**Builtin Structure:**
```rust
Value::Builtin(&'static str, fn(&[Value]) -> Result<Value, String>)
```

**Builtin Categories:**
- **Arithmetic:** `+`, `-`, `*`, `/`, `mod`, `expt`, `abs`, `sqrt`, etc.
- **Comparison:** `=`, `<`, `>`, `<=`, `>=`, `eq`, `not`, etc.
- **Lists:** `cons`, `car`, `cdr`, `list`, `length`, `append`, `reverse`, `map`, `filter`
- **Strings:** `string-length`, `string-append`, `substring`, `string-ref`, `string=?`
- **Type predicates:** `number?`, `string?`, `list?`, `procedure?`, etc.
- **I/O:** `print`, `display`, `newline`, `error`
- **Conversions:** `number->string`, `string->number`, `symbol->string`, etc.

**Example Builtin:**
```rust
b!("map", |args| {
    if args.len() != 2 { return Err("map: 2 args".into()); }
    let xs = match &args[1] {
        Value::List(xs) => xs.clone(),
        Value::Nil => return Ok(Value::List(vec![])),
        _ => return Err("map: second arg must be a list".into()),
    };
    let eval = Evaluator::new();
    let result: Result<Vec<Value>, _> = xs.iter()
        .map(|x| apply_value(&args[0], &[x.clone()], &eval))
        .collect();
    Ok(Value::List(result?))
});
```

---

## Core Data Structures

### Value Enum

```rust
pub enum Value {
    Number(f64),                              // 42, 3.14
    Bool(bool),                               // #t, #f
    String(String),                           // "hello"
    Symbol(String),                           // 'x, 'foo
    List(Vec<Value>),                         // (1 2 3)
    Builtin(&'static str, fn(&[Value]) -> Result<Value, String>),
    Lambda {
        params: Vec<String>,                  // ("x" "y")
        rest: Option<String>,                 // Some("args") for (x y . args)
        body: Vec<Expr>,                      // [(+ x y)]
        env: Env,                             // Captured closure
    },
    Macro {
        params: Vec<String>,
        rest: Option<String>,
        body: Vec<Expr>,
        env: Env,                             // Macro definition env
    },
    Nil,                                      // ()
}
```

### Expr Enum (AST)

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

## Tail Call Optimization

### Why TCO Matters

Without TCO, deep recursion overflows the stack:
```lisp
(def sum-to (n)
  (if (<= n 0) 0 (+ n (sum-to (- n 1)))))
(sum-to 100000)  ; Stack overflow!
```

### How Rusty Does It

**Key insight:** Instead of recursive function calls, use a **trampoline loop**:

```rust
loop {
    match expr {
        // Base cases: return immediately
        Expr::Number(_) => return Ok(...),
        
        // Control flow: continue loop, don't recurse
        Expr::List(list) if head == "if" => {
            cur = consequent_or_alternative;
            continue;  // ← Loop instead of recurse!
        }
        
        // Function call in tail position: reuse loop
        Expr::List(list) => {
            match func {
                Value::Lambda { body, env: cenv, .. } => {
                    cur = body[last];   // New expression to eval
                    env = child_env;    // New environment
                    continue;           // ← Loop again, don't recurse!
                }
            }
        }
    }
}
```

### Requirements for TCO

1. **Tail position detection:** Only the last expression in a sequence is tail-recursive
   - `(begin a b c)` — only `c` is in tail position
   - `(if test a b)` — both `a` and `b` are in tail position

2. **Loop continuation:** Instead of `return self.eval(...)`, use `cur = ...; continue;`

3. **Environment threading:** Pass environment through loop, don't nest it via call stack

### Stack-Safe Recursion Example

```lisp
(def sum-list (xs acc)
  (if (null? xs)
      acc
      (sum-list (cdr xs) (+ acc (car xs)))))

(sum-list '(1 2 3 4 5) 0)  ; → 15, no stack growth
```

Even with a million-element list, stack depth stays constant because each recursive call is in tail position and uses the loop.

---

## Environment & Scoping

### Lexical Scoping

Rusty implements **lexical (static) scoping**: variables are resolved based on where they're defined, not where they're called.

```lisp
(def x 10)

(def make-adder (n)
  (lambda (y) (+ x y)))

(def my-adder (make-adder 5))

(let ((x 100))
  (my-adder 1))  ; → 11, not 101!
```

Why? `my-adder` captures the **global environment** where `x=10`, not the `let` scope where `x=100`.

### Closure Capture

When a lambda is created, it captures a reference to the **current environment**:

```lisp
(def make-counter ()
  (let ((count 0))
    (lambda ()
      (set! count (+ count 1))
      count)))

(def c (make-counter))
(c)  ; → 1
(c)  ; → 2
(c)  ; → 3
```

Each call to `c`:
1. Extends captured environment with empty params
2. Evaluates body `(set! count (+ count 1))`
3. `set!` mutates the **captured** `count`, not a local one
4. Multiple closures from same `make-counter` share the same `count` cell

### Variable Shadowing

Inner scopes can hide outer ones:

```lisp
(def x 10)

(let ((x 20))
  (print x))  ; Prints 20

(print x)  ; Prints 10
```

Lookup walks up the parent chain and stops at the first match.

---

## Special Forms

### Quote (`quote`, `'`)

Returns literal data without evaluation:

```lisp
(quote (+ 1 2))  ; → (+ 1 2), not 3
'(+ 1 2)          ; Same
```

### Quasiquote (`` ` ``)

Template syntax for code generation:

```lisp
(def x 5)
`(+ x 1)                    ; → (+ x 1)
`(+ ,x 1)                   ; → (+ 5 1)
`(+ ,@(list 1 2) 3)         ; → (+ 1 2 3)
```

**Rules:**
- `,expr` — Unquote: evaluate and splice the result
- `,@expr` — Unquote-splicing: evaluate and splice list elements

### If

```lisp
(if test consequent alternate)
(if (> x 5) "big" "small")
```

Lazily evaluates only the branch taken.

### Cond

Multi-branch conditional:

```lisp
(cond
  ((< x 0) "negative")
  ((= x 0) "zero")
  ((> x 0) "positive")
  (else "error"))
```

Short-circuits on first true condition.

### Let / Let* / Letrec

**`let`** — Parallel bindings (all evaluated in outer scope):
```lisp
(let ((x 1) (y 2)) (+ x y))
; Equivalent to: ((lambda (x y) (+ x y)) 1 2)
```

**`let*`** — Sequential bindings (each sees previous):
```lisp
(let* ((x 1) (y (+ x 1))) y)  ; y = 2
```

**`letrec`** — Recursive bindings (can reference each other):
```lisp
(letrec ((fact (lambda (n) (if (<= n 1) 1 (* n (fact (- n 1)))))))
  (fact 5))
```

### Do Loop

```lisp
(do ((i 0 (+ i 1)))         ; Variables: (var init step)
    ((>= i 10) i)           ; Test clause and result
  (print i))                ; Body
```

Runs body in a loop, updating variables by step each iteration.

---

## Adding New Features

### Adding a Builtin Function

**1. Write the function in `src/main.rs` in `setup_builtins()`:**

```rust
b!("my-func", |args| {
    if args.len() != 2 { return Err("my-func: 2 args".into()); }
    match (&args[0], &args[1]) {
        (Value::Number(a), Value::Number(b)) => {
            Ok(Value::Number(a + b))
        }
        _ => Err("my-func: expected numbers".into())
    }
});
```

**2. Add tests in `new-features.lisp`:**

```lisp
(assert-equal 7 (my-func 3 4) "my-func basic")
(assert-true
  (try-error (my-func "x" 1))
  "my-func type check")
```

**3. Update README.md** with example and documentation.

### Adding a Special Form

**1. Add a new arm to the match in `eval()` in `src/eval.rs`:**

```rust
"my-form" => {
    if list.len() < 2 { return Err("my-form: needs args".into()); }
    let result = self.eval(&list[1], &env)?;
    // Do something
    cur = list[2].clone();
    continue;  // ← Important for TCO!
}
```

**2. Add to the special forms check** (before macro/function call):

```rust
if let Expr::Symbol(head) = &list[0] {
    match head.as_str() {
        "my-form" => { ... }
        "if" => { ... }
        _ => {}  // Falls through to macro/function call
    }
}
```

**3. Add tests and documentation.**

### Adding a Type to Value

**1. Add variant to `Value` enum in `src/env.rs`:**

```rust
pub enum Value {
    // ...
    MyType { field1: String, field2: i32 },
}
```

**2. Add `Display` implementation:**

```rust
impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Value::MyType { field1, field2 } => {
                write!(f, "#<mytype {} {}>", field1, field2)
            }
            // ...
        }
    }
}
```

**3. Add conversion helpers if needed:**

```rust
pub fn expr_to_value(e: &Expr) -> Value { /* ... */ }
pub fn value_to_expr(v: &Value) -> Expr { /* ... */ }
```

---

## Testing Strategy

### Test File Organization

- **`tests.lisp`** — Core regression tests (arithmetic, lists, closures, recursion)
- **`new-features.lisp`** — Advanced features (let forms, macros, type predicates)
- **`hello.lisp`** — Simple integration test

### Running Tests

```bash
./run_tests.sh
```

This:
1. Compiles Rusty (`cargo build --release`)
2. Runs `hello.lisp`, captures output
3. Compares to `expected_hello.txt`
4. Runs `tests.lisp`, compares to `expected_tests.txt`
5. Runs `new-features.lisp`, compares to `expected_new.txt`

### Writing a Test

```lisp
(def assert-equal (expected actual label)
  (if (eq expected actual)
      (print label)
      (begin
        (print "FAIL:" label)
        (print "  expected" expected)
        (print "  got" actual)
        (div 1 0))))  ; Crash on failure

(assert-equal 42 (my-func 20 22) "my-func test")
```

### Updating Expected Output

After adding/modifying tests, regenerate expected files:

```bash
cargo run --release -- tests.lisp > expected_tests.txt
cargo run --release -- new-features.lisp > expected_new.txt
```

Then commit both the test and expected file.

---

## Performance Considerations

### Current Bottlenecks

1. **AST interpretation** — No bytecode compilation
2. **Environment lookup** — Hash table lookup + parent chain walk
3. **Allocation** — Every value boxed in `Value` enum
4. **Cloning** — Expr and Env cloned frequently

### Optimization Opportunities

1. **Bytecode compilation** — Compile AST to bytecode, interpret bytecode
2. **Inline caching** — Cache environment lookups
3. **Value tagging** — Use tagged pointers instead of enum boxing
4. **Persistent data structures** — More efficient list/environment sharing
5. **JIT compilation** — Compile hot paths to native code (hard, requires `cranelift` or similar)

### When to Optimize

Focus on correctness first. Only optimize after profiling to identify real bottlenecks.

---

## Design Principles

1. **Simplicity over performance** — Easy to understand and modify
2. **Correctness over features** — Better to have few features that work than many broken ones
3. **Lisp philosophy** — Data is code, code is data (homoiconicity via S-expressions)
4. **TCO always** — Never grow the stack, even for deep recursion
5. **Lexical scoping** — Predictable variable resolution

---

## Further Reading

- **Scheme specification** — R5RS / R7RS for reference semantics
- **Crafting Interpreters** — "craftinginterpreters.com" for general interpreter techniques
- **SICP** — "Structure and Interpretation of Computer Programs" for Lisp semantics
