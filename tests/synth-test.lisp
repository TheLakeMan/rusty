;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; synth-test.lisp — golden test for synth.lisp (sketch-based synthesis).
;; Deterministic: enumeration order is fixed, no randomness, no LLM.

(load "synth.lisp")

;; ── Warm-up: synthesize max from a one-hole sketch ───────────────────────
(define max-spec
  (list (list 'pure #t)
        (list 'domains (list (list -2 0 3) (list -1 1 4)))
        (list 'invariant
              (lambda (f a b) (and (>= (f a b) a) (>= (f a b) b)
                                   (or (= (f a b) a) (= (f a b) b)))))))
(define r-max
  (synth-fill '(lambda (a b) (if (?? c) a b))
              (list (list 'c '((< a b) (= a b) (> a b))))
              max-spec))
(print (cons 'max r-max))

;; ── abs: two interacting holes ───────────────────────────────────────────
(define abs-spec
  (list (list 'pure #t)
        (list 'domains (list (list -3 -1 0 2 5)))
        (list 'invariant
              (lambda (f x) (and (>= (f x) 0)
                                 (or (= (f x) x) (= (f x) (- 0 x))))))))
(define r-abs
  (synth-fill '(lambda (x) (if (?? c) (?? e) x))
              (list (list 'c '((> x 0) (< x 0) (= x 0)))
                    (list 'e '(x (* x x) (- 0 x))))
              abs-spec))
(print (cons 'abs r-abs))

;; ── The deliverable: sorting algorithms from spec ────────────────────────
(define (sorted? l)
  (or (null? l) (null? (cdr l))
      (and (<= (car l) (cadr l)) (sorted? (cdr l)))))
(define (count-of x l) (length (filter (lambda (y) (= y x)) l)))
(define (perm? a b)
  (and (= (length a) (length b))
       (all? (lambda (x) (= (count-of x a) (count-of x b))) b)))

(define sort-spec
  (list (list 'pure #t)
        (list 'domains
              (list (list '() '(1) '(2 1) '(1 2) '(3 1 2) '(2 2 1)
                          '(5 -1 4 0) '(1 2 3 4) '(4 3 2 1) '(7 7 7))))
        (list 'invariant
              (lambda (f l) (and (sorted? (f l)) (perm? (f l) l))))))

;; Insertion sort: holes for the base case and the comparison. Wrong
;; fillings enumerate first — the tried/cexs counts show CEGIS working.
(define isort-sketch
  '(letrec ((insert (lambda (x s)
                      (cond ((null? s) (?? base))
                            ((?? cmp) (cons x s))
                            (else (cons (car s) (insert x (cdr s)))))))
            (isort  (lambda (l)
                      (if (null? l) (quote ())
                          (insert (car l) (isort (cdr l)))))))
     isort))
(define r-isort
  (synth-fill isort-sketch
              (list (list 'base '((quote ()) s (list x)))
                    (list 'cmp  '((> x (car s)) (= x (car s)) (< x (car s)))))
              sort-spec))
(print (cons 'insertion-sort r-isort))

;; Quicksort: two partition holes; only complementary predicates keep every
;; element (perm? kills the rest — e.g. lo=<, hi=> drops duplicates of the
;; pivot, which is exactly what the (7 7 7) test list is there to catch).
(define qsort-sketch
  '(letrec ((qs (lambda (l)
                  (if (null? l) (quote ())
                      (let ((p (car l)) (r (cdr l)))
                        (append (qs (filter (lambda (y) (?? lo)) r))
                                (cons p (qs (filter (lambda (y) (?? hi)) r)))))))))
     qs))
(define r-qsort
  (synth-fill qsort-sketch
              (list (list 'lo '((> y p) (>= y p) (< y p) (<= y p)))
                    (list 'hi '((> y p) (>= y p) (< y p) (<= y p))))
              sort-spec))
(print (cons 'quicksort r-qsort))

;; ── The synthesized sorts actually sort ──────────────────────────────────
(define isort-fn (eval (cadr r-isort)))
(define qsort-fn (eval (cadr r-qsort)))
(print (list 'isort-run (isort-fn '(9 -3 5 0 5 1))))
(print (list 'qsort-run (qsort-fn '(9 -3 5 0 5 1))))
(print (list 'agree (equal? (isort-fn '(8 6 7 5 3 0 9))
                            (qsort-fn '(8 6 7 5 3 0 9)))))

;; ── Proposer-driven loop (the LLM seat, scripted — no demos, no server) ──
;; Attempt 1 proposes a wrong comparison; the rejection (with its
;; counterexample) comes back as feedback; attempt 2 corrects it.
(define (scripted-proposer attempt feedback)
  (if (null? feedback)
      '((base (list x)) (cmp (> x (car s))))
      '((base (list x)) (cmp (< x (car s))))))
(define r-loop
  (synth-with-proposer isort-sketch '() sort-spec scripted-proposer 5))
(print (list 'proposer-loop (car r-loop) 'bindings (caddr r-loop)))

;; A failing proposer must exhaust attempts, not crash
(define r-fail
  (synth-with-proposer isort-sketch '() sort-spec
                       (lambda (a fb) '((base s) (cmp (= x (car s))))) 2))
(print (list 'proposer-gives-up (car r-fail)))

;; ── The LLM-reply extractor, on canned prose (no server needed) ─────────
;; Models reason out loud and echo the sketch; the extractor must skip
;; every non-bindings sexp and keep the LAST valid bindings alist.
(define canned
  "I need to fill the holes. The sketch is (cond ((null? s) (?? base)) ...).\nFor base, (list x) makes sense. For cmp, (< x (car s)).\nFinal answer:\n((base (list x)) (cmp (< x (car s))))")
(print (list 'extract-from-prose (synth-extract-bindings canned '(base cmp))))
(print (list 'extract-rejects-junk
             (equal? #f (synth-extract-bindings "no bindings anywhere ( just ) noise" '(base cmp)))))

(print "SYNTH TESTS DONE")
