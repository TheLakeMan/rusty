;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; pbt-test.lisp — golden test for pbt.lisp.
;; The teaching example: a buggy "sort" that runs ONE bubble pass. Sample
;; mode finds a failing list and shrinks it to a minimal counterexample;
;; EXHAUST mode proves the correct insertion sort over a whole finite
;; domain and refutes the buggy one with the SAME minimal witness. Sort
;; keys are small integers — everything is deterministic (seeded PRNG, no
;; timings, no randomness leaking into output).

(load "pbt.lisp")

;; ── The functions under test ─────────────────────────────────────────────
;; Buggy: one bubble pass only. It's a permutation of the input, so the
;; failure is purely unsortedness (a clean single-property counterexample).
(define (bubble-pass lst)
  (cond ((null? lst) '())
        ((null? (cdr lst)) lst)
        ((> (car lst) (cadr lst))
         (cons (cadr lst) (bubble-pass (cons (car lst) (cddr lst)))))
        (else (cons (car lst) (bubble-pass (cdr lst))))))
;; Correct: insertion sort.
(define (isort-insert x lst)
  (cond ((null? lst) (list x))
        ((<= x (car lst)) (cons x lst))
        (else (cons (car lst) (isort-insert x (cdr lst))))))
(define (isort lst) (foldl isort-insert '() lst))

;; ── The properties (boolean predicates over one input) ───────────────────
(define (sorted? lst)
  (cond ((null? lst) #t) ((null? (cdr lst)) #t)
        ((<= (car lst) (cadr lst)) (sorted? (cdr lst))) (else #f)))
(define (count-eq x lst) (count (lambda (y) (equal? y x)) lst))
(define (perm? a b)
  (and (= (length a) (length b))
       (all? (lambda (x) (= (count-eq x a) (count-eq x b))) a)))

(define (prop-bubble lst) (sorted? (bubble-pass lst)))            ; FAILS
(define (prop-isort  lst) (and (sorted? (isort lst))             ; HOLDS
                               (perm? (isort lst) lst)))

;; ── (1) SAMPLE mode: find a counterexample, shrink it to minimal ─────────
(define gen (gen-list (gen-int 0 9) 6))
(pbt-seed! 42)
(print (list 'sample (pbt-check prop-bubble gen 200)))

;; ── (2) Seed stability: same seed => same original => same minimal. A
;; different seed finds a (possibly different) case, but still fails. ──────
(pbt-seed! 42)
(define run-a (pbt-check prop-bubble gen 200))
(pbt-seed! 42)
(define run-b (pbt-check prop-bubble gen 200))
(print (list 'seed-stable (equal? run-a run-b)))
(pbt-seed! 7)
(print (list 'other-seed-still-fails
             (equal? (nth (pbt-check prop-bubble gen 200) 2) (quote failed))))

;; ── (3) The UPGRADE: sampling can only say 'passed; on a small finite
;; domain the SAME property is exhaustively 'verified — a real proof. ──────
(define dom (pbt-lists '(0 1 2) 3))          ; every list len 0..3 over {0,1,2}
(pbt-seed! 5)
(print (list 'isort-sampled  (nth (pbt-check prop-isort gen 200) 2)))   ; passed
(print (list 'isort-verified (pbt-verify prop-isort dom)))              ; verified

;; ── (4) Exhaust REFUTES the buggy sort — and the first counterexample
;; shrinks to the SAME minimal the sampler found. Both roads meet. ────────
(print (list 'bubble-refuted (pbt-verify prop-bubble dom)))

;; ── (5) Multi-argument exhaustive proof (raw cartesian product) ──────────
(print (list 'plus-commutes
             (pbt-verify* (lambda (a b) (= (+ a b) (+ b a)))
                          (list (range -2 3) (range -2 3)))))
(print (list 'minus-refuted
             (pbt-verify* (lambda (a b) (= (- a b) (- b a)))
                          (list (range 0 3) (range 0 3)))))

;; ── (6) Claim discipline: a property that RAISES counts as a failure
;; (boolean-strict — only #t holds), and shrinking drives it to the
;; minimal offending input, the empty list. ───────────────────────────────
(define (prop-head-nonneg lst) (>= (car lst) 0))    ; raises on '()
(pbt-seed! 3)
(print (list 'raise-is-failure
             (nth (pbt-check prop-head-nonneg (gen-list (gen-int 0 5) 4) 200) 2)))

(print "PBT TESTS DONE")
