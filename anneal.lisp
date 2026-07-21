;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; anneal.lisp — seeded simulated annealing / hill-climb with an exhaustive
;; optimum ORACLE on tiny discrete domains. Pure Lisp, zero interpreter changes.
;;
;; Every accept/reject is recorded as data in a trajectory log. The KEY
;; verification is not "SA found the optimum" — SA is NEVER called optimal.
;; Instead: check-exhaustive (or a full enumeration helper) recovers the true
;; minimum cost over a declared finite set (4-city TSP / tiny subset-sum), and
;; SA under a fixed seed returns a FIXED cost C that can be cross-checked
;; (C ≥ oracle-min always; equality is luck, not a claim).
;;
;; CLAIM DISCIPLINE:
;;   SA "found cost C under seed S"
;;   oracle "is the minimum over the declared finite set"
;; NEVER "SA is optimal", "converged", or "global minimum via annealing".

;; ── Seeded LCG ────────────────────────────────────────────────────────────
(define *anneal-seed* 1)
(define (anneal-seed! n) (set! *anneal-seed* n))
(define (anneal-rand)
  (set! *anneal-seed* (mod (+ (* *anneal-seed* 1103515245) 12345) 2147483648))
  (/ *anneal-seed* 2147483648))
(define (anneal-rand-int n)
  (floor (* (anneal-rand) n)))

;; ── Trajectory log entry: (step T cost accepted? move) ────────────────────
;; Public runners return (list final-state final-cost log).

;; Metropolis accept: always if dE≤0; else if u < exp(-dE/T).
;; ⚠️ exp is libm — used only inside a boolean decision, never printed.
(define (anneal-accept? dE T)
  (if (<= dE 0) #t
      (if (<= T 0) #f
          (< (anneal-rand) (exp (/ (- 0 dE) T))))))

;; Generic SA: state, cost-fn, neighbor-fn, T0, cool, steps.
;; neighbor-fn: state -> (list new-state move-tag)
(define (anneal-run state0 cost-fn neighbor-fn T0 cool steps)
  (define (go s c T k log)
    (if (>= k steps)
        (list s c (reverse log))
        (let* ((nm (neighbor-fn s))
               (s2 (car nm))
               (mv (cadr nm))
               (c2 (cost-fn s2))
               (dE (- c2 c))
               (acc (anneal-accept? dE T))
               (entry (list k T (if acc c2 c) acc mv)))
          (if acc
              (go s2 c2 (* T cool) (+ k 1) (cons entry log))
              (go s c (* T cool) (+ k 1) (cons entry log))))))
  (go state0 (cost-fn state0) T0 0 '()))

;; Hill-climb: only accept improving (or equal) moves; no temperature.
(define (hill-climb state0 cost-fn neighbor-fn steps)
  (define (go s c k log)
    (if (>= k steps)
        (list s c (reverse log))
        (let* ((nm (neighbor-fn s))
               (s2 (car nm))
               (mv (cadr nm))
               (c2 (cost-fn s2))
               (acc (<= c2 c))
               (entry (list k 0 (if acc c2 c) acc mv)))
          (if acc
              (go s2 c2 (+ k 1) (cons entry log))
              (go s c (+ k 1) (cons entry log))))))
  (go state0 (cost-fn state0) 0 '()))

;; ── 4-city TSP ────────────────────────────────────────────────────────────
;; Cities 0..3; tour is a permutation list starting with fixed city 0
;; (reduce symmetry). Distance matrix as nested lists; dist i j = (nth (nth D i) j).
(define (tsp-dist D i j) (nth (nth D i) j))

(define (tsp-tour-cost D tour)
  ;; tour is a cycle: sum edges tour[i]->tour[i+1] plus last->first
  (define (go xs acc)
    (if (null? (cdr xs)) acc
        (go (cdr xs) (+ acc (tsp-dist D (car xs) (cadr xs))))))
  (+ (go tour 0) (tsp-dist D (last tour) (car tour))))

;; All tours: permutations of {1,2,3} prefixed with 0.
(define (anneal-insertions x lst)
  (define (go pref rest acc)
    (let ((acc2 (cons (append pref (cons x rest)) acc)))
      (if (null? rest) (reverse acc2)
          (go (append pref (list (car rest))) (cdr rest) acc2))))
  (go '() lst '()))

(define (anneal-permutations lst)
  (if (null? lst) (list '())
      (foldl (lambda (perm acc)
               (append acc (anneal-insertions (car lst) perm)))
             '()
             (anneal-permutations (cdr lst)))))

(define (tsp-all-tours n)
  ;; n cities labeled 0..n-1; fix start at 0
  (map (lambda (p) (cons 0 p))
       (anneal-permutations
         (let loop ((i 1) (acc '()))
           (if (>= i n) (reverse acc)
               (loop (+ i 1) (cons i acc)))))))

;; Exhaustive optimum oracle: min cost over all tours in the declared set.
(define (tsp-oracle-min D)
  (let ((tours (tsp-all-tours (length D))))
    (foldl (lambda (t best)
             (let ((c (tsp-tour-cost D t)))
               (if (< c best) c best)))
           (tsp-tour-cost D (car tours))
           (cdr tours))))

;; Neighbor: swap two random positions in the tour (not index 0 — keep start fixed).
(define (tsp-neighbor tour)
  (let* ((n (length tour))
         (i (+ 1 (anneal-rand-int (- n 1))))
         (j (+ 1 (anneal-rand-int (- n 1))))
         (vi (nth tour i))
         (vj (nth tour j)))
    (define (set-at lst k v)
      (if (= k 0) (cons v (cdr lst))
          (cons (car lst) (set-at (cdr lst) (- k 1) v))))
    (list (set-at (set-at tour i vj) j vi) (list 'swap i j))))

;; ── Tiny subset-sum (optional second oracle domain) ───────────────────────
;; State = bit mask as list of 0/1 of length n; cost = |sum selected - target|.
(define (subset-cost weights target bits)
  (define (go ws bs acc)
    (if (null? ws) acc
        (go (cdr ws) (cdr bs)
            (+ acc (* (car ws) (car bs))))))
  (abs (- (go weights bits 0) target)))

(define (subset-neighbor bits)
  (let* ((i (anneal-rand-int (length bits)))
         (flipped (if (= (nth bits i) 0) 1 0)))
    (define (set-at lst k v)
      (if (= k 0) (cons v (cdr lst))
          (cons (car lst) (set-at (cdr lst) (- k 1) v))))
    (list (set-at bits i flipped) (list 'flip i))))

;; Enumerate all 2^n bit vectors (n small).
(define (subset-all-masks n)
  (if (= n 0) (list '())
      (let ((rest (subset-all-masks (- n 1))))
        (append (map (lambda (m) (cons 0 m)) rest)
                (map (lambda (m) (cons 1 m)) rest)))))

(define (subset-oracle-min weights target)
  (let ((masks (subset-all-masks (length weights))))
    (foldl (lambda (m best)
             (let ((c (subset-cost weights target m)))
               (if (< c best) c best)))
           (subset-cost weights target (car masks))
           (cdr masks))))

;; ── Exhaustive verification over the REAL tour domain ─────────────────────
;; The oracle's minimum is a true lower bound: EVERY tour in the declared set
;; costs at least it — check-exhaustive over the actual tours, so a
;; refutation would name the offending tour.
(define (verify-oracle-lower-bound D)
  (let ((m (tsp-oracle-min D)))
    (check-exhaustive
      (lambda (t) (>= (tsp-tour-cost D t) m))
      (list (tsp-all-tours (length D))))))

;; Claiming a bound one above the oracle minimum must be refused — and the
;; witnesses are exactly the OPTIMAL tours (the refutation names them).
(define (verify-oracle-bound-wrong D)
  (let ((m (tsp-oracle-min D)))
    (check-exhaustive
      (lambda (t) (>= (tsp-tour-cost D t) (+ m 1)))
      (list (tsp-all-tours (length D))))))

;; For a SYMMETRIC distance matrix, reversing a tour (start pinned at 0)
;; leaves its cost unchanged — proven over every tour in the set.
(define (verify-tour-reversal D)
  (check-exhaustive
    (lambda (t)
      (= (tsp-tour-cost D t)
         (tsp-tour-cost D (cons 0 (reverse (cdr t))))))
    (list (tsp-all-tours (length D)))))
