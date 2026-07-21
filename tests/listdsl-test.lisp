;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; listdsl-test.lisp — golden test for listdsl.lisp.
;; A comprehension DSL that fuses map/filter pipelines into a single pass, the
;; fusion PROVEN equivalent to the naive multi-pass version by check-exhaustive,
;; with the allocation win shown as a deterministic cell count.

(load "listdsl.lisp")

;; ── Comprehension sugar ────────────────────────────────────────────────────
;; [x*x for x in 1..5 if x>2]
(print (list 'comprehension (lc (* x x) (x <- (list 1 2 3 4 5)) (> x 2))))
;; multiple guards: [x for x in 0..9 if even and >3]
(print (list 'two-guards
             (lc x (x <- (list 0 1 2 3 4 5 6 7 8 9)) (= (mod x 2) 0) (> x 3))))

;; ── Fused == naive, and the allocation win, on a 2-map pipeline ────────────
(define g (lambda (x) (+ x 1)))
(define f (lambda (x) (* x 2)))
(define p2 (list (list 'map g) (list 'map f)))   ; xs -> map (+1) -> map (*2)
(define xs (list 1 2 3))

(lc-reset!) (define naive-out (naive-run p2 xs)) (define naive-cells (lc-count))
(lc-reset!) (define fused-out (fused-run p2 xs)) (define fused-cells (lc-count))
(print (list 'same-result (equal? naive-out fused-out) naive-out))
;; naive allocates one list per stage (2*3=6); fused allocates one output (3).
(print (list 'cells 'naive naive-cells 'fused fused-cells))

;; ── Exhaustive fusion proof over all lists of len<=3 over {0,1,2} ──────────
(define dom (lists-upto (list 0 1 2) 3))
(print (list 'domain-size (length dom)))
(print (list 'fusion-verified (verify-fusion p2 dom)))
;; a filter+map pipeline too
(define pfm (list (list 'filter (lambda (x) (> x 0))) (list 'map (lambda (x) (* x x)))))
(print (list 'filter-map-fusion-verified (verify-fusion pfm dom)))

;; ── Algebraic fusion laws ──────────────────────────────────────────────────
(print (list 'map-map-law (verify-map-map-law g f dom)))
(print (list 'filter-filter-law
             (verify-filter-filter-law (lambda (x) (> x 0)) (lambda (x) (< x 2)) dom)))
(print (list 'sum-map-fusion (verify-sum-map-fusion (lambda (x) (* x x)) dom)))

;; ── Negative control: map/filter reorder is NOT a valid fusion ─────────────
(define bad (verify-reorder-map-filter f (lambda (x) (> x 2)) dom))
(print (list 'reorder-refused 'count (length bad) 'first (car bad)))

(print "LISTDSL TESTS DONE")
