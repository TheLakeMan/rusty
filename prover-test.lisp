;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; prover-test.lisp — golden test for prover.lisp (bounded proof assistant).
;; Deterministic: no randomness, no LLM.

(load "prover.lisp")

;; ── 1. auto proves a quantified invariant ────────────────────────────────
(print (defproof abs-nonneg
         (forall ((x (-5 -3 -1 0 2 4))) (>= (abs x) 0))
         (auto)))

;; ── 2. structured script: intros / intro / split / exhaust by hand ──────
(print (defproof max-bounds
         (forall ((a (-2 0 3)) (b (-1 1 4)))
           (implies (> a b)
                    (and (= (max a b) a) (>= (max a b) b))))
         (step intros)
         (step intro)
         (step split)
         (step exhaust)
         (step exhaust)))

;; ── 3. combinators: or/repeat compose like LCF tactics ──────────────────
(print (defproof max-comm
         (forall ((a (-2 0 3 7)) (b (-1 1 4)))
           (= (max a b) (max b a)))
         (tactic-or (step split)          ; wrong tactic: raises, falls over
                    (tactic-seq (step intros) (step exhaust)))))

;; ── 4. lemma reuse: a proved theorem discharges a matching goal ──────────
(print (defproof abs-nonneg-again
         (forall ((x (-5 -3 -1 0 2 4))) (>= (abs x) 0))
         (step (lemma 'abs-nonneg))))

;; ── 5. the full circle: PROVE the sort that 4.2 SYNTHESIZED ─────────────
(load "synth.lisp")
(define (sorted? l)
  (or (null? l) (null? (cdr l))
      (and (<= (car l) (cadr l)) (sorted? (cdr l)))))
(define (count-of x l) (length (filter (lambda (y) (= y x)) l)))
(define (perm? a b)
  (and (= (length a) (length b))
       (all? (lambda (x) (= (count-of x a) (count-of x b))) b)))
(define sort-spec
  (list (list 'pure #t)
        (list 'domains (list (list '() '(1) '(2 1) '(3 1 2) '(7 7 7))))
        (list 'invariant (lambda (f l) (and (sorted? (f l)) (perm? (f l) l))))))
(define r-isort
  (synth-fill '(letrec ((insert (lambda (x s)
                                  (cond ((null? s) (?? base))
                                        ((?? cmp) (cons x s))
                                        (else (cons (car s) (insert x (cdr s)))))))
                        (isort  (lambda (l)
                                  (if (null? l) (quote ())
                                      (insert (car l) (isort (cdr l)))))))
                 isort)
              (list (list 'base '((quote ()) s (list x)))
                    (list 'cmp  '((> x (car s)) (= x (car s)) (< x (car s)))))
              sort-spec))
(define isort (eval (cadr r-isort)))
(print (list 'synthesized (car r-isort)))
;; ...and now prove it — over a LARGER domain than it was synthesized on:
(print (defproof isort-correct
         (forall ((l (() (1) (2 1) (1 2 3) (3 1 2) (5 -1 4 0)
                      (9 8 7 6 5) (2 2 1) (7 7 7) (0 -1 0 -1))))
           (and (sorted? (isort l)) (perm? (isort l) l)))
         (auto)))

;; ── 6. a false claim is refuted with a concrete counterexample ──────────
(print (list 'refuted
             (find-counterexample
               '(forall ((x (-5 -3 -1 0 2 4))) (> (abs x) 0)))))
;; ...and defproof on it reports unproved, never registers
(print (defproof abs-strictly-positive
         (forall ((x (-5 -3 -1 0 2 4))) (> (abs x) 0))
         (auto)))
(print (list 'not-registered
             (equal? #f (try-catch (theorem 'abs-strictly-positive) (e) #f))))

;; ── 7. interactive session ────────────────────────────────────────────────
(print (prove 'demorgan-bounded
              '(forall ((p (#t #f)) (q (#t #f)))
                 (equal? (not (and p q)) (or (not p) (not q))))))
(print (tac! intros))
(print (tac! exhaust))
(print (qed))
(print (list 'theorem-recorded (theorem 'demorgan-bounded)))

(print "PROVER TESTS DONE")
