;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; interp-test.lisp — golden test for interp.lisp.
;; Lagrange / piecewise-linear interpolation with residuals on a DECLARED
;; verification grid. Fit nodes {-1,0,1} make Lagrange arithmetic exact
;; dyadic, so quadratic reconstruction is checked with exact `=` over a real
;; coefficient grid. Only + - * / — the printed Runge residuals are
;; division-only floats (IEEE-portable), never libm.

(load "interp.lisp")

;; ── Known-answer: interpolant through 3 samples of 2x²−x+3 is the poly ────
(define p (lambda (x) (+ (* 2 x x) (* -1 x) 3)))
(define nodes (interp-nodes-from p (list -1 0 1)))
(print (list 'nodes nodes))
(print (list 'lagrange-at-2 (lagrange-eval nodes 2) 'exact (p 2)))       ; extrapolates exactly too
(print (list 'lagrange-at--2 (lagrange-eval nodes -2) 'exact (p -2)))

;; ── Piecewise-linear reproduces a LINE exactly (incl. extended segment) ───
(define ln (interp-nodes-from (lambda (x) (+ (* 3 x) 1)) (list -1 0 1)))
(print (list 'plin-line-at-2 (plin-eval ln 2)))

;; ── Exhaustive: Lagrange reproduces EVERY quadratic over the coeff grid ───
;; (a b c) ∈ {-1,0,1}³, checked with exact = at every x in {-2,…,2}.
(print (list 'lagrange-quads-verified (verify-lagrange-quads (list -1 0 1))))

;; ── The same claim for piecewise-linear is REFUSED (witnesses have a≠0) ───
(define wrong (verify-plin-quads (list -1 0 1)))
(print (list 'plin-quads-refuted 'count (length wrong) 'first (car wrong)))

;; ── Runge demonstration: degree-4 residual >> piecewise on the midpoints ──
;; 1/(1+25x²) at 5 equispaced nodes — more degree is NOT less error. The
;; residuals are bounds on the DECLARED midpoint grid, not a continuous sup.
(define rr (runge-residuals))
(print (list 'runge rr))
(print (list 'degree-worse-than-piecewise
             (> (cadr (assoc 'lagrange rr)) (cadr (assoc 'piecewise rr)))))

(print "INTERP TESTS DONE")
