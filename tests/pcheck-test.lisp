;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; pcheck-test.lisp — golden for pcheck.lisp (Phase D: parallel check-exhaustive
;; over the proc-pmap multi-process seam). Asserts the VERDICT is bit-identical
;; to serial check-exhaustive and independent of shard/worker count. NEVER a
;; timing — parallelism is proven for CORRECTNESS here; speed lives in
;; benchmarks/pcheck_bench.lisp (not in the suite).

(load "pcheck.lisp")

;; ── a real verified workload: bounded-horizon corridor-robot safety ─────────
;; For EVERY start position, simulate an H-step rollout and assert the robot
;; never leaves the corridor [0, wall]. This is the shape of a real safety proof
;; (shouzhong's certify-plant in miniature), not a toy predicate — the per-point
;; cost is a whole rollout, which is what makes many processes worth it.
;;
;; The plant lives BOTH as real defines here (so the in-process serial baseline
;; below is a genuine independent oracle) AND as `plant` source that crosses to
;; each child. The (equal? serial parallel) assertions are exactly what guard
;; the two copies against drift: edit one and not the other and the golden bites.
(define wall 20)
(define (safe? x) (and (>= x 0) (<= x wall)))
(define (ctrl-safe x) (if (< x 10) 1 (if (> x 10) -1 0)))   ; nudge to centre
(define (ctrl-reckless x) (if (> x 14) 5 (ctrl-safe x)))    ; shove +5 near wall
(define (rollout-safe? x0 h ctrl)
  (let loop ((x x0) (k 0))
    (if (> k h) #t
        (if (not (safe? x)) #f (loop (+ x (ctrl x)) (+ k 1))))))

(define plant "
(define wall 20)
(define (safe? x) (and (>= x 0) (<= x wall)))
(define (ctrl-safe x) (if (< x 10) 1 (if (> x 10) -1 0)))
(define (ctrl-reckless x) (if (> x 14) 5 (ctrl-safe x)))
(define (rollout-safe? x0 h ctrl)
  (let loop ((x x0) (k 0))
    (if (> k h) #t
        (if (not (safe? x)) #f (loop (+ x (ctrl x)) (+ k 1))))))
")

(define domain (list (range 0 21)))            ; every valid start position

;; ── VERIFIED: the safe controller keeps the robot in the corridor ───────────
(define prop-safe '(lambda (x0) (rollout-safe? x0 40 ctrl-safe)))
(define serial-safe (check-exhaustive (eval prop-safe) domain))
(define par-safe-1 (pcheck-exhaustive prop-safe domain 1 30 plant))
(define par-safe-4 (pcheck-exhaustive prop-safe domain 4 30 plant))
(define par-safe-7 (pcheck-exhaustive prop-safe domain 7 30 plant))
(println (list 'safe-serial serial-safe))
(println (list 'safe-parallel-verdict par-safe-4))
(println (list 'safe-equal-serial (equal? serial-safe par-safe-4)))
(println (list 'safe-worker-independent
               (and (equal? par-safe-1 par-safe-4)
                    (equal? par-safe-4 par-safe-7))))

;; ── REFUTED: the reckless controller drives some starts through the wall ────
(define prop-wild '(lambda (x0) (rollout-safe? x0 40 ctrl-reckless)))
(define serial-wild (check-exhaustive (eval prop-wild) domain))
(define par-wild-1 (pcheck-exhaustive prop-wild domain 1 30 plant))
(define par-wild-4 (pcheck-exhaustive prop-wild domain 4 30 plant))
(define par-wild-8 (pcheck-exhaustive prop-wild domain 8 30 plant))
(println (list 'wild-serial serial-wild))
(println (list 'wild-parallel par-wild-4))
(println (list 'wild-equal-serial (equal? serial-wild par-wild-4)))
(println (list 'wild-order-preserved
               (and (equal? par-wild-1 par-wild-4)
                    (equal? par-wild-4 par-wild-8))))

;; ── HONEST SCOPE: a shard that cannot finish is NOT a false 'verified ───────
;; One start position sends the plant into an infinite loop; that shard times
;; out and poisons the whole verdict (absence of a counterexample from a shard
;; that never ran is not evidence of its absence).
(define hang "
(define (hang-if-zero x) (if (= x 0) (hang-if-zero x) #t))
")
(define prop-hang '(lambda (x0) (hang-if-zero x0)))
(define hang-verdict (pcheck-exhaustive prop-hang (list (range 0 6)) 6 1 hang))
(println (list 'hang-incomplete-not-verified (pcheck-incomplete? hang-verdict)))
(println (list 'hang-verdict hang-verdict))

(println "PCHECK TESTS DONE")
