;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; list_bench.lisp — list-representation benchmarks (v0.32.0 O(1)-cdr work).
;; Timings, not golden output — do NOT add to run_tests.sh.
;;
;; Recorded on the reference machine (release build):
;;   v0.31.0: cdr-walk-30k 6.39 s   (cdr copied the tail — O(n²) traversal)
;;   v0.32.0: cdr-walk-30k 0.028 s  (LSlice offset cdr — ~230×)
;;   v0.33.0 (Rc lambda fields): fib25 0.195→0.166 s, cons-build-30k
;;   15.9→10.7 s, drone x-axis proof 2.99→2.66 s — lambda values no longer
;;   deep-copy params/body on every lookup/call
;;   v0.34.0 (leaf fast path in eval): fib25 0.166→0.154 s, let-500k
;;   0.638→0.573 s, drone x-axis proof 2.66→2.33 s — Symbol/Number args no
;;   longer clone an Expr (String alloc) per evaluation
;;   v0.35.0 (let bindings by reference): let-500k 0.573→0.527 s, drone
;;   x-axis proof 2.33→2.25 s — no bindings Vec / name+init clones / body
;;   to_vec per let evaluation
;;   v0.36.0 (native check-exhaustive): a defrust-compiled property sweeps
;;   by direct call, parallel across cores >=16k states (RUSTY_CE_THREADS
;;   overrides). Drone x-axis proof, 79,992 states: interpreted 2.25 s ->
;;   native serial 2.7 ms (~840x) -> native parallel 1.2 ms (~1,890x).
;;   v0.53.0 (amortized-O(1) cons — LSlice::prepend with the exposure-floor
;;   guard, env.rs): cons-build-10k 0.891 -> 0.0084 s (~106x), linear at
;;   scale (100k 84 ms, 1M 871 ms; the old asymptote put 1M at ~2.5 h).
;;   fib25/cdr-walk/let-500k unchanged; symreg_bench -4%, agent_bench -7%.
;;   Aliased tails (cons onto a cdr, double cons onto one list) still copy
;;   — checked by adversarial aliasing tests; goldens bit-identical.

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
