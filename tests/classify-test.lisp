;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; classify-test.lisp — golden test for classify.lisp.
;; A hierarchical-label classifier (dog ⇒ mammal). The naive data-perfect fit
;; violates the invariant off-distribution; logic-loss over the whole domain
;; forces a still-data-perfect fit that check-exhaustive certifies clean.

(load "classify.lisp")

;; ── Naive fit: accurate on training data, invariant-blind ──────────────────
(define naive (naive-fit))
(print (list 'naive-model (model-names naive)))
(print (list 'naive-data-loss (data-loss naive)))              ; 0 — data-perfect
(print (list 'naive-logic-cost (logic-cost naive feature-domain)))  ; 1 violation
(print (list 'naive-violations (invariant-violations naive feature-domain)))
;; check-exhaustive REFUTES: the off-training point (0 1) is a real witness.
(define nv (verify-invariant naive feature-domain))
(print (list 'naive-verify 'count (length nv) 'first (car nv)))

;; ── Logic-guided fit: same data accuracy, invariant respected ──────────────
(define guided (logic-fit 10))
(print (list 'guided-model (model-names guided)))
(print (list 'guided-data-loss (data-loss guided)))            ; still 0
(print (list 'guided-logic-cost (logic-cost guided feature-domain)))  ; 0
;; check-exhaustive CERTIFIES: invariant holds at every domain point.
(print (list 'guided-verify (verify-invariant guided feature-domain)))

;; ── The classifier in action on the previously-unseen point (0 1) ──────────
(print (list 'naive@0-1  (classify naive  (list 0 1))))   ; dog, not mammal — bad
(print (list 'guided@0-1 (classify guided (list 0 1))))   ; neither — invariant-safe

(print "CLASSIFY TESTS DONE")
