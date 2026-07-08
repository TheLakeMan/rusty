# Rusty — A Modern Lisp in Rust

A complete, feature-rich Lisp interpreter implemented in Rust with first-class support for **AI agent orchestration**, **tool calling**, **LLM integration**, and **symbolic reasoning**.

**Version:** 0.10.0 | **Status:** Production-ready — REPL, file runner, Python bridge, AI agent loop

---

## 🎯 Vision: The Symbolic Transformation Layer for AI/ML

Rusty is the language you reach for when you need **computation that reasons about computation**:

- **LLM as creative planner** — Generate high-level strategies
- **Rusty as reliable executor** — Deterministically execute with symbolic reasoning
- **Verifiable agents** — Prove correctness using formal methods

[→ **See the full 5-year roadmap →**](./ROADMAP.md)

---

## Quick Start

```bash
# Build
cargo build --release

# Interactive REPL
cargo run

# Run a Lisp file
cargo run -- path/to/script.lisp

# Run the agent demo
cargo run -- agent.lisp

# Python bridge
maturin develop
python3 -c "import rusty; print(rusty.eval('(+ 1 2)'))"
```

---

## Architecture

```
Source (.lisp) or REPL input
    ↓  src/lexer.rs       — tokenizer
    ↓  src/parser.rs      — S-expression parser  
    ↓  src/eval.rs        — evaluator, TCO loop, special forms, LLM + tool builtins
    ↓  src/env.rs         — lexical environments, closures
    ↓  src/interp.rs      — builtins, stdlib loader, shared core
    ↓  src/lib.rs         — PyO3 Python bindings
    ↓  src/main.rs        — REPL, file runner
```

### Key Files

| File | Purpose |
|------|---------|
| `src/eval.rs` | Evaluator — TCO loop, special forms, `deftool`, `react-loop`, `llm` |
| `src/interp.rs` | 60+ builtins, stdlib loader, JSON, shell, format |
| `src/env.rs` | Environment frames — `Value` enum including `Tool`, `Lambda`, `Macro` |
| `src/lib.rs` | Python bindings via PyO3 — `Rusty`, `RustySession`, `rusty.eval()` |
| `agent.lisp` | 10 filesystem + shell + LLM tools, ReAct agent loop |
| `std.lisp` | Standard library — 230+ lines of Lisp utilities |

[→ **Deep dive: Full architecture guide →**](./ARCHITECTURE.md)

---

## AI Agent System

Rusty is designed as the **symbolic execution layer** for local AI agents:

```
LLM (planner)     → decides what to do
Rusty (executor)  → deterministically does it
```

### deftool — Register Agent Tools

```lisp
(deftool create-dir (path)
  "Create a directory at the given path"
  (shell (format "mkdir -p ~a" path)))

(deftool read-file (path)
  "Read file contents"
  (shell (format "cat ~a" path)))

(deftool ask-llm (prompt)
  "Query the local LLM"
  (llm prompt 0.7 500))
```

### tool-call — Execute Tools

```lisp
; Direct tool invocation
(tool-call "create-dir" "my-project")
(tool-call "write-file" "my-project/README.md" "# Hello from Rusty!")
(tool-call "read-file" "my-project/README.md")
(tool-call "list-dir" "my-project")
(tool-call "file-exists" "my-project/README.md")
(tool-call "ask-llm" "What is machine learning?")
```

### list-tools — Inspect Registry

```lisp
(list-tools)
; => ((create-dir ("path") "Create a directory...")
;     (write-file ("path" "content") "Write content...")
;     ...)

(show-tools)   ; Pretty-print all registered tools
```

### react-loop — Autonomous Agent

```lisp
; Load tools then run the ReAct loop
(load "agent.lisp")
(agent "Create a folder called notes with an index.md file")
```

The ReAct loop:
1. Sends goal + tool descriptions to the LLM
2. Parses `ACTION:` / `INPUT:` / `FINAL:` from response
3. Executes the tool call via Rusty (real system calls)
4. Feeds `OBSERVATION:` back to LLM
5. Repeats until `FINAL:` or max steps

### llm — Direct LLM Access

```lisp
; Requires llama-server running on localhost:8080
(llm "What is 2+2?" 0.7 100)
(llm "Summarize this" 0.3 500)
```

Start a compatible server:
```bash
# With llama.cpp
llama-server -m /path/to/model.gguf --port 8080

# With Hyperion
~/hyperion/build/model_server /path/to/model.gguf
# then wrap with an OpenAI-compatible proxy
```

---

## Built-in Tools (agent.lisp)

| Tool | Args | Description |
|------|------|-------------|
| `create-dir` | `path` | Create directory (mkdir -p) |
| `write-file` | `path content` | Write content to file |
| `append-file` | `path content` | Append content to file |
| `read-file` | `path` | Read file contents |
| `list-dir` | `path` | List directory (ls -la) |
| `delete-file` | `path` | Delete a file |
| `file-exists` | `path` | Check if path exists → bool |
| `shell-run` | `command` | Run any shell command |
| `ask-llm` | `prompt` | Query local LLM |
| `search-files` | `pattern` | grep -r in current directory |

---

## Python Bridge

```python
import rusty

# One-shot eval
print(rusty.eval("(+ 1 2)"))                    # "3"
print(rusty.eval("(->> '(1 2 3) (filter odd?) (map square) sum)"))  # "35"

# Stateless instance
r = rusty.Rusty()
print(r.eval("(json-encode (list (list \"x\" 42)))"))  # {"x": 42}

# Stateful session — definitions persist across calls
s = rusty.RustySession()
s.eval("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))")
print(s.eval("(fact 10)"))   # 3628800
```

Build the Python package:
```bash
maturin develop        # install into active venv
maturin build          # build wheel for distribution
```

---

## Language Reference

### Core Special Forms

```lisp
(define x 42)                          ; bind
(define (f x y) (+ x y))              ; define function
(def f (x y) (+ x y))                 ; SimpleLisp-style define
(set! x 43)                            ; mutate existing
(set x 44)                             ; create or mutate
(lambda (x y . rest) body...)          ; anonymous function
(if test then else)                    ; conditional
(cond (test expr)... (else expr))      ; multi-branch
(and a b c) (or a b c)                ; short-circuit logic
(when test body...) (unless test body...)
(begin e1 e2 ... en)                   ; sequence
(let ((x 1) (y 2)) body...)           ; local bindings
(let* ((x 1) (y (+ x 1))) body...)    ; sequential let
(letrec ((f (lambda (n) ...))) body...) ; recursive let
(let loop ((i 0)) body... (loop (+ i 1)))  ; named let / loop
(do ((var init step)...) (test result...) body...)  ; do loop
(quote x) 'x                          ; literal data
(quasiquote x) `x  ,splice  ,@splice  ; template / unquote
(eval-when (phase...) body...)         ; run body now (phase unused outside macros);
                                        ; inside defmacro, runs once at definition time
```

### Macros

```lisp
(defmacro my-when (test . body)
  `(if ,test (begin ,@body) ()))

(defmacro swap! (a b)
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp ,a)) (set! ,a ,b) (set! ,b ,tmp))))

(gensym "prefix")    ; unique symbol for hygienic macros
```

### Macro Profiler

```lisp
(macro-profile-on)          ; start recording expansion counts/timing (off by default)
(macro-profile-report)      ; => ((name call-count total-microseconds) ...) sorted by time desc
(show-macro-profile)        ; pretty-print the above
(macro-profile-reset)
(macro-profile-off)
```

### Native Codegen (defrust) & Symbolic Differentiation

```lisp
;; Compiles a restricted numeric subset (numbers, params, + - * /, if,
;; self-recursive calls) to real Rust via rustc, and dynamically loads it.
;; ~1000x faster than the tree-walked equivalent once compiled (measured
;; on fib(30): ~8.2s interpreted vs. ~0.007s compiled, cached).
(defrust fib (n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(fib 30)   ; => 832040, runs as native code

;; True symbolic differentiation (AST rewriting via calculus rules), not
;; numeric approximation — grad returns a new callable derivative function.
(define d/dx (grad (lambda (x) (+ (* x x) 1))))   ; d/dx[x^2 + 1] = 2x
(d/dx 3)   ; => 6
```

### Graph IR

```lisp
;; A computation-DAG IR (inspired by XLA/TVM) over the same restricted
;; numeric subset defrust compiles. Common-subexpression elimination falls
;; out of hash-consing during construction; constant folding (incl. pruning
;; an if-branch with a constant condition) and dead-code elimination are
;; explicit passes run afterward. No codegen backend yet — graph-eval runs
;; the optimized IR through its own small interpreter.
(graph-node-count (lambda (x) (+ (* x x) (* x x))))  ; => 3 (not 5 — CSE)
(graph-ir (lambda (x) (+ (* 2 3) x)))                ; => (((0 const 6) (1 param 0) (2 add 0 1)) 2)
(graph-eval (lambda (x y) (if (> x y) (- x y) (+ x y))) 5 2)  ; => 3
```

### Agent / Tool Forms

```lisp
(deftool name (params) "description" body...)
(tool-call "name" arg...)
(list-tools)
(react-loop goal max-steps)
(llm prompt temperature max-tokens)
(shell "command")
```

### Error Handling

```lisp
(try-catch
  (/ 1 0)
  (e) (format "Caught: ~a" e))
```

### Pattern Matching

```lisp
(match value
  (("ok" v)    (format "got: ~a" v))
  (("err" e)   (format "error: ~a" e))
  ((_ . rest)  (format "list: ~a" rest))
  (_           "unknown"))
```

### File Loading

```lisp
(load "tools.lisp")
(load-relative "utils.lisp")
```

### Arithmetic & Math

```lisp
+ - * / mod expt abs sqrt floor ceiling round max min gcd
; Aliases: add sub mul div
```

### Comparison

```lisp
= < > <= >= eq? equal? not zero? positive? negative? odd? even?
; Aliases: eq gt lt ge le neq
```

### Lists

```lisp
cons car cdr list null? pair? list? length append reverse
nth member list-tail map filter foldl foldr for-each apply
; From std.lisp: zip take drop range iota flatten any? all?
; partition find remove-duplicates zip-with
```

### Strings

```lisp
string-length string-append string-append-list substring
string-ref string=? number->string string->number
symbol->string string->symbol string->list str
format    ; (format "~a + ~a = ~a" 1 2 3)  →  "1 + 2 = 3"
          ; ~a = any, ~s = quoted, ~% = newline, ~~ = tilde
string-join string-repeat string-contains? string-starts-with?
```

### JSON

```lisp
(json-encode (list (list "key" "val")))   ; → "{\"key\": \"val\"}"
(json-decode "{\"x\": 42}")               ; → (("x" 42))
```

### Types

```lisp
number? string? boolean? symbol? list? procedure? macro? tool? nil?
type-of    ; → symbol: number / string / boolean / lambda / tool / ...
```

### I/O

```lisp
(print x y z)      ; space-separated, with newline
(println x)        ; alias for print
(display x)        ; no newline, strings unquoted
(newline)
(error "msg")
```

### Standard Library (std.lisp, auto-loaded)

```lisp
; Math
square cube inc dec average clamp sign

; Lists  
last flatten zip zip-with take drop take-while drop-while
range iota sum product any? all? none? count find find-index
partition remove-duplicates flatten1 interleave

; Association lists
assoc assq alist-get record-set make-record get-field
(field key record)   ; accessor macro

; Functional
compose curry identity const flip negate memoize
map* filter* foldl*  ; pipeline-friendly (list-first)

; Threading macros
(-> x (f a) (g b))    ; thread first
(->> x (f a) (g b))   ; thread last

; Loop macros
(dotimes (i 10) body...)
(dolist (x lst) body...)
(while test body...)
(repeat n body...)

; Assertions
(assert condition ["message"])   ; message optional — defaults to the literal condition text

; Constraint embedding
(defun-constrained (safe-sqrt x)
  (assert (>= x 0))
  (sqrt x))
;; (safe-sqrt -4) raises "Assertion failed: (>= x 0)" instead of returning NaN

; Logic-driven loss (crisp propositional logic, not fuzzy/differentiable)
(logic-loss (and (implies P Q) (not R)))   ; => 0 if the formula holds, else 1

; Gradual typing — runtime contracts at call time; define/lambda are
; untouched, this is a separate opt-in macro. ti/return-type name an
; existing <type>? predicate (number, string, boolean, symbol, list, ...).
(define-typed (add-typed (x : number) (y : number)) : number
  (+ x y))
(add-typed 3 "oops")   ; => Error: expected number, got a different type

; Flow-sensitive static type checking — walks the body WITHOUT running it,
; narrowing types through if/let. Conservative: unresolvable types are
; "unknown" and never flagged, so this only reports provable mismatches.
(check-types (lambda (x) (string-length x)) '((x number)))
;; => ("string-length: argument 1 is statically known to be number, expected string")

;; narrowing overrides an outer declared type within a branch:
(check-types (lambda (x) (if (number? x) (+ x 1) 0)) '((x string)))  ; => ok

; Effect tracking — walks the body WITHOUT running it, reporting any
; operation it can prove is effectful (set!, print, shell, file I/O,
; llm/tool-call, memory, gensym, load); quoted data is never flagged.
(check-effects (lambda (x) (+ x 1)))            ; => pure
(check-effects (lambda (x) (print x) (+ x 1)))  ; => ("print: performs I/O")
(effectful? 'set!)                              ; => #t

; Bounded exhaustive checking — proves a property over EVERY combination
; of finite domains (not sampling); returns 'verified or counterexamples.
(check-exhaustive (lambda (x y) (= (+ x y) (+ y x)))
                  '((-2 -1 0 1 2) (-2 -1 0 1 2)))       ; => verified
(check-exhaustive (lambda (m e) (member (transition m e) modes))
                  (list modes events))                   ; => verified: transition is total & closed
```

---

## Tail Call Optimization

Rusty implements TCO via an explicit trampoline loop — stack-safe recursion to arbitrary depth:

```lisp
(define (sum-to n acc)
  (if (<= n 0) acc
      (sum-to (- n 1) (+ acc n))))

(sum-to 1000000 0)   ; no stack overflow
```

---

## Testing

```bash
./run_tests.sh
# or individually:
cargo run -- tests.lisp
cargo run -- new-features.lisp
cargo run -- hello.lisp
```

---

## 5-Year Roadmap

### Phase 1 (Q1–Q4 2025): Symbolic Transformation Layer
Build macro DSLs for computation graph generation and optimization. Generate code on par with PyTorch.

### Phase 2 (Q1–Q2 2026): Verifiable AI Systems
Integrate formal verification (Lean/Coq). Prove tool correctness. Add gradual typing.

### Phase 3 (Q3–Q4 2026): Production ML Integration
Zero-copy tensor interop with PyTorch/JAX. Multi-agent coordination. 10x performance.

### Phase 4 (Q1–Q4 2027): Ecosystem & Libraries
Killer apps: symbolic regression, proof synthesis, robot control. Package manager.

### Phase 5 (Q1 2028+): Maturity
v1.0.0 release. IDE support, LSP, debugger. Production deployments.

**[→ Read the full roadmap →](./ROADMAP.md)**

---

## Contributing

Rusty welcomes contributions! Areas of interest:

- **Performance optimization** — Reduce cloning, implement copy-on-write
- **Macro system** — New examples, DSL patterns
- **Python bridge** — More bindings, better interop
- **Documentation** — Tutorials, examples, API docs
- **Tests** — Coverage, edge cases, property-based testing

See [ROADMAP.md](./ROADMAP.md) for planned features and [ARCHITECTURE.md](./ARCHITECTURE.md) for deep-dive technical design.

---

## License

MIT

🦀 *In memory of the brother who inspired this journey.*
