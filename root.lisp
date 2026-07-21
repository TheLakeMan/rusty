;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; root.lisp — 1-D root finding with CERTIFICATES as data, and exhaustive
;; localization proofs. Pure Lisp, zero interpreter changes.
;;
;; Bisection / Newton return a tagged record (an alist of (key value) pairs)
;; describing what was found — status, bracket, iteration count, width, the
;; residual f at the estimate — never a bare number and never a raise. The
;; search uses only `+ - * /` (no libm), so every value is IEEE-deterministic
;; and the golden is portable: a given f64 bit pattern prints identically on
;; every platform, so certificate floats are bit-stable across machines. (Only
;; a libm call like exp/sin could drift by a ULP — there is none here.)
;;
;; CLAIM DISCIPLINE — the caveat is the crack. A returned root is a NUMERICAL
;; ESTIMATE with a stated bracket/residual, not a proof that a real root
;; exists. Bisection assumes f is CONTINUOUS on the bracket (declared, not
;; proven): the intermediate-value guarantee is only as good as that
;; assumption. What IS proven, exhaustively, is localization: "for every root
;; position in the declared grid, bisection returns an estimate within the
;; requested tolerance." Newton reports only "converged: |f|<eps in ≤K steps"
;; or "max-iters" / "derivative-zero" — NEVER "global root".

;; ── Certificate records (alist of (key value)) ───────────────────────────
(define (cert-get cert key) (let ((e (assoc key cert))) (if e (cadr e) #f)))
(define (cert-status cert)  (cert-get cert 'status))
(define (sign x) (cond ((> x 0) 1) ((< x 0) -1) (else 0)))

;; ── Bisection ─────────────────────────────────────────────────────────────
;; Requires a STRICT sign change on [a,b] (f(a)·f(b) < 0); otherwise returns a
;; 'no-bracket certificate rather than guessing. Runs until the bracket width
;; ≤ eps OR max-iter steps are taken; the estimate is the final midpoint.
(define (bisect f a b eps max-iter)
  (let ((fa (f a)) (fb (f b)))
    (if (>= (* (sign fa) (sign fb)) 0)
        (list (list 'status 'no-bracket) (list 'bracket (list a b))
              (list 'f-ends (list fa fb)))
        (bisect-loop f a b fa fb eps max-iter 0))))

(define (bisect-cert a b k)
  (let ((m (/ (+ a b) 2)))
    (list (list 'status 'root) (list 'root m) (list 'bracket (list a b))
          (list 'iters k) (list 'width (- b a)))))

(define (bisect-loop f a b fa fb eps max-iter k)
  (if (or (<= (- b a) eps) (>= k max-iter))
      (bisect-cert a b k)
      (let* ((m (/ (+ a b) 2)) (fm (f m)))
        (cond ((= fm 0)
               (list (list 'status 'root) (list 'root m) (list 'bracket (list m m))
                     (list 'iters (+ k 1)) (list 'width 0)))
              ((< (* (sign fa) (sign fm)) 0) (bisect-loop f a m fa fm eps max-iter (+ k 1)))
              (else                          (bisect-loop f m b fm fb eps max-iter (+ k 1)))))))

;; ── Newton ────────────────────────────────────────────────────────────────
;; Caller supplies f AND its derivative df (from `grad` or by hand). Stops on
;; |f(x)| < eps ('converged), K steps ('max-iters), or df(x)=0 ('derivative-zero).
(define (newton f df x0 eps max-iter)
  (define (loop x k)
    (let ((fx (f x)))
      (cond ((< (abs fx) eps)
             (list (list 'status 'converged) (list 'root x) (list 'iters k) (list 'f-x fx)))
            ((>= k max-iter)
             (list (list 'status 'max-iters) (list 'root x) (list 'iters k) (list 'f-x fx)))
            (else (let ((d (df x)))
                    (if (= d 0)
                        (list (list 'status 'derivative-zero) (list 'root x) (list 'iters k))
                        (loop (- x (/ fx d)) (+ k 1))))))))
  (loop x0 0))

;; ── Bracket inventory ─────────────────────────────────────────────────────
;; Scan [a,b] in n equal sub-intervals; return every sub-bracket (lo hi) across
;; which f changes sign — a complete inventory of the sign-change brackets on
;; that grid (it can MISS a root pair inside one sub-interval; the claim is
;; "every sign change on this grid", not "every real root").
(define (bracket-search f a b n)
  (let ((h (/ (- b a) n)))
    (define (go i acc)
      (if (>= i n) (reverse acc)
          (let* ((lo (+ a (* i h))) (hi (+ a (* (+ i 1) h))))
            (if (< (* (sign (f lo)) (sign (f hi))) 0)
                (go (+ i 1) (cons (list lo hi) acc))
                (go (+ i 1) acc)))))
    (go 0 '())))

;; ── Exhaustive localization proof ─────────────────────────────────────────
;; For the linear family f_c(x) = x - c (root at c), bisection on the ASYMMETRIC
;; bracket [c-1, c+2] must return an estimate within `eps` of c, for EVERY
;; integer root position c in the grid. Ample max-iter → 'verified; too few
;; steps to reach eps → REFUSED with the witness c that couldn't be localized.
;; The bracket is deliberately asymmetric: a symmetric one would put the linear
;; root exactly at the first midpoint (instant exact hit), hiding the width→eps
;; dependence the refutation is meant to exercise.
(define (verify-localizes eps max-iter c-domain)
  (check-exhaustive
    (lambda (c)
      (let ((cert (bisect (lambda (x) (- x c)) (- c 1) (+ c 2) eps max-iter)))
        (and (equal? (cert-status cert) 'root)
             (< (abs (- (cert-get cert 'root) c)) eps))))
    (list c-domain)))
