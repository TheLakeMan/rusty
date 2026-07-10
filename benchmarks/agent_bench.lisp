;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; agent_bench.lisp — Phase 3.3 deliverable benchmark.
;;
;; Three agent workloads, all deterministic (no LLM):
;;   1. orchestration  — 4000 message hops through the actor scheduler
;;   2. swarm          — proposer/verifier/certifier synthesis (swarm.lisp's
;;                       flow) driven 30 rounds
;;   3. agent-compute  — a dispatcher/worker/collector pipeline where each
;;                       work item computes fib(20); run once with the
;;                       worker's tool interpreted ("naive interpretation")
;;                       and once defrust-compiled
;;
;; Run against an old binary for interpreter-only comparison, and read the
;; naive-vs-compiled pair on the same binary for the compilation speedup.
;; Usage: rusty benchmarks/agent_bench.lisp

(define (bench label thunk)
  (let ((t0 (now-micros)))
    (let ((r (thunk)))
      (print (list label 'ms (/ (- (now-micros) t0) 1000)))
      r)))

;; ── 1. orchestration: ping-pong, 4000 hops ───────────────────────────────
(agent-reset!)
(agent-spawn 'ping (lambda (m) (if (> m 0) (send! 'pong (- m 1)) '())))
(agent-spawn 'pong (lambda (m) (if (> m 0) (send! 'ping (- m 1)) '())))
(bench 'orchestration-4000-hops
  (lambda () (begin (send! 'ping 4000) (run-agents))))

;; ── 2. swarm-style verified synthesis, 30 rounds ─────────────────────────
;; The verifier's brain: static gates then exhaustive checking, same
;; machinery as swarm.lisp, driven repeatedly.
(define abs-spec
  (list (list 'pure #t)
        (list 'domains (list (list -3 -1 0 2 5)))
        (list 'invariant
              (lambda (f x) (and (>= (f x) 0)
                                 (or (= (f x) x) (= (f x) (- 0 x))))))))
(define (swarm-round)
  (begin
    ;; wrong candidate rejected, right candidate verified — both paths
    (verify-candidate (eval-string "(lambda (x) x)") abs-spec)
    (verify-candidate (eval-string "(lambda (x) (if (< x 0) (- 0 x) x))") abs-spec)))
(define (swarm-rounds n)
  (if (= n 0) 'done (begin (swarm-round) (swarm-rounds (- n 1)))))
(bench 'swarm-verify-30-rounds (lambda () (swarm-rounds 30)))

;; ── 3. agent pipeline with a numeric core: 50 × fib(20) ─────────────────
(define (fib-i n) (if (< n 2) n (+ (fib-i (- n 1)) (fib-i (- n 2)))))

(define (run-pipeline fib-fn)
  (agent-reset!)
  (define total 0)
  (agent-spawn 'dispatcher
    (lambda (n) (if (> n 0)
                    (begin (send! 'worker 20) (send! 'dispatcher (- n 1)))
                    '())))
  (agent-spawn 'worker    (lambda (n) (send! 'collector (fib-fn n))))
  (agent-spawn 'collector (lambda (v) (set! total (+ total v))))
  (send! 'dispatcher 50)
  (run-agents)
  total)

(define naive-total (bench 'agent-compute-naive (lambda () (run-pipeline fib-i))))

;; same pipeline, worker's numeric core compiled (only available if this
;; binary has defrust — all do since 1.2; kernel caching since 3.3)
(defrust fib-c (n) (if (< n 2) n (+ (fib-c (- n 1)) (fib-c (- n 2)))))
(define compiled-total (bench 'agent-compute-compiled (lambda () (run-pipeline fib-c))))

(print (list 'totals-agree (equal? naive-total compiled-total) naive-total))
(print "AGENT BENCH DONE")
