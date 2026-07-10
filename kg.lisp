;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; kg.lisp — inference rules over the native knowledge graph (Phase 1.3).
;; The store/query/N-Triples core is Rust (src/kg.rs, kg-* builtins);
;; this layer adds forward-chaining rules in pure Lisp, same library
;; pattern as the actor/prover layers.
;;
;;   (kg-rule! body head)   body: list of (s p o) patterns; head: one
;;                          (s p o) template — shared ?vars bind across
;;   (kg-infer!)            forward-chain all rules to fixpoint,
;;                          returns the number of new triples derived
;;   (kg-rules-clear!)

(define *kg-rules* '())
(define (kg-rules-clear!) (set! *kg-rules* '()))
(define (kg-rule! body head)
  (set! *kg-rules* (cons (list body head) *kg-rules*)))

(define (kg-subst term binds)
  (let ((hit (assoc term binds)))
    (if hit (cadr hit) term)))

(define (kg-apply-rule rule)            ; → number of NEW triples
  (let ((body (car rule)) (head (cadr rule)))
    (foldl (lambda (binds acc)
             (if (kg-add! (kg-subst (car head) binds)
                          (kg-subst (cadr head) binds)
                          (kg-subst (caddr head) binds))
                 (+ acc 1)
                 acc))
           0
           (kg-query body))))

(define (kg-infer!)
  (let loop ((total 0))
    (let ((new (foldl (lambda (r acc) (+ acc (kg-apply-rule r))) 0 *kg-rules*)))
      (if (= new 0) total (loop (+ total new))))))
