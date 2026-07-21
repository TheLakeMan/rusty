;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; csp-test.lisp — golden test for csp.lisp.
;; Two classic finite-domain problems: N-queens (solution counts) and graph
;; coloring (satisfiable count, and an UNSAT instance proven exhaustively).
;; Everything is integer/symbol data over declared finite domains, so both
;; the backtracking solver and the check-exhaustive proof are exact and
;; deterministic — no timings, no randomness.

(load "csp.lisp")

;; ── N-queens: one queen per column; the variable's value is its row. A
;; pairwise constraint per column pair forbids equal rows and diagonals. ──
(define (queens-csp n)
  (let ((cols (range 0 n)))
    (csp-make cols
      (map (lambda (c) (cons c (range 0 n))) cols)
      (csp-append-all
        (map (lambda (i)
               (csp-append-all
                 (map (lambda (j)
                        (if (< i j)
                            (list (list (list i j)
                                        (lambda (ri rj)
                                          (and (not (= ri rj))
                                               (not (= (abs (- ri rj)) (abs (- i j))))))))
                            '()))
                      cols)))
             cols)))))

;; Known solution counts (2, 10, 4) — the exact, textbook answers.
(print (list 'queens-counts
             'n4 (csp-count (queens-csp 4))
             'n5 (csp-count (queens-csp 5))
             'n6 (csp-count (queens-csp 6))))

;; First solution + stable enumeration order (same CSP twice => same list).
(print (list 'n4-first (csp-solve (queens-csp 4))))
(print (list 'n4-order-stable
             (equal? (csp-solutions (queens-csp 4)) (csp-solutions (queens-csp 4)))))

;; The smart backtracker agrees with the dumb brute-cartesian solver.
(print (list 'n5-verify (csp-verify (queens-csp 5))))

;; ── Graph 3-coloring of a triangle (a,b,c all mutually adjacent) ─────────
(define (triangle-csp colors)
  (csp-make '(a b c)
    (list (cons 'a colors) (cons 'b colors) (cons 'c colors))
    (list (list '(a b) (lambda (x y) (not (equal? x y))))
          (list '(b c) (lambda (x y) (not (equal? x y))))
          (list '(a c) (lambda (x y) (not (equal? x y)))))))

;; 3 colors on a triangle => 3! = 6 proper colorings.
(print (list 'triangle-3color-count (csp-count (triangle-csp '(r g b)))))

;; ── UNSAT: a triangle needs 3 colors, so 2 colors is unsatisfiable — and
;; that is a PROOF (whole tree exhausted / check-exhaustive 'verified), not
;; a sample. ──────────────────────────────────────────────────────────────
(print (list 'triangle-2color-solve (csp-solve (triangle-csp '(r g)))
             'unsat? (csp-unsat? (triangle-csp '(r g)))))
(print (list 'triangle-2color-proven-unsat (csp-prove-unsat (triangle-csp '(r g)))))

;; The dual: on a SATISFIABLE instance, check-exhaustive's counterexamples
;; ARE the solutions — 6 of them for the 3-coloring.
(print (list 'triangle-3color-witnessed
             (length (csp-prove-unsat (triangle-csp '(r g b))))))

(print "CSP TESTS DONE")
