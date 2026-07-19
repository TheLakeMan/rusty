;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; stress_bench.lisp — load/scaling stress harness (v0.61.0).
;; Timings, NOT golden output — do NOT add to run_tests.sh.
;;
;; Exercises the subsystems that SURVIVE deep load (found robust in the
;; 2026-07-18 crash-hunt) at large scale, to catch throughput/memory
;; regressions.  Every workload here stays clear of the native-stack cliffs
;; documented at the bottom; those cliffs are reproduced separately by
;; benchmarks/stress_crash_probe.sh (they core-dump by design and so can
;; never live in a golden or an in-process bench).
;;
;; Run:  cargo run --release -- benchmarks/stress_bench.lisp
;; Read the printed "time: X s" rows; compare against your own prior run on
;; the same machine state (quote ratios/crossovers, never absolutes — the
;; numbers here are machine-dependent and rot).

(println "== stress_bench ==")

;; --- lists: O(1) cons build + O(1) cdr traversal at scale ---
(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))
(println "cons-build+length 1M:")
(time (length (build 1000000 '())))
(println "cons-build+length 5M:")
(time (length (build 5000000 '())))

;; --- reverse (allocates a fresh 1M-element buffer) ---
(println "reverse 1M:")
(time (length (reverse (range 0 1000000))))

;; --- map over 1M (iterative builtin, closure applied per element) ---
(println "map*2 over 1M:")
(time (length (map (lambda (x) (* x 2)) (range 0 1000000))))

;; --- TCO loop: 10M tail calls, constant space ---
(define (spin n acc) (if (= n 0) acc (spin (- n 1) (+ acc 1))))
(println "tco-spin 10M:")
(time (spin 10000000 0))

;; --- strings: 100k appends building a 1M-char string ---
(define (rep n s acc) (if (= n 0) acc (rep (- n 1) s (string-append acc s))))
(println "string-append -> 1M chars:")
(time (string-length (rep 100000 "abcdefghij" "")))

;; --- knowledge graph: 500k triples, then a query ---
(kg-clear!)
(define (kgfill n) (if (= n 0) 'done (begin (kg-add! (list 'n n) 'is 'num) (kgfill (- n 1)))))
(println "kg-add! 500k triples:")
(time (kgfill 500000))
(println "kg-query over 500k:")
(time (length (kg-query '((?s is num)))))
(kg-clear!)

;; --- multi-process seam under fan-out: 100 embarrassingly-parallel children ---
;; (the one real multicore path; measures spawn/collect at width, result order
;;  is deterministic regardless of worker count)
(define codes (map (lambda (i) "(let loop ((k 0) (a 0)) (if (= k 100000) a (loop (+ k 1) (+ a 1))))")
                   (range 0 100)))
(println "proc-pmap 100 children x8 workers:")
(time (length (proc-pmap codes 30 8)))

(println "== stress_bench done ==")
