;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; perf_gate.lisp — CI performance-regression gate (sprint item).
;;
;; Ratios, not absolutes: shared CI runners have noisy, heterogeneous
;; clocks, but the RELATIVE speed of compiled vs interpreted execution is
;; a property of the implementation, not the machine. Thresholds sit far
;; below healthy values (defrust ~1000x, fusion ~29x locally), so only a
;; real regression trips them. Raises (nonzero exit) on breach.

(define (time-us thunk) (let ((t0 (now-micros))) (thunk) (- (now-micros) t0)))

;; ── Gate 1: defrust JIT must crush tree-walking ──────────────────────────
(define (fib-i n) (if (< n 2) n (+ (fib-i (- n 1)) (fib-i (- n 2)))))
(defrust fib-c (n) (if (< n 2) n (+ (fib-c (- n 1)) (fib-c (- n 2)))))
(fib-c 25)  ; warm the call path
(define ti (time-us (lambda () (fib-i 25))))
(define tc (max (time-us (lambda () (fib-c 25))) 1))
(define jit-ratio (floor (/ ti tc)))
(print (list 'gate-1 'defrust-speedup jit-ratio 'threshold 50))
(when (< jit-ratio 50)
  (error (format "PERF REGRESSION: defrust speedup ~ax < 50x" jit-ratio)))

;; ── Gate 2: kernel fusion must beat tree-walking the same lambda ─────────
(define big (lambda (x y) (+ (/ (* (+ x 1) (+ y 1)) (+ (* x x) 1)) (/ (* (+ x 2) (+ y 2)) (+ (* x x) 2)) (/ (* (+ x 3) (+ y 3)) (+ (* x x) 3)) (/ (* (+ x 4) (+ y 4)) (+ (* x x) 4)) (/ (* (+ x 5) (+ y 5)) (+ (* x x) 5)) (/ (* (+ x 6) (+ y 6)) (+ (* x x) 6)) (/ (* (+ x 7) (+ y 7)) (+ (* x x) 7)) (/ (* (+ x 8) (+ y 8)) (+ (* x x) 8)) (/ (* (+ x 9) (+ y 9)) (+ (* x x) 9)) (/ (* (+ x 10) (+ y 10)) (+ (* x x) 10)) (/ (* (+ x 11) (+ y 11)) (+ (* x x) 11)) (/ (* (+ x 12) (+ y 12)) (+ (* x x) 12)) (/ (* (+ x 13) (+ y 13)) (+ (* x x) 13)) (/ (* (+ x 14) (+ y 14)) (+ (* x x) 14)) (/ (* (+ x 15) (+ y 15)) (+ (* x x) 15)) (/ (* (+ x 16) (+ y 16)) (+ (* x x) 16)) (/ (* (+ x 17) (+ y 17)) (+ (* x x) 17)) (/ (* (+ x 18) (+ y 18)) (+ (* x x) 18)) (/ (* (+ x 19) (+ y 19)) (+ (* x x) 19)) (/ (* (+ x 20) (+ y 20)) (+ (* x x) 20)) (/ (* (+ x 21) (+ y 21)) (+ (* x x) 21)) (/ (* (+ x 22) (+ y 22)) (+ (* x x) 22)) (/ (* (+ x 23) (+ y 23)) (+ (* x x) 23)) (/ (* (+ x 24) (+ y 24)) (+ (* x x) 24)))))
(define bigk (graph-compile big))
(define (loop-call f n acc)
  (if (= n 0) acc (loop-call f (- n 1) (+ acc (f n 2.5)))))
(loop-call bigk 100 0)  ; warm
(define tw (time-us (lambda () (loop-call big  8000 0))))
(define tf (max (time-us (lambda () (loop-call bigk 8000 0))) 1))
(define fuse-ratio (floor (/ tw tf)))
(print (list 'gate-2 'fusion-speedup fuse-ratio 'threshold 3))
(when (< fuse-ratio 3)
  (error (format "PERF REGRESSION: fusion speedup ~ax < 3x" fuse-ratio)))
;; results must also agree exactly
(when (not (equal? (loop-call big 50 0) (loop-call bigk 50 0)))
  (error "CORRECTNESS REGRESSION: fused kernel diverges from tree-walk"))

(print "PERF GATES PASSED")
