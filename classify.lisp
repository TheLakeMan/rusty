;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; classify.lisp — a classifier whose predictions are PROVEN to respect a
;; declared logical invariant over the ENTIRE finite feature domain, using
;; std.lisp's `implies` / `logic-loss` to GUIDE fitting and check-exhaustive to
;; CERTIFY the result. Pure Lisp, zero interpreter changes.
;;
;; The deliverable: "a classification model that respects logical invariants."
;; The Rusty angle is the gap between GUIDED and PROVEN. logic-loss (std.lisp,
;; crisp) is a penalty that biases parameter selection toward the invariant;
;; but a fit that is 100% accurate on the training data can still VIOLATE the
;; invariant off-distribution. Only running the invariant over every point of
;; the finite feature domain — check-exhaustive — certifies that zero
;; violations remain.
;;
;; The example is hierarchical labels: `dog` and `mammal`, features
;; (fur bark) ∈ {0,1}². Invariant: (implies dog mammal) — a dog is a mammal.
;; The training set contains no furless barker (0 1), so an independent
;; best-fit that keys `dog` on bark alone is DATA-PERFECT yet predicts
;; dog-but-not-mammal at (0 1). Adding logic-loss over the whole domain forces
;; a `dog` rule that also requires fur — still data-perfect, and now the
;; exhaustive check returns 'verified.
;;
;; CLAIM DISCIPLINE: "the classifier respects the declared invariant at EVERY
;; point of the declared finite feature domain." NOT "a good classifier",
;; nothing about accuracy or generalization beyond the declared domain, and
;; "guided by logic-loss" is never conflated with "proven" — the proof is the
;; check-exhaustive verdict, not the training.

;; ── Features & finite domain ────────────────────────────────────────────────
(define (fur x)  (car x))
(define (bark x) (cadr x))
(define feature-domain
  (list (list 0 0) (list 0 1) (list 1 0) (list 1 1)))

;; ── Model = (mammal-rule dog-rule); a rule = (name predicate) ───────────────
(define (rule-name r) (car r))
(define (rule-pred r) (cadr r))
(define (mammal-rule model) (car model))
(define (dog-rule    model) (cadr model))
(define (mammal? model x) ((rule-pred (mammal-rule model)) x))
(define (dog?    model x) ((rule-pred (dog-rule    model)) x))
(define (classify model x)
  (list (list 'mammal (mammal? model x)) (list 'dog (dog? model x))))
(define (model-names model)
  (list 'mammal (rule-name (mammal-rule model)) 'dog (rule-name (dog-rule model))))

;; ── The invariant: (implies dog mammal) — from std.lisp ─────────────────────
(define (invariant-ok? model x) (implies (dog? model x) (mammal? model x)))

;; logic-loss (std.lisp) = 0 when the invariant holds at x, else 1.
(define (logic-cost model domain)
  (sum (map (lambda (x) (logic-loss (invariant-ok? model x))) domain)))

(define (invariant-violations model domain)
  (filter (lambda (x) (not (invariant-ok? model x))) domain))

;; PROOF: the invariant holds at EVERY point of the finite feature domain.
(define (verify-invariant model domain)
  (check-exhaustive (lambda (x) (invariant-ok? model x)) (list domain)))

;; ── Candidate rule pools ────────────────────────────────────────────────────
(define mammal-pool
  (list (list 'fur      (lambda (x) (= (fur x) 1)))
        (list 'bark     (lambda (x) (= (bark x) 1)))
        (list 'fur|bark (lambda (x) (or (= (fur x) 1) (= (bark x) 1))))))
(define dog-pool
  (list (list 'bark     (lambda (x) (= (bark x) 1)))
        (list 'fur&bark  (lambda (x) (and (= (fur x) 1) (= (bark x) 1))))))

;; ── Training data: (features desired-mammal desired-dog) ────────────────────
;; NOTE the absence of any (0 1) row — no furless barker is ever observed.
(define train-data
  (list (list (list 1 1) 1 1)     ; dog:  fur + bark
        (list (list 1 0) 1 0)     ; cat:  fur, quiet
        (list (list 0 0) 0 0)))   ; rock: neither
(define (row-x row)      (car row))
(define (row-mammal row) (cadr row))
(define (row-dog row)    (caddr row))

;; ── Losses ──────────────────────────────────────────────────────────────────
(define (bool->int b) (if b 1 0))
;; # of training points a rule misclassifies for a given label column.
(define (rule-data-loss rule want-of data)
  (sum (map (lambda (row)
              (bool->int (not (= (bool->int ((rule-pred rule) (row-x row)))
                                 (want-of row)))))
            data)))

;; ── Independent best fit (data accuracy only — invariant-blind) ─────────────
(define (best-by cost-fn pool)                 ; first pool element minimizing cost
  ;; foldl calls (fn elem acc): r = candidate element, best = running winner.
  (foldl (lambda (r best) (if (< (cost-fn r) (cost-fn best)) r best))
         (car pool) (cdr pool)))
(define (naive-fit)
  (list (best-by (lambda (r) (rule-data-loss r row-mammal train-data)) mammal-pool)
        (best-by (lambda (r) (rule-data-loss r row-dog    train-data)) dog-pool)))

;; ── Logic-guided fit: data-loss + λ·logic-cost over the whole domain ────────
(define (all-combos)
  (apply append
    (map (lambda (m) (map (lambda (d) (list m d)) dog-pool)) mammal-pool)))
(define (model-cost model lam)
  (+ (rule-data-loss (mammal-rule model) row-mammal train-data)
     (rule-data-loss (dog-rule    model) row-dog    train-data)
     (* lam (logic-cost model feature-domain))))
(define (logic-fit lam)
  (let ((combos (all-combos)))
    (foldl (lambda (m best) (if (< (model-cost m lam) (model-cost best lam)) m best))
           (car combos) (cdr combos))))

;; total training misclassifications (both labels) — for reporting accuracy.
(define (data-loss model)
  (+ (rule-data-loss (mammal-rule model) row-mammal train-data)
     (rule-data-loss (dog-rule    model) row-dog    train-data)))
