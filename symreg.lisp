;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; symreg.lisp — symbolic regression by genetic programming (Phase 4.1).
;;
;; Find a human-readable equation fitting data, as a pure-Lisp library:
;; candidate equations ARE Lisp expressions (lists), so generation,
;; crossover, and mutation are ordinary list surgery, and fitness turns a
;; candidate into a real callable via `(eval (list 'lambda vars expr))` —
;; the interpreter's own fast path, no meta-interpretation.
;;
;;   (symreg data vars)                 ; data rows: ((inputs...) target)
;;   (symreg data vars pop gens)        ; explicit population/generation caps
;;     => (expr mse generation)        ; expr already simplified
;;
;; Deterministic: seeded LCG PRNG ((symreg-seed! n) to reseed), so runs are
;; reproducible and this library golden-tests (see symreg-test.lisp).

;; ── Seeded PRNG ───────────────────────────────────────────────────────────
(define *symreg-seed* 123456789)
(define (symreg-seed! n) (set! *symreg-seed* n))
(define (sr-rand)                       ; float in [0,1)
  (set! *symreg-seed* (mod (+ (* *symreg-seed* 1103515245) 12345) 2147483648))
  (/ *symreg-seed* 2147483648))
(define (sr-rand-int n) (floor (* (sr-rand) n)))
(define (sr-choose lst) (nth lst (sr-rand-int (length lst))))

;; ── Random expression trees ──────────────────────────────────────────────
;; Protected division, the classic GP guard: Rusty's `/` raises on a zero
;; divisor, and a random candidate WILL divide by zero somewhere in the
;; data. pdiv is total (returns 1 there), so every candidate is safe to run.
(define (sr-pdiv a b) (if (= b 0) 1 (/ a b)))
;; Op table rows are (name arity). Extend the vocabulary with
;; (symreg-ops! ...) — including MACRO building blocks: a block defined via
;; defmacro (e.g. (defmacro sq (e) `(* ,e ,e))) is legal GP vocabulary,
;; because fitness runs candidates through `eval`, which expands macros.
;; Blocks keep candidate trees small — the search explores a richer space
;; at the same tree depth (docs/ROADMAP.md 4.1, macro-based generation).
(define *sr-default-ops* '((+ 2) (- 2) (* 2) (sr-pdiv 2)))
(define *sr-ops* *sr-default-ops*)
(define (symreg-ops! ops) (set! *sr-ops* ops))
(define (symreg-ops-reset!) (set! *sr-ops* *sr-default-ops*))
(define (sr-random-const) (- (sr-rand-int 11) 5))          ; integer in -5..5
(define (sr-random-terminal vars)
  (if (< (sr-rand) 0.7) (sr-choose vars) (sr-random-const)))
(define (sr-random-tree vars depth)
  (if (or (= depth 0) (< (sr-rand) 0.3))
      (sr-random-terminal vars)
      (let ((op (sr-choose *sr-ops*)))
        (cons (car op) (sr-random-args vars (- depth 1) (cadr op))))))
(define (sr-random-args vars depth n)
  (if (= n 0) '()
      (cons (sr-random-tree vars depth) (sr-random-args vars depth (- n 1)))))

;; ── Tree surgery (preorder indexing) ─────────────────────────────────────
(define (sr-size t)
  (if (pair? t) (+ 1 (sum (map sr-size (cdr t)))) 1))
(define (sr-get t i)
  (if (= i 0) t (sr-get-in (cdr t) (- i 1))))
(define (sr-get-in ts i)
  (let ((s (sr-size (car ts))))
    (if (< i s) (sr-get (car ts) i) (sr-get-in (cdr ts) (- i s)))))
(define (sr-put t i sub)
  (if (= i 0) sub (cons (car t) (sr-put-in (cdr t) (- i 1) sub))))
(define (sr-put-in ts i sub)
  (let ((s (sr-size (car ts))))
    (if (< i s)
        (cons (sr-put (car ts) i sub) (cdr ts))
        (cons (car ts) (sr-put-in (cdr ts) (- i s) sub)))))

;; ── Fitness: MSE, with NaN → hard penalty ────────────────────────────────
;; With pdiv total, candidates can't raise; extreme values can still
;; overflow to inf (loses every comparison it should lose) or NaN (compares
;; false with everything, itself included — caught by the (= m m) test).
(define (sr-fitness expr vars data)
  (let ((f (eval (list 'lambda vars expr))))
    (let ((m (/ (sum (map (lambda (row)
                            (let ((d (- (apply f (car row)) (cadr row))))
                              (* d d)))
                          data))
                (length data))))
      (if (= m m) m 1e300))))

;; ── Variation ─────────────────────────────────────────────────────────────
(define *sr-max-size* 60)   ; parsimony guard: oversized offspring are rejected
(define (sr-crossover a b)
  (let ((child (sr-put a (sr-rand-int (sr-size a))
                       (sr-get b (sr-rand-int (sr-size b))))))
    (if (> (sr-size child) *sr-max-size*) a child)))
(define (sr-mutate t vars)
  (let ((child (sr-put t (sr-rand-int (sr-size t)) (sr-random-tree vars 2))))
    (if (> (sr-size child) *sr-max-size*) t child)))

;; ── Selection: k-tournament on (expr fitness) pairs ──────────────────────
(define (sr-tournament scored n k)
  (let loop ((i 1) (best (nth scored (sr-rand-int n))))
    (if (>= i k) best
        (let ((c (nth scored (sr-rand-int n))))
          (loop (+ i 1) (if (< (caddr c) (caddr best)) c best))))))

;; ── Finalization: sr-pdiv → / where provably safe ────────────────────────
;; The evolved equation uses protected division; if plain `/` produces the
;; identical MSE on the training data (i.e. no divisor is ever 0 there),
;; present the human the ordinary form.
(define (sr-unprotect t)
  (if (not (pair? t)) t
      (cons (if (equal? (car t) 'sr-pdiv) '/ (car t))
            (map sr-unprotect (cdr t)))))
(define (sr-finalize expr vars data)
  (let ((plain (sr-unprotect expr)))
    (if (try-catch (= (sr-fitness plain vars data) (sr-fitness expr vars data))
                   (e) #f)
        plain expr)))

;; ── Simplification: constant folding + algebraic identities ─────────────
(define (sr-factors t)          ; flatten a product tree into its factors
  (if (and (pair? t) (equal? (car t) '*))
      (append (sr-factors (cadr t)) (sr-factors (caddr t)))
      (list t)))
(define (sr-remove-once x lst)
  (cond ((null? lst) '())
        ((equal? (car lst) x) (cdr lst))
        (else (cons (car lst) (sr-remove-once x (cdr lst))))))
(define (sr-product factors)
  (cond ((null? factors) 1)
        ((null? (cdr factors)) (car factors))
        (else (list '* (car factors) (sr-product (cdr factors))))))
(define (sr-member? x lst)
  (cond ((null? lst) #f)
        ((equal? (car lst) x) #t)
        (else (sr-member? x (cdr lst)))))

(define (sr-simplify1 t)
  (cond ((not (pair? t)) t)
        ((not (= (length t) 3))          ; unary/n-ary op (macro block):
         (let ((args (map sr-simplify1 (cdr t))))
           (if (all? number? args)       ; constant-fold if args are constant
               (eval (cons (car t) args))
               (cons (car t) args))))
        (else
      (let ((op (car t))
            (a (sr-simplify1 (cadr t)))
            (b (sr-simplify1 (caddr t))))
        (cond ((and (number? a) (number? b))
               (eval (list op a b)))
              ((and (equal? op '*) (equal? a 1)) b)
              ((and (equal? op '*) (equal? b 1)) a)
              ((and (equal? op '*) (or (equal? a 0) (equal? b 0))) 0)
              ((and (equal? op '+) (equal? a 0)) b)
              ((and (equal? op '+) (equal? b 0)) a)
              ((and (equal? op '-) (equal? b 0)) a)
              ((and (equal? op '-) (equal? a b)) 0)
              ((and (equal? op 'sr-pdiv) (equal? b 1)) a)
              ((and (equal? op 'sr-pdiv) (equal? a b)) 1)  ; pdiv(0,0)=1 too
              ;; presentation-level cancellation (standard CAS move — exact
              ;; everywhere except the removable singularity at b = 0):
              ;; (/ (* ... b ...) b) → the product without that b, however
              ;; deeply the factor sits in the product tree.
              ((and (or (equal? op '/) (equal? op 'sr-pdiv))
                    (sr-member? b (sr-factors a)))
               (sr-product (sr-remove-once b (sr-factors a))))
              (else (list op a b)))))))
(define (sr-simplify t)
  (let ((s (sr-simplify1 t)))
    (if (equal? s t) t (sr-simplify s))))

;; ── The evolution loop ────────────────────────────────────────────────────
(define (sr-init-population vars n)
  (if (= n 0) '()
      (cons (sr-random-tree vars (+ 2 (mod n 3)))   ; ramped depths 2–4
            (sr-init-population vars (- n 1)))))

(define (sr-next-gen scored n vars elite)
  ;; keep the elite, breed the rest: 90% crossover, 10% subtree mutation
  (let loop ((i 1) (acc (list elite)))
    (if (>= i n) acc
        (let ((p1 (car (sr-tournament scored n 3))))
          (loop (+ i 1)
                (cons (if (< (sr-rand) 0.9)
                          (sr-crossover p1 (car (sr-tournament scored n 3)))
                          (sr-mutate p1 vars))
                      acc))))))

(define (symreg data vars . opt)
  (let ((pop-size (if (null? opt) 120 (car opt)))
        (max-gens (if (or (null? opt) (null? (cdr opt))) 60 (cadr opt))))
    (let evolve ((pop (sr-init-population vars pop-size))
                 (gen 0)
                 (best '(0 1e301)))
      ;; scored rows: (expr raw-mse selection-score) — the selection score
      ;; adds a parsimony nudge (1e-10 per node) that only matters as a
      ;; tie-break between equally-fitting equations: prefer the smaller.
      (let ((scored (map (lambda (e)
                           (let ((m (sr-fitness e vars data)))
                             (list e m (+ m (* 1e-10 (sr-size e))))))
                         pop)))
        (let ((gen-best (foldl (lambda (c acc) (if (< (cadr c) (cadr acc)) c acc))
                               best scored)))
          (if (or (< (cadr gen-best) 1e-20) (>= gen max-gens))
              (list (sr-finalize (sr-simplify (car gen-best)) vars data)
                    (cadr gen-best) gen)
              (evolve (sr-next-gen scored pop-size vars (car gen-best))
                      (+ gen 1)
                      gen-best)))))))
