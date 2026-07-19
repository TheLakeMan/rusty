;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; llm_proposer.lisp — verify-gated synthesis under a REAL model.
;; Manual (needs a live llama-server on :8080); NOT a golden. See ./README.md.
;;
;; `synthesize-verified` runs the 2.1 proof-by-checker loop: the llm-proposer
;; suggests a lambda, and only a candidate that passes the STATIC gates first
;; (check-effects for purity) and then check-exhaustive over the declared domain
;; is accepted. A wrong/hallucinated proposal must be REJECTED and fed back as a
;; counterexample — never accepted, never a crash. Observed live (Llama-3.1-8B):
;; double/square verify first try; x*x+x typically needs a couple feedback rounds
;; — which is the point: the checker rejects the wrong attempts.

(define (spec-double)
  (list (list 'pure #t) (list 'domains '((0 1 2 3 4 5)))
        (list 'invariant (lambda (f x) (= (f x) (* 2 x))))))
(define (spec-square)
  (list (list 'pure #t) (list 'domains '((0 1 2 3 4 5)))
        (list 'invariant (lambda (f x) (= (f x) (* x x))))))
(define (spec-x2plusx)
  (list (list 'pure #t) (list 'domains '((1 2 3 4 5 6)))
        (list 'invariant (lambda (f x) (= (f x) (+ (* x x) x))))))

(define (run label task spec)
  (let* ((t0 (now-micros))
         (r  (try-catch (synthesize-verified spec (llm-proposer task) 4)
                        (e) (list 'harness-error e)))
         (dt (/ (- (now-micros) t0) 1000000.0)))
    (println (format "~a (~a s): ~a" label dt
                     (if (equal? (car r) 'verified)
                         (list 'VERIFIED 'attempts (caddr r))
                         r)))))

(run 'double  "a lambda taking one integer x and returning x doubled"       (spec-double))
(run 'square  "a lambda taking one integer x and returning x squared"       (spec-square))
(run 'x2plusx "a lambda taking one integer x and returning x*x + x"          (spec-x2plusx))
