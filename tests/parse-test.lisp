;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; parse-test.lisp — golden test for parse.lisp.
;; Parser combinators, ambiguity as data, exhaustive A^≤k language match
;; against a hand table. Printed values are symbols, trees, booleans, or
;; check-exhaustive verdicts — no floats.

(load "parse.lisp")

;; ── Tiny language: S = a b*   (one 'a followed by zero-or-more 'b) ────────
(define p-ab*
  (parse-seq (parse-lit 'a) (parse-many (parse-lit 'b))))

(define (accept-ab* s)
  (parse-ok? (parse-run p-ab* s)))

;; Hand reference table as a predicate (same language).
(define (ref-ab* s)
  (and (not (null? s))
       (equal? (car s) 'a)
       (all? (lambda (t) (equal? t 'b)) (cdr s))))

;; Known-answer parses
(print (list 'ok-a (parse-run p-ab* (list 'a))))
(print (list 'ok-abb (parse-run p-ab* (list 'a 'b 'b))))
(print (list 'err-empty (parse-run p-ab* '())))
(print (list 'err-ba (parse-run p-ab* (list 'b 'a))))
(print (list 'err-unconsumed (parse-run p-ab* (list 'a 'b 'c))))

;; ── Exhaustive A={a,b}, k=3 vs hand reference ─────────────────────────────
(print (list 'lang-verified
             (verify-lang-equiv accept-ab* ref-ab* (list 'a 'b) 3)))
;; Wrong reference (always reject) → refused with a witness that should accept.
(print (list 'lang-refuted
             (verify-lang-equiv-wrong accept-ab* (lambda (s) #f) (list 'a 'b) 3)))

;; ── Ambiguity detector: two alts that both accept "a" ─────────────────────
(define p-a1 (parse-map (lambda (x) 'tree1) (parse-lit 'a)))
(define p-a2 (parse-map (lambda (x) 'tree2) (parse-lit 'a)))
(print (list 'ambiguous-a
             (parse-ambiguous? (list p-a1 p-a2) (list 'a))
             (parse-all-accepting (list p-a1 p-a2) (list 'a))))
(print (list 'unambiguous-b
             (parse-ambiguous? (list p-a1 p-a2) (list 'b))))

;; ── Left-recursion policy (documented): right-recursive form via many ─────
;; (parse-many does not left-recurse). Smoke: many b on bbb.
(define p-bs (parse-many (parse-lit 'b)))
(print (list 'many-b (parse-run p-bs (list 'b 'b 'b))))

(print "PARSE TESTS DONE")
