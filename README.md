# Rusty — A Modern Lisp in Rust

A complete, feature-rich Lisp interpreter implemented in Rust with first-class support for **AI agent orchestration**, **tool calling**, **LLM integration**, and **symbolic reasoning**.

**Version:** 0.10.0 | **Status:** Production-ready — REPL, file runner, Python bridge, AI agent loop

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
(assert condition "message")
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

## Vision

> *"Rusty as the symbolic transformation layer for AI/ML infrastructure."*

The 5-year direction: make Rusty the language people reach for when they need computation that reasons about computation — LLM as creative planner, Rusty as reliable executor with memory, tools, and rules.

- **Neuro-symbolic bridge**: embed logical constraints alongside neural computation
- **Composable agent tools**: `deftool` as a first-class primitive, not an afterthought  
- **Verifiable AI systems**: Lisp's homoiconicity makes it natural to reason about the programs you're generating

---

## License

MIT

🦀 *In memory of the brother who inspired this journey.*
