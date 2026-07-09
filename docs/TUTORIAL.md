# The Rusty Tutorial

From zero to verified, compiled, agent-driven programs. Everything below
is real, runnable code — paste it into the REPL (`cargo run`) or a file
(`cargo run -- file.lisp`). Reference companion: [SPEC.md](./SPEC.md)
(precise semantics) and the README (feature catalog).

## 1. First steps

```lisp
(define x 42)
(define (square n) (* n n))
(square 7)                       ; => 49
(let ((a 1) (b 2)) (+ a b))      ; => 3
```

Two gotchas worth learning on day one:

- **Only `#f` is false.** `()`, `0`, and `""` are all true:
  `(if '() "yes" "no")` ⇒ `"yes"`.
- **`=` is numeric-only.** Compare booleans, symbols, strings, and lists
  with `equal?`.

Recursion is free in tail position — this loops forever without growing
the stack, because named `let`, `if` branches, and last-body positions
are all guaranteed tail calls:

```lisp
(let loop ((i 0) (acc 0))
  (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))   ; => 499999500000
```

## 2. Lists are the data structure

```lisp
(define xs '(1 2 3 4 5))
(map square xs)                  ; => (1 4 9 16 25)
(filter odd? xs)                 ; => (1 3 5)
(foldl + 0 xs)                   ; => 15
(->> xs (filter odd?) (map square) sum)   ; => 35, threading macro
```

Lists are `Rc`-backed: passing them around is O(1). But `cons` copies —
building a long list one `cons` at a time is O(n²); prefer `map`/`filter`
or accumulate and `reverse`.

## 3. Macros: programs that write programs

A macro receives its arguments **unevaluated** and returns code. Three
examples that show the code-generation muscle:

**A record definer** — one call generates a constructor and a getter per
field:

```lisp
(defmacro defrecord (name . fields)
  `(begin
     (define (,name . vals) (cons (quote ,name) vals))
     ,@(let build ((fs fields) (i 1) (acc '()))
         (if (null? fs) (reverse acc)
             (build (cdr fs) (+ i 1)
                    (cons `(define (,(string->symbol
                                      (string-append (symbol->string name) "-"
                                                     (symbol->string (car fs))))
                                    r)
                             (nth r ,i))
                          acc))))))

(defrecord point x y)
(point-x (point 3 4))            ; => 3
```

**A memoizing `define`** — the macro wraps your body in a cache you never
see:

```lisp
(define *memo-table* '())
(defmacro define-memo (sig . body)
  `(define ,sig
     (let ((key (list ,@(cdr sig))))
       (let ((hit (assoc key *memo-table*)))
         (if hit (cadr hit)
             (let ((result (begin ,@body)))
               (set! *memo-table* (cons (list key result) *memo-table*))
               result))))))

(define-memo (slow-square x) (begin (print (list 'computing x)) (* x x)))
(slow-square 6)                  ; prints (computing 6), => 36
(slow-square 6)                  ; silent, => 36
```

**A property-test definer** — compact syntax compiles into an exhaustive
check over finite domains:

```lisp
(defmacro defproperty (name bindings prop)
  `(define (,name)
     (check-exhaustive ,(cons 'lambda (cons (map car bindings) (list prop)))
                       (quote ,(map cadr bindings)))))

(defproperty max-comm ((a (-2 0 3)) (b (-1 4))) (= (max a b) (max b a)))
(max-comm)                       ; => verified
```

Hygiene note: names your template binds via `let`/`lambda`/etc. are
auto-renamed so they can't collide with call-site code. One trap: a
*literal* `(lambda ,params ...)` inside a template confuses that rename
pass — build such forms with `,(cons 'lambda ...)` instead, as
`defproperty` does above. (`let`-bound temps have the same issue; use
`(gensym "tmp")` — see `define-typed` in std.lisp for the house pattern.)

## 4. Verified programming

The verification layers all share one rule: **static checks run before
anything executes, and "verified" means checked on every point of the
stated domains** — never a sample, never a vibe.

```lisp
;; runtime-checked signatures
(define-typed (add2 (x number?) (y number?)) number? (+ x y))

;; contracts checked against the args on every call
(defun-constrained (safe-sqrt x) (assert (>= x 0)) (sqrt x))

;; is this lambda pure? statically:
(check-effects (lambda (x) (begin (print x) x)))   ; => ((print ...)) — no it isn't

;; gate an untrusted candidate: static checks, THEN exhaustive
(verify-candidate (eval-string "(lambda (x) (if (< x 0) (- 0 x) x))")
                  (list (list 'pure #t)
                        (list 'domains (list (list -3 -1 0 2 5)))
                        (list 'invariant (lambda (f x) (>= (f x) 0)))))
;; => verified
```

## 5. Going native

When a numeric function is hot, compile it — `defrust` generates real
Rust, invokes `rustc`, and loads the result (~1000× on `fib(30)`):

```lisp
(defrust fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(fib 30)                          ; => 832040, native

(defrust* (F (n) (if (= n 0) 1 (- n (M (F (- n 1))))))   ; mutual recursion:
          (M (n) (if (= n 0) 0 (- n (F (M (- n 1)))))))  ; one shared .so

(define fk (graph-compile (lambda (x y) (+ (* (+ x y) (+ x y)) (/ x y)))))
(fk 3.0 2.0)                      ; whole optimized dataflow graph → one kernel
```

## 6. Tensors, autodiff, training

```lisp
(define W (tensor '((0.1 0.2) (0.3 0.4))))
(define X (tensor '((1.0 2.0))))
(matmul X W)                      ; => #<tensor 1x2 ...>

;; loss + gradient w.r.t. EVERY argument, one reverse-mode pass:
(graph-grad (lambda (x) (* x x)) 5)          ; => (25 10)

;; training loops: compile forward+backward ONCE, shape-specialized —
;; ~3× over graph-grad, ~37× over 1-thread PyTorch at small sizes:
(define step! (graph-compile-grad loss-fn X W B T))
(step! X W B T)                   ; => (loss gX gW gB gT), bit-identical
```

## 7. Actors, checkpoints, traces

```lisp
(agent-spawn 'square (lambda (m) (send! 'collect (* m m))))
(define total 0)
(agent-spawn 'collect (lambda (v) (set! total (+ total v))))
(send! 'square 7)
(run-agents)                      ; deterministic scheduling => (quiescent 2)
total                             ; => 49

(checkpoint "state.lisp")         ; global env as plain Lisp source;
                                  ; restore = (load "state.lisp")
(trace-on) ... (trace-report)     ; every hop as pure data
```

Keep durable actor state in globals via `set!` — that's what checkpoints
capture faithfully.

## 8. Discovery, synthesis, proof

```lisp
;; find the equation behind data (GP; beats gplearn 25/30 vs 12/30):
(load "symreg.lisp")
(symreg (map (lambda (x) (list (list x) (+ (* x x) x))) '(0 1 2 3 4)) '(x))

;; fill holes in a sketch until the spec is exhaustively satisfied:
(load "synth.lisp")
(synth-fill '(lambda (a b) (if (?? c) a b))
            (list (list 'c '((< a b) (> a b))))
            max-spec)             ; => (ok (lambda (a b) (if (> a b) a b)) ...)

;; and prove things — bounded, honest, counterexamples as data:
(load "prover.lisp")
(defproof abs-nonneg (forall ((x (-5 -1 0 2))) (>= (abs x) 0)) (auto))
(find-counterexample '(forall ((x (-5 0 2))) (> (abs x) 0)))
;; => (counterexamples (((0) false)))
```

## 9. LLM agents

Tools are first-class; the ReAct loop drives a local model against them;
everything model-produced passes the verification gates before it runs.

```lisp
(deftool word-count (path)
  "Count words in a file"
  (length (string-split (file-read path) " ")))

(agent "Summarize README.md in one line")   ; needs llama-server on :8080
(llm "One word for a red fruit?" 0.2 50)
```

Environment: `RUSTY_LLM_URL`, `RUSTY_MODEL`, `RUSTY_SYSTEM`,
`RUSTY_LLM_TIMEOUT_SECS` — raise the timeout well past 120s for slow
reasoning models, or requests abort mid-generation.

## 10. Best practices

- **Verify with runs, not builds.** A change isn't done when it
  compiles; it's done when a before/after test or benchmark shows the
  claimed behavior. The repo's own golden suite (`./run_tests.sh`) is
  the model.
- **Keep verifiable code pure.** `check-effects` gates candidates before
  they execute — side effects in a candidate mean instant rejection.
- **Prefer integer domains for exhaustive checks.** Exact arithmetic is
  what makes "checked everywhere" meaningful (see robot-test.lisp).
- **`eval` vs `eval-string`:** building code as data at runtime → `eval`
  (current env, fast). Untrusted/LLM text → `eval-string` (fresh env),
  and gate it with `verify-candidate` regardless.
- **Total functions in search spaces.** GP and synthesis run arbitrary
  candidates; use protected ops (`sr-pdiv`) so no candidate can raise.
- **State that must survive goes in globals.** Checkpoints re-close
  lambdas over the restored global env; `let`-captures don't survive.
- **Determinism is a feature.** Seeded PRNGs, ordered enumeration, and
  deterministic scheduling are why every capability here golden-tests.
