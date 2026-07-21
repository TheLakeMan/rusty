;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; root-test.lisp — golden test for root.lisp.
;; Root finding with certificates as data, plus an exhaustive localization
;; proof. Every printed value comes from + - * / only (no libm), so the floats
;; are IEEE-deterministic and portable; verdicts are check-exhaustive results.

(load "root.lisp")

(define (f-sqrt2 x)  (- (* x x) 2))          ; root √2 in [1,2]
(define (df-sqrt2 x) (* 2 x))

;; ── Bisection: a certificate, and an honest 'no-bracket refusal ───────────
(print (list 'bisect-sqrt2 (bisect f-sqrt2 1 2 (/ 1 100) 50)))
(print (list 'no-sign-change (bisect f-sqrt2 2 3 (/ 1 100) 50)))   ; both f>0

;; ── Newton: converges on a simple root, reports max-iters on a hard one ───
(print (list 'newton-sqrt2 (newton f-sqrt2 df-sqrt2 2 (/ 1 100) 20)))
;; (x-3)² has a DOUBLE root — Newton crawls; a bad start + few steps → max-iters.
(define (f-dbl x)  (* (- x 3) (- x 3)))
(define (df-dbl x) (* 2 (- x 3)))
(print (list 'newton-hard (newton f-dbl df-dbl 0 (/ 1 1000) 3)))

;; ── Bracket inventory: every sign-change sub-interval on a grid ───────────
;; x²-2 on [-3,3] split into 6 unit cells → the two cells straddling ±√2.
(print (list 'brackets (bracket-search f-sqrt2 -3 3 6)))

;; ── Exhaustive localization: proven, then refuted on the same grid ────────
;; Bisection localizes the root within eps=1/8 for every root position in the
;; grid when given 20 iterations ('verified); with only 2 iterations the bracket
;; is still too wide, and every position becomes a counterexample witness.
(print (list 'localizes-verified (verify-localizes (/ 1 8) 20 (list 0 1 2 3))))
(print (list 'localizes-refuted  (verify-localizes (/ 1 8) 2  (list 0 1 2 3))))

;; ── Certificate accessors are honest data ─────────────────────────────────
(define c (bisect f-sqrt2 1 2 (/ 1 100) 50))
(print (list 'status (cert-status c) 'iters (cert-get c 'iters)))

(print "ROOT TESTS DONE")
