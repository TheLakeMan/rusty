;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; interp.lisp — polynomial (Lagrange) and piecewise-linear interpolation with
;; error envelopes measured on a DECLARED verification grid. Pure Lisp, zero
;; interpreter changes.
;;
;; Nodes are `((x0 y0) (x1 y1) …)` in ascending x. `lagrange-eval` evaluates
;; the unique degree-(n-1) interpolant through the nodes; `plin-eval` evaluates
;; the piecewise-linear interpolant (end segments extended for x outside the
;; node range — documented, not hidden). `max-abs-residual` is the max
;; |f(x) − g(x)| over an explicit finite grid — an error bound ON THAT GRID.
;;
;; THE VERIFICATION BITE: with nodes at {-1, 0, 1} every Lagrange basis
;; denominator is ±1 or ±2, so evaluation at integer x is EXACT dyadic
;; arithmetic — "the interpolant through 3 samples of a quadratic reproduces
;; the quadratic" is checkable with exact `=` over a real coefficient×grid
;; product, not an epsilon. The same claim for piecewise-linear is FALSE and
;; is refused with the offending coefficients as witnesses.
;;
;; PORTABILITY: only + - * / (no libm). Division-only floats are IEEE-
;; correctly-rounded and therefore bit-stable across platforms (root.lisp
;; precedent), so the Runge residuals below may be printed raw.
;;
;; CLAIM DISCIPLINE — the caveat is the crack: an error bound here is a bound
;; on the DECLARED verification grid, NEVER a continuous supremum ("max error
;; on [-1,1]") and NEVER a convergence claim. The Runge demonstration is the
;; negative control that more degree does NOT mean less error.

;; ── Node helpers ──────────────────────────────────────────────────────────
(define (interp-nodes-from f xs)                       ; sample f at xs
  (map (lambda (x) (list x (f x))) xs))
(define (node-x n) (car n))
(define (node-y n) (cadr n))

;; ── Lagrange interpolation ────────────────────────────────────────────────
;; basis_i(x) = Π_{j≠i} (x − xj)/(xi − xj);  L(x) = Σ yi·basis_i(x).
(define (lagrange-basis nodes i x)
  (let ((xi (node-x (nth nodes i))))
    (define (go j acc)
      (if (>= j (length nodes)) acc
          (if (= j i) (go (+ j 1) acc)
              (let ((xj (node-x (nth nodes j))))
                (go (+ j 1) (* acc (/ (- x xj) (- xi xj))))))))
    (go 0 1)))

(define (lagrange-eval nodes x)
  (define (go i acc)
    (if (>= i (length nodes)) acc
        (go (+ i 1) (+ acc (* (node-y (nth nodes i)) (lagrange-basis nodes i x))))))
  (go 0 0))

;; ── Piecewise-linear interpolation ────────────────────────────────────────
;; Segment [xi, xi+1] containing x (end segments extended beyond the range).
(define (plin-eval nodes x)
  (define (seg ns)
    (if (or (null? (cddr ns)) (<= x (node-x (cadr ns))))
        (list (car ns) (cadr ns))
        (seg (cdr ns))))
  (let* ((s (seg nodes))
         (x0 (node-x (car s)))  (y0 (node-y (car s)))
         (x1 (node-x (cadr s))) (y1 (node-y (cadr s))))
    (+ y0 (* (- y1 y0) (/ (- x x0) (- x1 x0))))))

;; ── Residual on a declared grid ───────────────────────────────────────────
(define (max-abs-residual f g grid)
  (foldl (lambda (x best) (max best (abs (- (f x) (g x))))) 0 grid))

;; ── Exhaustive verification ───────────────────────────────────────────────
;; (1) Lagrange through samples of ax²+bx+c at nodes {-1,0,1} reproduces the
;; quadratic EXACTLY at every x in the verification grid {-2,…,2} — for every
;; coefficient triple in the domain. Exact `=`: basis denominators are ±1/±2,
;; so all arithmetic is dyadic. A real 3-D coefficient domain.
(define *interp-fit-nodes* (list -1 0 1))
(define *interp-check-grid* (list -2 -1 0 1 2))

(define (verify-lagrange-quads coeff-domain)
  (check-exhaustive
    (lambda (a b c)
      (let* ((p (lambda (x) (+ (* a x x) (* b x) c)))
             (nodes (interp-nodes-from p *interp-fit-nodes*)))
        (all? (lambda (x) (= (lagrange-eval nodes x) (p x)))
              *interp-check-grid*)))
    (list coeff-domain coeff-domain coeff-domain)))

;; (2) The same claim for PIECEWISE-LINEAR is false whenever a ≠ 0 — refused
;; with the coefficients as witnesses (the a = 0 rows genuinely pass).
(define (verify-plin-quads coeff-domain)
  (check-exhaustive
    (lambda (a b c)
      (let* ((p (lambda (x) (+ (* a x x) (* b x) c)))
             (nodes (interp-nodes-from p *interp-fit-nodes*)))
        (all? (lambda (x) (= (plin-eval nodes x) (p x)))
              *interp-check-grid*)))
    (list coeff-domain coeff-domain coeff-domain)))

;; ── Runge demonstration (honest negative control) ─────────────────────────
;; f(x) = 1/(1+25x²) interpolated at 5 equispaced nodes on [-1,1]: the
;; degree-4 interpolant's residual at the declared midpoints is LARGE, and
;; piecewise-linear through the same nodes is far smaller — degree does not
;; buy accuracy. Division-only arithmetic; the residuals are printable floats.
(define (runge-f x) (/ 1 (+ 1 (* 25 x x))))
(define *runge-nodes-x* (list -1 (/ -1 2) 0 (/ 1 2) 1))
(define *runge-midpoints* (list (/ -3 4) (/ -1 4) (/ 1 4) (/ 3 4)))

(define (runge-residuals)
  (let ((nodes (interp-nodes-from runge-f *runge-nodes-x*)))
    (list (list 'lagrange (max-abs-residual runge-f (lambda (x) (lagrange-eval nodes x)) *runge-midpoints*))
          (list 'piecewise (max-abs-residual runge-f (lambda (x) (plin-eval nodes x)) *runge-midpoints*)))))
