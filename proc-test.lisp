;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; proc-test.lisp — golden for the Phase A multi-process seam (proc-eval).
;; A child runs a FULL, separate rusty interpreter; parent and child share
;; nothing but bytes over pipes. Deterministic: every result and error string
;; is timing-independent, and the one timeout case asserts the OUTCOME (a
;; killed child) rather than a duration.

;; A plain computation comes back as (ok <printed-result>).
(println (list 'ok-simple (proc-eval "(+ 1 2)")))
;; The child is a full rusty — the stdlib (range/apply) is present.
(println (list 'ok-stdlib (proc-eval "(apply + (range 1 101))")))

;; A child that RAISES is data, not a parent crash: (error <stderr> <code>).
(println (list 'child-error (proc-eval "(car 5)")))
;; A child that never terminates is killed at the deadline: (timeout).
;; (spin) is tail-recursive, so TCO loops it forever — only the kill ends it.
(println (list 'timeout-killed (proc-eval "(define (spin) (spin)) (spin)" 1)))

;; Real memory isolation: a child mutating its OWN global cannot reach ours.
(define x 99)
(println (list 'child-result (proc-eval "(define x 1) (set! x 2) x")))
(println (list 'parent-x-unchanged x))

;; Effect honesty: proc-eval is surfaced by the SAME walker pkg-effects uses,
;; so a package that spawns subprocesses admits it.
(println (list 'effect-surfaced (check-effects (lambda (c) (proc-eval c)))))

;; A non-string program is refused as an error, never a crash.
(println (list 'needs-string (try-catch (proc-eval 42) (e) (list 'rejected e))))

(println "PROC TESTS DONE")
