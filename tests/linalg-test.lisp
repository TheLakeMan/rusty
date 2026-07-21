;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; linalg-test.lisp — golden test for linalg.lisp.
;; LU-style determinant / solve / residual with certificates, plus exhaustive
;; checks over tiny integer grids. Fixtures keep elimination on exact dyadic
;; values (pivots ±1/±2, triangular / diagonal systems), so every printed
;; number is exact and IEEE-portable — no libm anywhere.

(load "linalg.lisp")

;; ── Determinant known-answers (exact) ─────────────────────────────────────
(print (list 'det-2x2      (mat-det (list (list 2 1) (list 1 2)))))            ; 3
(print (list 'det-3x3-tri  (mat-det (list (list 2 0 0) (list 1 2 0) (list 0 1 2)))))  ; 8
(print (list 'det-singular (mat-det (list (list 1 2) (list 2 4)))))           ; pivot-failure

;; ── Solve known-answer: exact dyadic x, residual EXACTLY 0 ────────────────
(define As (list (list 2 1) (list 0 2)))
(define sol (mat-solve As (list 4 6)))
(print (list 'solve-x (la-get sol 'x) 'residual (residual As (la-get sol 'x) (list 4 6))))
;; A singular system is a NAMED failure, not a NaN.
(print (list 'solve-singular (la-status (mat-solve (list (list 1 1) (list 1 1)) (list 2 2)))))

;; ── Exhaustive: LU det == closed form over the whole {-1,0,1,2} 4-D grid ──
(print (list 'det-grid-verified (verify-det2 (list -1 0 1 2))))
;; The wrong claim "det is always 1" is refused; show the count + the first
;; witness (check-exhaustive's odometer order is deterministic).
(define wrong (verify-det2-wrong (list -1 0 1 2)))
(print (list 'det-wrong-refuted 'count (length wrong) 'first (car wrong)))

;; ── Exhaustive: solve residual is 0 for every b in the grid, for this A ───
(print (list 'solve-grid-verified (verify-solve-consistent As (list 0 1 2 3))))

(print "LINALG TESTS DONE")
