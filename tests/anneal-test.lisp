;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; anneal-test.lisp — golden test for anneal.lisp.
;; Exhaustive TSP oracle on 4 cities; SA under fixed seed returns a fixed
;; cost (never claimed optimal). Printed values are integer costs, booleans,
;; or check-exhaustive verdicts. libm `exp` only inside accept boolean.

(load "anneal.lisp")

;; Symmetric 4-city distances (integer). Optimal tour cost is hand-known.
;;    0 1 2 3
;; 0  0 2 9 10
;; 1  2 0 6 4
;; 2  9 6 0 3
;; 3 10 4 3 0
;; Tour (0 1 3 2): 2+4+3+9 = 18
;; Tour (0 1 2 3): 2+6+3+10 = 21
;; Tour (0 2 1 3): 9+6+4+10 = 29
;; Tour (0 2 3 1): 9+3+4+2 = 18
;; Tour (0 3 1 2): 10+4+6+9 = 29
;; Tour (0 3 2 1): 10+3+6+2 = 21
;; Oracle min = 18
(define D (list (list 0 2 9 10)
                (list 2 0 6 4)
                (list 9 6 0 3)
                (list 10 4 3 0)))

(print (list 'oracle-min (tsp-oracle-min D)))
(print (list 'tour-0213 (tsp-tour-cost D (list 0 1 3 2))))
(print (list 'tour-0123 (tsp-tour-cost D (list 0 1 2 3))))

;; Exhaustive over the REAL tour domain: the oracle min is a lower bound for
;; every tour (verified); claiming min+1 is refused and the witnesses ARE the
;; two optimal tours; reversal symmetry proven over the same domain.
(print (list 'oracle-lower-bound (verify-oracle-lower-bound D)))
(define obw (verify-oracle-bound-wrong D))
(print (list 'oracle-bound-wrong-refuted 'count (length obw) 'witnesses (map car obw)))
(print (list 'tour-reversal (verify-tour-reversal D)))

;; SA under seed 1: pin the found cost (deterministic under this stream).
;; Claim: "found cost C under seed S" — NOT optimal.
(anneal-seed! 1)
(define sa (anneal-run (list 0 1 2 3)
                       (lambda (t) (tsp-tour-cost D t))
                       tsp-neighbor 10 (/ 95 100) 40))
(define sa-cost (cadr sa))
(print (list 'sa-seed1-cost sa-cost))
(print (list 'sa-ge-oracle (>= sa-cost (tsp-oracle-min D))))

;; Replay: same seed + same budget → same cost
(anneal-seed! 1)
(define sa2 (anneal-run (list 0 1 2 3)
                        (lambda (t) (tsp-tour-cost D t))
                        tsp-neighbor 10 (/ 95 100) 40))
(print (list 'sa-replay (equal? sa-cost (cadr sa2))))

;; Log is data: first entry has step 0
(print (list 'log-len (length (caddr sa))
             'first-step (car (car (caddr sa)))))

;; Subset-sum oracle: weights (3 5 7), target 10 → min residual 0 (3+7)
(print (list 'subset-oracle (subset-oracle-min (list 3 5 7) 10)))

(print "ANNEAL TESTS DONE")
