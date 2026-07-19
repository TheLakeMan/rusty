;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; llm_volume.lisp — volume / latency / no-leak harness for the `llm` builtin.
;; Manual (needs a live llama-server on :8080); NOT a golden. See ./README.md.
;;
;; Fires N sequential llm calls through the one shared tokio runtime and reports
;; success count + latency spread. Healthy = every call succeeds, latency stays
;; flat (no degradation), the process never hangs. `max_tokens` is passed here
;; (16) but the bare/2-arg forms are exercised by the arg-form check at the end.

(define n 20)
(define oks 0)
(define lo 1.0e9)
(define hi 0.0)
(define sum 0.0)

(define (run i)
  (let* ((t0 (now-micros))
         (r  (try-catch (llm (format "What is ~a plus ~a? Reply with only the number." i i) 0.0 16)
                        (e) (list 'error e)))
         (dt (/ (- (now-micros) t0) 1000000.0)))
    (when (< dt lo) (set! lo dt))
    (when (> dt hi) (set! hi dt))
    (set! sum (+ sum dt))
    (when (and (string? r) (> (string-length r) 0)) (set! oks (+ oks 1)))
    (println (format "  call ~a: ~a s -> ~a" i dt r))))

(let loop ((i 1)) (when (<= i n) (run i) (loop (+ i 1))))
(println (format "VOLUME: ok=~a/~a  min=~a  avg=~a  max=~a s" oks n lo (/ sum n) hi))

;; arg-form coverage (the v0.62.0 max_tokens fix: 1- and 2-arg must not send null)
(println (list 'one-arg (llm "What is 5+5? Reply with only the number.")))
(println (list 'two-arg (llm "What is 6+6? Reply with only the number." 0.2)))
(println (list 'three-arg (llm "What is 7+7? Reply with only the number." 0.2 16)))
