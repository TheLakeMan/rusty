;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; pcheck_bench.lisp — serial vs PARALLEL check-exhaustive (Phase D: proc-pmap).
;; Timings, NOT golden output — do NOT add to run_tests.sh.
;;
;; The point Phase D has to earn: many CHILD PROCESSES are the one real multicore
;; path off the Rc-based single-threaded core, and on a big verification sweep
;; that pays off — WITHOUT changing the verdict. Every row below re-asserts
;; (equal? serial parallel); a run where any verdict differs is a failed
;; benchmark, not a faster one.
;;
;; HONEST SCOPE: each child pays interpreter STARTUP. So the win only shows once
;; the per-shard COMPUTE dominates that startup. The crossover section makes the
;; loss visible on a tiny domain — below the crossover, use serial check-exhaustive.
;; Quote the ratio + the crossover from a re-run on your own machine; wall-clock
;; absolutes rot (they are machine- and load-dependent — check `nproc` and
;; `ps aux --sort=-%cpu` first).
;;
;; Reference run (4-core machine, release build, 8000 starts x horizon 250):
;;   serial            ~2884 ms   verified
;;   shards 1          ~2823 ms   1.0x   (one child — no parallelism)
;;   shards 2          ~1767 ms   1.6x
;;   shards 4          ~1140 ms   2.5x   (== core count)
;;   shards 8          ~1060 ms   2.7x   (oversubscribed; diminishing)
;;   crossover: tiny domain (8 starts x horizon 3) serial ~0.06 ms vs parallel
;;   ~12 ms — startup dominates, serial wins by ~200x. Same verdict every row.

(load "pcheck.lisp")

;; ── the workload: bounded-horizon corridor safety over a big start domain ───
(define wall 1000000)
(define (safe? x) (and (>= x 0) (<= x wall)))
(define (ctrl x) (if (< x 500000) 1 -1))
(define (rollout-safe? x0 h)
  (let loop ((x x0) (k 0))
    (if (> k h) #t (if (not (safe? x)) #f (loop (+ x (ctrl x)) (+ k 1))))))

;; the same plant as source for the children
(define plant "
(define wall 1000000)
(define (safe? x) (and (>= x 0) (<= x wall)))
(define (ctrl x) (if (< x 500000) 1 -1))
(define (rollout-safe? x0 h)
  (let loop ((x x0) (k 0))
    (if (> k h) #t (if (not (safe? x)) #f (loop (+ x (ctrl x)) (+ k 1))))))
")

(define (ms t0 t1) (/ (- t1 t0) 1000.0))

(define (time-it thunk)
  (let ((t0 (now-micros)))
    (let ((r (thunk)))
      (list r (ms t0 (now-micros))))))

;; ── big sweep: serial vs parallel at 1/2/4/8 shards ─────────────────────────
(define horizon 250)
(define big-dom (list (range 0 8000)))
(define prop '(lambda (x0) (rollout-safe? x0 250)))

(println (list 'workload 'starts 8000 'horizon horizon))
(newline)

(define ser (time-it (lambda () (check-exhaustive (eval prop) big-dom))))
(define serial-verdict (car ser))
(println (list 'serial-ms (cadr ser) 'verdict serial-verdict))

(for-each
  (lambda (n)
    (let* ((par (time-it (lambda () (pcheck-exhaustive prop big-dom n 60 plant))))
           (verdict (car par))
           (t (cadr par)))
      (println (list 'shards n
                     'ms t
                     'speedup (/ (cadr ser) t)
                     'same-verdict (equal? verdict serial-verdict)))))
  (list 1 2 4 8))

(newline)
;; ── crossover: a TINY domain where child startup dominates and parallel LOSES ─
(println 'crossover-tiny-domain)
(define tiny-dom (list (range 0 8)))
(define tprop '(lambda (x0) (rollout-safe? x0 3)))
(define tser (time-it (lambda () (check-exhaustive (eval tprop) tiny-dom))))
(define tpar (time-it (lambda () (pcheck-exhaustive tprop tiny-dom 4 60 plant))))
(println (list 'serial-ms (cadr tser)))
(println (list 'parallel4-ms (cadr tpar)
               'same-verdict (equal? (car tser) (car tpar))))
(println (list 'note 'below-crossover-serial-wins-use-check-exhaustive))
(newline)
(println "PCHECK BENCH DONE")
