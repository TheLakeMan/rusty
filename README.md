# Rusty — A Modern Lisp in Rust

A complete, feature-rich Lisp interpreter implemented in Rust, ported from a Python prototype. Designed for **AI scripting**, **game logic**, and **symbolic reasoning** with first-class support for tail-call optimization, hygienic macros, and closures.

**Version:** 0.9.2 | **Status:** Production-ready REPL, full core language support

---

## Quick Start

### Build & Run
```bash
# Build
cargo build --release

# Interactive REPL
cargo run

# Run a Lisp file
cargo run -- path/to/script.lisp
```

### Hello, Rusty
```lisp
(print "Hello, Rusty!")
(def add-nums (x y) (+ x y))
(print (add-nums 5 3))
```

---

## Language Features

### Core Language
- **Lexical Scoping & Closures** — Full closure capture with lexical environments
- **Tail Call Optimization (TCO)** — Stack-safe recursion via explicit loop
- **Hygienic Macros** — `defmacro` with proper variable hygiene
- **Quasiquote & Unquote** — Template-based meta-programming (`` ` ,, ,@ ``)
- **First-class Functions** — `lambda`, `define`, `def`, `apply`
- **Pattern Recognition** — `quote`, `cond`, `match`-like constructs

### Control Flow
```lisp
(if test then-expr else-expr)
(cond (test1 expr1) (test2 expr2) (else expr3))
(and a b c)
(or a b c)
(when test body...)
(unless test body...)
(begin e1 e2 ... en)
(do ((var init step)...) (test result...) body...)
```

### Data Binding
```lisp
(define x 42)                          ; bind x
(def square (n) (* n n))              ; define function
(set! x 43)                            ; mutate existing binding
(set x 44)                             ; create or update
(let ((x 1) (y 2)) (+ x y))           ; local bindings, evaluated in outer scope
(let* ((x 1) (y (+ x 1))) y)          ; sequential, each sees previous
(letrec ((f (lambda (n) ...))) ...)    ; recursive, sees self
(lambda (x y . rest) body...)          ; rest parameters
```

### Arithmetic (Scheme-style + SimpleLisp aliases)
```lisp
(+ 1 2 3)        ; addition (also: add)
(- 5 2)          ; subtraction (also: sub)
(* 3 4)          ; multiplication (also: mul)
(/ 10 2)         ; division (also: div)
(mod 10 3)       ; modulo
(expt 2 8)       ; exponentiation
(abs -5)         ; absolute value
(sqrt 16)        ; square root
(floor 3.7)      ; floor
(ceiling 3.2)    ; ceiling
(round 3.5)      ; round
(max 1 5 3)      ; maximum
(min 1 5 3)      ; minimum
(gcd 12 8)       ; greatest common divisor
```

### Comparisons (Scheme-style + SimpleLisp aliases)
```lisp
(= 3 3)          ; numeric equality (also: eq for all types)
(< 3 5)          ; less than (also: lt)
(> 5 3)          ; greater than (also: gt)
(<= 3 3)         ; less-or-equal (also: le)
(>= 3 3)         ; greater-or-equal (also: ge)
(/= 3 4)         ; not-equal
(not #f)         ; logical NOT → #t
(zero? 0)        ; is zero?
(positive? 5)    ; is positive?
(negative? -3)   ; is negative?
(odd? 5)         ; is odd?
(even? 4)        ; is even?
```

### Lists (Immutable)
```lisp
(list 1 2 3)                           ; construct list
(cons 0 '(1 2))                        ; prepend element
(car '(1 2 3))                         ; head (1)
(cdr '(1 2 3))                         ; tail ((2 3))
(length '(1 2 3))                      ; length (3)
(append '(1 2) '(3 4))                 ; concat ((1 2 3 4))
(reverse '(1 2 3))                     ; reverse ((3 2 1))
(nth '(a b c) 1)                       ; index (b)
(member 2 '(1 2 3))                    ; membership check (#t)
(list-tail '(1 2 3) 1)                 ; skip n ((2 3))

; List predicates
(null? '())                            ; empty?
(pair? '(1))                           ; non-empty list?
(list? '(1 2))                         ; is a list?
```

### Higher-Order Functions
```lisp
(map (lambda (x) (* x 2)) '(1 2 3))    ; ((2 4 6))
(filter (lambda (x) (> x 2)) '(1 2 3)); ((3))
(foldl (lambda (acc x) (+ acc x)) 0 '(1 2 3))  ; left fold (6)
(foldr (lambda (x acc) (+ x acc)) 0 '(1 2 3))  ; right fold (6)
(for-each (lambda (x) (print x)) '(1 2 3))     ; iterate (side effects)
(apply + '(1 2 3))                     ; call with arg list (6)
```

### Strings
```lisp
(string-length "hello")                ; length (5)
(string-append "hello" " " "world")    ; concat ("hello world")
(substring "hello" 1 4)                ; slice ("ell")
(string-ref "hello" 0)                 ; char at index ("h")
(string=? "a" "a")                     ; equality (#t)
(number->string 42)                    ; convert ("42")
(string->number "42")                  ; parse (42 or #f)
(symbol->string 'x)                    ; symbol to string ("x")
(string->symbol "x")                   ; string to symbol (x)
(string->list "ab")                    ; explode (("a" "b"))
```

### Type Predicates
```lisp
(number? 42)                           ; is number?
(string? "hello")                      ; is string?
(boolean? #t)                          ; is boolean?
(symbol? 'x)                           ; is symbol?
(list? '(1 2))                         ; is list?
(procedure? (lambda (x) x))            ; is callable?
(nil? '())                             ; is nil/empty?
```

### I/O
```lisp
(print "hello" 42 x)                   ; print with spaces, newline
(display "no newline")                 ; no newline
(newline)                              ; print newline
(error "message")                      ; raise error
```

### Macros (Hygienic)
```lisp
(defmacro inc (x)
  `(+ ,x 1))

(inc 5)  ; → 6

(defmacro when (test body)
  `(if ,test (begin ,@body)))

(when (> x 5)
  (print "big")
  (set! x 0))
```

---

## Architecture

### How Rusty Works

```
Source Code (.lisp file or REPL input)
    ↓ [Lexer: src/lexer.rs]
Tokens (LParen, Symbol, Number, String, etc.)
    ↓ [Parser: src/parser.rs]
AST (Expr enum: Number, Symbol, List, etc.)
    ↓ [Evaluator: src/eval.rs + TCO Loop]
Value (Number, String, Lambda, List, etc.)
    ↓ [Environment: src/env.rs]
Lexical scopes, closures, mutations
```

### Key Files

| File | Purpose | Lines |
|------|---------|-------|
| **src/main.rs** | REPL, 100+ builtins, I/O | 568 |
| **src/eval.rs** | Evaluator, TCO loop, special forms | 483 |
| **src/env.rs** | Environment frames, scoping | 121 |
| **src/parser.rs** | S-expression parser | 79 |
| **src/lexer.rs** | Tokenizer | 105 |

### Tail Call Optimization

Rusty implements TCO via an explicit **trampoline loop** in the evaluator:

```rust
pub fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, String> {
    let mut cur = expr.clone();
    let mut env = env.clone();
    
    loop {
        match &cur {
            // Base cases return immediately
            Expr::Number(n) => return Ok(Value::Number(*n)),
            
            // Control flow (if, begin, etc.) continue the loop
            // instead of recursing — this avoids stack growth
            Expr::List(list) => {
                if let Expr::Symbol(head) = &list[0] {
                    if head == "if" {
                        cur = if_branch;  // Continue loop, don't recurse
                        continue;
                    }
                }
                // Function call: tail position handled by loop too
                let func = self.eval(&list[0], &env)?;
                match func {
                    Value::Lambda { body, .. } => {
                        cur = body[last];  // Continue loop
                        env = child_env;
                        continue;  // ← Key: avoids recursion
                    }
                }
            }
        }
    }
}
```

This enables **stack-safe recursion** for arbitrary depth:
```lisp
(def sum-to (n acc)
  (if (<= n 0)
      acc
      (sum-to (- n 1) (+ acc n))))

(sum-to 1000000 0)  ; Works! No stack overflow.
```

### Lexical Scoping & Closures

Environments are **immutable linked lists** (via `Rc<RefCell<EnvFrame>>`):

```rust
pub enum Value {
    Lambda {
        params: Vec<String>,
        rest: Option<String>,
        body: Vec<Expr>,
        env: Env,  // ← Captures closure environment
    }
}
```

Example:
```lisp
(def make-counter ()
  (let ((x 0))
    (lambda ()
      (set! x (+ x 1))
      x)))

(def counter (make-counter))
(counter)  ; → 1
(counter)  ; → 2
```

The lambda captures the `let` environment, including `x`. Mutations via `set!` affect the captured cell.

### Hygienic Macros

Macros receive **unevaluated arguments** and expand into new AST, which is then evaluated:

```lisp
(defmacro when (test body)
  `(if ,test (begin ,@body)))

(when (> x 5)
  (print "big"))
  
; Expands to:
; (if (> x 5) (begin (print "big")))
```

Hygiene is preserved because macro variables live in their **definition environment**, not the call site.

---

## Examples

### Recursive Factorial (with TCO)
```lisp
(def fact (n acc)
  (if (<= n 1)
      acc
      (fact (- n 1) (* acc n))))

(fact 5 1)  ; → 120
```

### Map & Filter
```lisp
(def double (x) (* x 2))
(map double '(1 2 3))  ; → (2 4 6)

(filter (lambda (x) (> x 2)) '(1 2 3))  ; → (3)
```

### Closures & Mutable Cells
```lisp
(def make-adder (n)
  (lambda (x) (+ x n)))

(def add5 (make-adder 5))
(add5 10)  ; → 15
```

### Macro: Assert
```lisp
(defmacro assert (condition)
  `(if (not ,condition)
       (error "Assertion failed")))

(assert (= 2 2))  ; OK
(assert (= 2 3))  ; Error
```

### Game AI Example (Pseudocode)
```lisp
(def evaluate-move (game-state move)
  (let* ((result (apply-move game-state move))
         (score (evaluate-board result)))
    (if (> score 100)
        (print "Good move!")
        (print "Weak move."))))
```

---

## Testing

Run the test suite:
```bash
./run_tests.sh
```

This executes `tests.lisp` and `new-features.lisp` against the Rust implementation and compares with expected output.

Test files:
- **tests.lisp** — Core functionality (arithmetic, lists, closures, recursion)
- **new-features.lisp** — Advanced features (let forms, letrec, type predicates)
- **hello.lisp** — Simple example

---

## Use Cases

### ✅ Ideal For
- **AI Agent Scripting** — Decision trees, reasoning logic, prompt composition
- **Game Logic** — State machines, dialogue, NPC behavior
- **Symbolic Reasoning** — Pattern matching, constraint solving, knowledge representation
- **Meta-programming** — DSLs via macros, code generation
- **Prototyping** — Fast iteration on logic before optimization

### ⚠️ Not Ideal For
- Neural network inference (no tensor ops; consider embedding this in a Python/Rust ML framework)
- Large-scale numerical computation (single-threaded, no SIMD)
- Systems programming (use Rust directly)

---

## Roadmap

### Planned Features
- [ ] **Exception Handling** — `try`/`catch`/`finally` for graceful error recovery
- [ ] **Module System** — Namespace support, `(module name exports)`
- [ ] **Pattern Matching** — Enhanced `match` construct for destructuring
- [ ] **Mutable Data Structures** — Hash tables, vectors with efficient mutation
- [ ] **Lazy Evaluation** — `delay`/`force` for infinite sequences
- [ ] **Object System** — `defclass`, `make-instance`, method dispatch
- [ ] **String Interpolation** — Lisp-native template syntax for prompt building

### Performance Optimizations
- Bytecode compilation (currently AST-interpreted)
- JIT compilation for hot paths
- Garbage collection tuning

---

## Contributing

Contributions welcome! See `CONTRIBUTING.md` for guidelines.

To add a new builtin:
1. Add to `setup_builtins()` in `src/main.rs`
2. Add tests to `new-features.lisp` or `tests.lisp`
3. Document in README

---

## License

MIT

---

## Inspiration

- **Scheme** — TCO, lexical scoping, hygienic macros
- **Python** — SimpleLisp prototype (original author)
- **Common Lisp** — Rich standard library
- **Rust** — Safe, performant implementation language

Built for **AI, games, and symbolic reasoning**. Built in **Rust**.

🦀 _In memory of the brother who inspired this journey._
