;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; list_bench.lisp — list-representation benchmarks (v0.32.0 O(1)-cdr work).
;; Timings, not golden output — do NOT add to run_tests.sh.
;;
;; Recorded on the reference machine (release build):
;;   v0.31.0: cdr-walk-30k 6.39 s   (cdr copied the tail — O(n²) traversal)
;;   v0.32.0: cdr-walk-30k 0.028 s  (LSlice offset cdr — ~230×)
;;   cons-build-30k ~16 s both — cons still copies (documented; build with
;;   accumulate+reverse or range, both linear)

(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(print (list 'fib25 (time (fib 25))))

(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))
(print (list 'cons-build-10k (time (length (build 10000 '())))))

(define big (range 0 30000))
(define (walk xs n) (if (null? xs) n (walk (cdr xs) (+ n 1))))
(print (list 'cdr-walk-30k (time (walk big 0))))

(define (letloop i acc) (if (= i 0) acc (let ((a (+ acc 1)) (b 2)) (letloop (- i 1) (+ a 0)))))
(print (list 'let-500k (time (letloop 500000 0))))

(print (list 'map-30k (time (length (map (lambda (x) (* x 2)) big)))))
