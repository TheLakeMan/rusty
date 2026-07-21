;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; stats.lisp — descriptive stats + EXACT small-n permutation tests + seeded
;; bootstrap CI. Pure Lisp, zero interpreter changes.
;;
;; Descriptive helpers (mean / population variance / sum) are ordinary IEEE
;; arithmetic. The verification bite is finite-population: a two-sample
;; mean-difference p-value is k/n! over an ENUMERATED set of permutations
;; (via check-exhaustive over that finite list), and a bootstrap CI is the
;; quantile pair of a FIXED seeded LCG draw stream — replay is the audit.
;;
;; CLAIM DISCIPLINE — the caveat is the crack:
;;   "under this null enumeration, statistic T has two-sided p = k/n!"
;;   "under seed S and B resamples, the bootstrap mean CI endpoints are …"
;; NEVER "significant", "true effect", "unbiased estimator", or asymptotic
;; p-values. A p-value here is an exact count on a declared finite set of
;; label shuffles — nothing more.

;; ── Seeded LCG (same recurrence family as pbt/symreg) ─────────────────────
;; State is an integer; (stats-rand) returns U in [0,1) as f64. Deterministic
;; given the seed and the draw-order — never reorder draws between runs.
(define *stats-seed* 42)
(define (stats-seed! n) (set! *stats-seed* n))
(define (stats-rand)
  (set! *stats-seed* (mod (+ (* *stats-seed* 1103515245) 12345) 2147483648))
  (/ *stats-seed* 2147483648))

;; ── Descriptive ───────────────────────────────────────────────────────────
(define (stats-sum xs) (foldl + 0 xs))
(define (stats-mean xs)
  (let ((n (length xs)))
    (if (= n 0) 0 (/ (stats-sum xs) n))))
;; Population variance (divide by n, not n-1) — declared, not "unbiased".
(define (stats-var xs)
  (let* ((m (stats-mean xs))
         (n (length xs)))
    (if (= n 0) 0
        (/ (foldl (lambda (x acc) (+ acc (* (- x m) (- x m)))) 0 xs) n))))

;; Absolute mean difference between two samples (two-sided statistic).
(define (stats-mean-diff a b)
  (abs (- (stats-mean a) (stats-mean b))))

;; ── Permutations (small n only — n! grows fast) ───────────────────────────
;; Insert x into every position of lst; returns a list of lists.
(define (stats-insertions x lst)
  (define (go pref rest acc)
    (let ((acc2 (cons (append pref (cons x rest)) acc)))
      (if (null? rest) (reverse acc2)
          (go (append pref (list (car rest))) (cdr rest) acc2))))
  (go '() lst '()))

(define (stats-permutations lst)
  (if (null? lst) (list '())
      (foldl (lambda (perm acc)
               (append acc (stats-insertions (car lst) perm)))
             '()
             (stats-permutations (cdr lst)))))

;; Split a combined list into first na elements and the rest (group A / B).
(define (stats-split-at n lst)
  (define (go k rest a-acc)
    (if (= k 0) (list (reverse a-acc) rest)
        (go (- k 1) (cdr rest) (cons (car rest) a-acc))))
  (go n lst '()))

;; Exact two-sample permutation test under the null "labels are exchangeable".
;; Returns an alist certificate:
;;   (status exact-perm) (n-perms N) (k K) (p P) (obs OBS)
;; where K is the number of permutations of the pooled sample whose
;; |mean(A')-mean(B')| is ≥ the observed statistic, A' = first |A| of the
;; shuffled pool, B' the rest. p = K/N with N = n!.
;; This is an EXACT count on the declared enumeration — not a Monte Carlo p.
(define (stats-perm-test a b)
  (let* ((na (length a))
         (pool (append a b))
         (obs (stats-mean-diff a b))
         (perms (stats-permutations pool))
         (n (length perms))
         (k (foldl (lambda (p acc)
                     (let* ((sp (stats-split-at na p))
                            (a2 (car sp))
                            (b2 (cadr sp)))
                       (if (>= (stats-mean-diff a2 b2) obs) (+ acc 1) acc)))
                   0 perms)))
    (list (list 'status 'exact-perm)
          (list 'n-perms n)
          (list 'k k)
          (list 'p (/ k n))
          (list 'obs obs))))

(define (stats-cert-get cert key)
  (let ((e (assoc key cert))) (if e (cadr e) #f)))

;; ── Seeded bootstrap CI for the mean ──────────────────────────────────────
;; Draw B resamples WITH replacement using the local LCG; return
;; (lo hi) = the empirical q-lo / q-hi quantiles of the B means.
;; Fixed seed + fixed B + fixed quantile rule → fixed endpoints (replay = audit).
;; Claim is only "under seed S and this stream", never a coverage guarantee.
(define (stats-sample-with-replacement xs n)
  (define (go k acc)
    (if (= k 0) acc
        (let ((i (floor (* (stats-rand) (length xs)))))
          (go (- k 1) (cons (nth xs i) acc)))))
  (go n '()))

(define (stats-bootstrap-means xs B)
  (define (go k acc)
    (if (= k 0) (reverse acc)
        (go (- k 1)
            (cons (stats-mean (stats-sample-with-replacement xs (length xs)))
                  acc))))
  (go B '()))

;; Sort ascending (insertion sort — no `sort` builtin).
(define (stats-insert-sorted x lst)
  (cond ((null? lst) (list x))
        ((<= x (car lst)) (cons x lst))
        (else (cons (car lst) (stats-insert-sorted x (cdr lst))))))
(define (stats-sort xs)
  (foldl (lambda (x acc) (stats-insert-sorted x acc)) '() xs))

;; Index of empirical quantile q in a sorted length-n list (0-based, clamp).
;; Uses floor(q*(n-1)) — a fixed rule, documented, not "the" quantile.
(define (stats-quantile-idx n q)
  (let ((i (floor (* q (- n 1)))))
    (cond ((< i 0) 0)
          ((>= i n) (- n 1))
          (else i))))

(define (stats-bootstrap-ci xs B q-lo q-hi seed)
  (stats-seed! seed)
  (let* ((ms (stats-sort (stats-bootstrap-means xs B)))
         (n (length ms))
         (lo (nth ms (stats-quantile-idx n q-lo)))
         (hi (nth ms (stats-quantile-idx n q-hi))))
    (list (list 'status 'bootstrap-ci)
          (list 'B B)
          (list 'seed seed)
          (list 'lo lo)
          (list 'hi hi))))

;; ── Exhaustive verification helpers ───────────────────────────────────────
;; (1) Mean is permutation-invariant: for every perm of a fixed list, the
;; mean equals the original mean. Domain = the enumerated permutations.
;; Right property → 'verified; wrong property (mean always 0) → refused with
;; the first non-zero-mean perm as witness.
(define (verify-mean-perm-invariant xs)
  (let ((m0 (stats-mean xs))
        (perms (stats-permutations xs)))
    (check-exhaustive
      (lambda (p) (= (stats-mean p) m0))
      (list perms))))

(define (verify-mean-always-zero xs)
  (let ((perms (stats-permutations xs)))
    (check-exhaustive
      (lambda (p) (= (stats-mean p) 0))
      (list perms))))

;; (2) Exact permutation-test count: for a declared (a b), the certificate's
;; k equals a hand-given expected-k. Proven by check-exhaustive over a
;; singleton domain that packages the fixture — boolean-strict.
(define (verify-perm-k a b expected-k)
  (check-exhaustive
    (lambda (_)
      (let ((c (stats-perm-test a b)))
        (= (stats-cert-get c 'k) expected-k)))
    (list (list #t))))

;; A deliberately wrong expected-k must be refused (witness is the singleton).
(define (verify-perm-k-wrong a b wrong-k)
  (check-exhaustive
    (lambda (_)
      (let ((c (stats-perm-test a b)))
        (= (stats-cert-get c 'k) wrong-k)))
    (list (list #t))))
