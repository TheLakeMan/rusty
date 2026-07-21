;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; listdsl.lisp — a comprehension DSL that FUSES a map/filter pipeline into a
;; single pass, with the fusion PROVEN equivalent to the naive multi-pass
;; version by check-exhaustive. Pure Lisp, zero interpreter changes.
;;
;; The JAX angle done the Rusty way. JAX/XLA fuse element-wise ops into one
;; kernel so the intermediate arrays are never materialized; the correctness of
;; that rewrite is trusted. Here the same rewrite is a DATA transform you can
;; run BOTH ways — `naive-run` materializes one list per stage, `fused-run`
;; threads each element through every stage in a single pass — and
;; `verify-fusion` proves the two agree over EVERY list in a declared finite
;; domain. The optimization is not asserted; it is checked everywhere.
;;
;; A PIPELINE is data: a list of stages, each `(map f)` or `(filter p)`, applied
;; left to right. The comprehension macro `lc` is sugar that builds one:
;;   (lc (* x x) (x <- xs) (> x 2))   ==  [x*x for x in xs if x>2]
;;
;; The "optimized" claim is made COUNTABLE: `lc-cons!` bumps a shared cell
;; counter on every output cons, so the golden shows the fused pass allocating
;; one output list where the naive pass allocates one per stage — a real,
;; deterministic win, not a wall-clock anecdote.
;;
;; CLAIM DISCIPLINE: "the fused single-pass executor is proven EQUAL to the
;; naive multi-pass version over the declared finite list domain, and allocates
;; fewer intermediate cells." NEVER a wall-clock speed claim, never a statement
;; about infinite/lazy streams — the proof is over the declared finite domain,
;; and reordering that ISN'T a valid fusion is refused with a witness.

;; ── Instrumented allocation counter ────────────────────────────────────────
;; Both runners build output through lc-cons!, so the cell counts they report
;; are directly comparable (the counting is fair by construction).
(define *lc-cells* 0)
(define (lc-reset!) (set! *lc-cells* 0))
(define (lc-count)  *lc-cells*)
(define (lc-cons! v tail)
  (set! *lc-cells* (+ *lc-cells* 1))
  (cons v tail))

;; ── Naive multi-pass execution (the reference) ─────────────────────────────
;; Each stage walks the whole list and MATERIALIZES a fresh output list.
(define (lc-map f xs)
  (if (null? xs) '()
      (lc-cons! (f (car xs)) (lc-map f (cdr xs)))))

(define (lc-filter p xs)
  (cond ((null? xs) '())
        ((p (car xs)) (lc-cons! (car xs) (lc-filter p (cdr xs))))
        (else (lc-filter p (cdr xs)))))

(define (stage-run stage xs)
  (cond ((equal? (car stage) 'map)    (lc-map    (cadr stage) xs))
        ((equal? (car stage) 'filter) (lc-filter (cadr stage) xs))
        (else (error (string-append "lc: unknown stage "
                                    (format "~a" (car stage)))))))

(define (naive-run pipeline xs)
  (if (null? pipeline) xs
      (naive-run (cdr pipeline) (stage-run (car pipeline) xs))))

;; ── Fused single-pass execution (the "optimized" code the DSL generates) ────
;; Each element is threaded through EVERY stage before the next element is
;; touched; a filter that rejects short-circuits the rest of the pipeline for
;; that element. No stage ever sees a materialized intermediate list.
(define (fuse-elem pipeline x)          ; -> (keep v) | (drop)
  (let loop ((ps pipeline) (v x))
    (if (null? ps) (list 'keep v)
        (let ((stage (car ps)))
          (cond ((equal? (car stage) 'map)
                 (loop (cdr ps) ((cadr stage) v)))
                ((equal? (car stage) 'filter)
                 (if ((cadr stage) v) (loop (cdr ps) v) (list 'drop)))
                (else (error "lc: unknown stage")))))))

(define (fused-run pipeline xs)
  (if (null? xs) '()
      (let ((r (fuse-elem pipeline (car xs))))
        (if (equal? (car r) 'keep)
            (lc-cons! (cadr r) (fused-run pipeline (cdr xs)))
            (fused-run pipeline (cdr xs))))))

;; `run` is the fused executor — running a pipeline uses the optimized path.
(define (run pipeline xs) (fused-run pipeline xs))

;; ── Comprehension sugar ────────────────────────────────────────────────────
;; (lc yield (var <- source) guard...)  ==  [yield for var in source if guards]
;; Desugars straight into a fused (filter then map) pipeline.
(define (lc-guard-expr gs) (if (null? gs) #t (cons 'and gs)))
(defmacro lc (yield binding . guards)
  (let ((var   (car binding))
        (arrow (cadr binding))
        (src   (caddr binding)))
    (if (not (equal? arrow '<-))
        (error "lc: binding must be (var <- source)")
        `(fused-run
           (list (list 'filter (lambda (,var) ,(lc-guard-expr guards)))
                 (list 'map    (lambda (,var) ,yield)))
           ,src))))

;; ── Finite list domains (for the exhaustive proofs) ─────────────────────────
(define (lists-of-len alphabet n)
  (if (= n 0) (list '())
      (let ((shorter (lists-of-len alphabet (- n 1))))
        (apply append
          (map (lambda (a) (map (lambda (t) (cons a t)) shorter)) alphabet)))))

(define (lists-upto alphabet maxlen)
  (apply append
    (map (lambda (n) (lists-of-len alphabet n)) (range 0 (+ maxlen 1)))))

;; ── The proofs ──────────────────────────────────────────────────────────────
;; Fusion preserves semantics: fused-run == naive-run for EVERY list in domain.
(define (verify-fusion pipeline domain)
  (check-exhaustive
    (lambda (xs) (equal? (naive-run pipeline xs) (fused-run pipeline xs)))
    (list domain)))

;; Algebraic fusion laws, each proven over a finite list domain:
;;   map f . map g            ==  map (f . g)          (map-map fusion)
;; (local binary compose; std's variadic `compose` has a known closure edge
;; case for called multi-fn composes, so we build the closure directly.)
(define (comp2 f g) (lambda (x) (f (g x))))
(define (verify-map-map-law g f domain)
  (check-exhaustive
    (lambda (xs)
      (equal? (naive-run (list (list 'map g) (list 'map f)) xs)
              (naive-run (list (list 'map (comp2 f g))) xs)))
    (list domain)))

;;   filter p . filter q      ==  filter (p and q)      (filter-filter fusion)
(define (verify-filter-filter-law p q domain)
  (check-exhaustive
    (lambda (xs)
      (equal? (naive-run (list (list 'filter p) (list 'filter q)) xs)
              (naive-run (list (list 'filter (lambda (x) (and (p x) (q x))))) xs)))
    (list domain)))

;; Reduction fusion: sum(map f xs) with NO materialized intermediate list.
(define (naive-sum-map f xs) (sum (lc-map f xs)))         ; allocates |xs| cells
(define (fused-sum-map f xs)                               ; allocates 0 cells
  (let loop ((ys xs) (acc 0))
    (if (null? ys) acc (loop (cdr ys) (+ acc (f (car ys)))))))
(define (verify-sum-map-fusion f domain)
  (check-exhaustive
    (lambda (xs) (= (naive-sum-map f xs) (fused-sum-map f xs)))
    (list domain)))

;; NEGATIVE CONTROL — reordering map and filter is NOT a valid fusion in
;; general (the guard sees pre- vs post-map values), and the check REFUSES it
;; with real list witnesses.
(define (verify-reorder-map-filter f p domain)
  (check-exhaustive
    (lambda (xs)
      (equal? (naive-run (list (list 'map f) (list 'filter p)) xs)
              (naive-run (list (list 'filter p) (list 'map f)) xs)))
    (list domain)))
