;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; stats-test.lisp — golden test for stats.lisp.
;; Descriptive stats, exact small-n permutation p-values (enumerated n!),
;; and seeded bootstrap CI endpoints. Printed values are integers, exact
;; rationals from + - *, or check-exhaustive verdicts — bootstrap floats are
;; IEEE from + - * / only (no libm), so bit-stable across platforms.
;;
;; Claims under test: "under this null enumeration / this seed stream" —
;; NEVER "significant" or "true effect".

(load "stats.lisp")

;; ── Known-answer descriptive stats (integer-friendly) ─────────────────────
;; mean(1 2 3 4) = 10/4 = 2.5; population var = ((-1.5)²+(-0.5)²+(0.5)²+(1.5)²)/4 = 1.25
(print (list 'mean (stats-mean (list 1 2 3 4))))
(print (list 'var  (stats-var  (list 1 2 3 4))))
(print (list 'sum  (stats-sum  (list 1 2 3 4))))

;; ── Exact permutation test on a tiny two-sample fixture ───────────────────
;; A=(1 4) B=(2 3): pool has 4 distinct labels → 24 perms. Observed |mean
;; diff| = |2.5-2.5|=0, so EVERY perm has stat ≥ 0 → k=24, p=1.
;; (Equal group means under the null is the honest "no signal" fixture.)
(define cert-eq (stats-perm-test (list 1 4) (list 2 3)))
(print (list 'perm-eq-means
             (stats-cert-get cert-eq 'n-perms)
             (stats-cert-get cert-eq 'k)
             (stats-cert-get cert-eq 'p)
             (stats-cert-get cert-eq 'obs)))

;; A=(1 2) B=(9 10): obs = |1.5-9.5|=8. Only permutations that put both
;; small values in A (or both large — same |diff|) hit the extreme.
;; Hand count: positions for the two A slots among 4 pool slots that yield
;; mean-diff ≥ 8. With distinct values {1,2,9,10}, the only A sets with
;; |mean(A)-mean(B)|≥8 are {1,2} and {9,10}. Each set appears 2!·2! = 4
;; times as ordered perms of the pool → k=8, n=24, p=8/24.
(define cert-sep (stats-perm-test (list 1 2) (list 9 10)))
(print (list 'perm-separated
             (stats-cert-get cert-sep 'n-perms)
             (stats-cert-get cert-sep 'k)
             (stats-cert-get cert-sep 'p)
             (stats-cert-get cert-sep 'obs)))

;; ── Exhaustive: mean is permutation-invariant (verified / refuted pair) ───
(print (list 'mean-perm-verified (verify-mean-perm-invariant (list 1 2 3))))
(print (list 'mean-zero-refuted  (verify-mean-always-zero (list 1 2 3))))

;; ── Exhaustive: hand-counted k for the separated fixture ──────────────────
(print (list 'perm-k-verified (verify-perm-k (list 1 2) (list 9 10) 8)))
(print (list 'perm-k-refuted  (verify-perm-k-wrong (list 1 2) (list 9 10) 0)))

;; ── Seeded bootstrap CI: fixed seed → fixed endpoints (replay = audit) ────
;; Small B so the golden stays short; endpoints are f64 from + - * / only.
(define ci (stats-bootstrap-ci (list 1 2 3 4) 20 (/ 1 10) (/ 9 10) 42))
(print (list 'boot-ci
             (stats-cert-get ci 'B)
             (stats-cert-get ci 'seed)
             (stats-cert-get ci 'lo)
             (stats-cert-get ci 'hi)))
;; Same seed again → identical endpoints (determinism check as data).
(define ci2 (stats-bootstrap-ci (list 1 2 3 4) 20 (/ 1 10) (/ 9 10) 42))
(print (list 'boot-replay
             (equal? (stats-cert-get ci 'lo) (stats-cert-get ci2 'lo))
             (equal? (stats-cert-get ci 'hi) (stats-cert-get ci2 'hi))))

(print "STATS TESTS DONE")
