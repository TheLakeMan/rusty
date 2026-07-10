;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; symreg_bench.lisp — Rusty side of the 4.1 deliverable benchmark.
;; 3 problems × 10 seeds, pop 120 × max 60 generations (symreg defaults).
;; Success = training MSE < 1e-10. Mirrored by symreg_gplearn_bench.py.

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
