;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; simplex-test.lisp — golden test for simplex.lisp.
;; Tableau simplex (Bland's rule) cross-checked against brute-force vertex
;; enumeration over a tiny LP grid. Known-answer fixtures have integer optima
;; (exact, portable); the exhaustive check compares objectives within ε and
;; prints only verdicts. Only + - * / — no libm.

(load "simplex.lisp")

;; ── Known-answer: max 3x₁+2x₂ s.t. x₁+x₂≤4, x₁+3x₂≤6 → (4 0), z=12 ────────
(define sol (lp-simplex (list (list 1 1) (list 1 3)) (list 4 6) (list 3 2)))
(print (list 'lp-optimal (lp-cert-get sol 'x) 'z (lp-cert-get sol 'z)))

;; ── Unbounded: max x₁ with x₁ unconstrained above (zero column) ───────────
(print (list 'unbounded (lp-status (lp-simplex (list (list 0 1) (list 0 1)) (list 2 2) (list 1 0)))))

;; ── Degenerate LP (redundant constraints): Bland's rule must terminate ────
(print (list 'degenerate (lp-simplex (list (list 1 1) (list 1 1)) (list 2 2) (list 1 1))))

;; ── Exhaustive: simplex ≡ brute vertex enumeration over the whole grid ────
;; c=(1 1), every A over {0,1}⁴ and b over {1,2}² — 64 LPs, each solved twice.
(print (list 'agrees-verified (verify-simplex-agrees (list 1 1) (list 0 1) (list 1 2))))

;; ── The wrong claim "the optimum is always 0" is refused with a witness ───
(define wrong (verify-simplex-wrong (list 1 1) (list 0 1) (list 1 2)))
(print (list 'wrong-refuted 'count (length wrong) 'first (car wrong)))

(print "SIMPLEX TESTS DONE")
