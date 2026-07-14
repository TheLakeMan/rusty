;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; symreg_bench.lisp — Rusty side of the 4.1 deliverable benchmark.
;; 3 problems × 10 seeds, pop 120 × max 60 generations (symreg defaults).
;; Success = training MSE < 1e-10. Mirrored by symreg_gplearn_bench.py.
;;
;; v0.38.0 native fitness fast path (sr-eval-mse): -27% (measured split of the
;; remainder: fitness ~35%, crossover+mutation ~50%, selection/size ~15%).
;; v0.39.0 native GP tree surgery (sr-size/sr-get/sr-put builtins): the tree
;; ops were ~O(n^2) per crossover/mutation interpreted (sr-get/sr-put recompute
;; sr-size on each sibling subtree) and are hit again by the selection score
;; and both parsimony guards -- so the natives beat the 50% estimate by a lot.
;; Same machine as the 0.38.0 run: 16.7 s -> 3.2 s (-81%), results bit-identical
;; (expected_symreg.txt unchanged). Cumulative from the pre-0.38 baseline
;; (~23.4 s -> 3.2 s, ~7.3x). Also measured and REJECTED (0.38.0): tail-call
;; frame reuse in the eval trampoline (fib +-0%, 5M tail loop ~-3%, symreg
;; ~-1.5% -- under the 5% bar; the v0.33 frame-map pool already owns that win).

(load "symreg.lisp")

(define (make-data f xs) (map (lambda (x) (list (list x) (f x))) xs))
(define (frange a b step)
  (if (> a b) '() (cons a (frange (+ a step) b step))))

(define quad  (lambda (x) (+ (* x x) (* 2 x) 1)))
(define koza1 (lambda (x) (+ (expt x 4) (expt x 3) (* x x) x)))
(define bivar (lambda (x y) (+ (* x y) x)))

(define quad-data  (make-data quad  (frange -2 2 0.25)))
(define koza-data  (make-data koza1 (frange -1 1 0.1)))
(define grid '((-2 1) (-1 3) (0 2) (1 -1) (2 4) (3 -2) (-3 -1) (2 -3)))
(define bivar-data (map (lambda (p) (list p (bivar (car p) (cadr p)))) grid))

(define (run-problem name data vars seeds)
  (let loop ((s 1) (wins 0) (total-ms 0))
    (if (> s seeds)
        (begin
          (print (list name 'success wins '/ seeds 'total-ms total-ms))
          wins)
        (begin
          (symreg-seed! s)
          (let ((t0 (now-micros)))
            (let ((r (symreg data vars)))
              (let ((ms (/ (- (now-micros) t0) 1000)))
                (print (list name 'seed s 'mse (cadr r) 'gen (caddr r) 'ms ms))
                (loop (+ s 1)
                      (if (< (cadr r) 1e-10) (+ wins 1) wins)
                      (+ total-ms ms)))))))))

(run-problem 'quadratic quad-data  '(x) 10)
(run-problem 'koza-1    koza-data  '(x) 10)
(run-problem 'bivar     bivar-data '(x y) 10)
(print "RUSTY SYMREG BENCH DONE")
