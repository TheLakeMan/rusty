;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; ode.lisp — fixed-step ODE integrators with VERIFIED trajectory invariants.
;; Pure Lisp, zero interpreter changes. robot.lisp's inductive-safety story for
;; a discrete controller, carried to a continuous-ish plant: an ODE integrated
;; at a FIXED step is a deterministic discrete map, so a property that holds
;; "after N steps for every initial condition in a finite grid" is provable by
;; `check-exhaustive` — ran everywhere on the declared IC×step grid, never
;; sampled.
;;
;; State is a VECTOR (a list of numbers); the right-hand side is a pure
;; `f(t, y) -> dy/dt` returning a vector the same length. Two steppers:
;; forward `ode-euler` and 4th-order `ode-rk4`. `trajectory` records every
;; state; `ode-solve` returns just the final one.
;;
;; CLAIM DISCIPLINE — this is the load-bearing caveat. Every claim is over the
;; DISCRETE semantics of a fixed step h on a declared finite domain:
;;   "after N steps of THIS stepper, property P holds for all IC in grid D."
;; NEVER "converges to the true solution as h -> 0" (an unbounded limit claim
;; this module does not and cannot make), and NEVER "stable" / "accurate" in
;; general. A closed-form match is asserted only WITHIN a declared epsilon on a
;; declared grid. Deterministic: integers/rationals in, IEEE f64 out; the only
;; libm call (`exp`) appears solely inside an epsilon-comparison, never in
;; printed output, so a 1-ULP platform difference cannot move a verdict.

;; ── Vector state algebra ──────────────────────────────────────────────────
;; (Rusty `map` is single-list only, so a two-list zip is hand-written, same
;;  as units.lisp's dim-map2 / csp.lisp's csp-zip.)
(define (vmap2 f a b)
  (if (or (null? a) (null? b)) '()
      (cons (f (car a) (car b)) (vmap2 f (cdr a) (cdr b)))))
(define (vec+ a b)   (vmap2 + a b))
(define (vec- a b)   (vmap2 - a b))
(define (vscale k v) (map (lambda (e) (* k e)) v))

;; ── Steppers: (stepper f t y h) -> next state ─────────────────────────────
(define (ode-euler f t y h)
  (vec+ y (vscale h (f t y))))

(define (ode-rk4 f t y h)
  (let* ((k1 (f t y))
         (k2 (f (+ t (/ h 2)) (vec+ y (vscale (/ h 2) k1))))
         (k3 (f (+ t (/ h 2)) (vec+ y (vscale (/ h 2) k2))))
         (k4 (f (+ t h)       (vec+ y (vscale h k3)))))
    (vec+ y (vscale (/ h 6)
              (vec+ k1 (vec+ (vscale 2 k2) (vec+ (vscale 2 k3) k4)))))))

;; ── Trajectory recorder ───────────────────────────────────────────────────
;; Returns the list of n+1 states (y0, y1, …, yn). Tail-recursive by hand:
;; std `take`/naive recursion overflow past a few thousand elements, and a long
;; integration is exactly that many steps.
(define (trajectory stepper f t0 y0 h n)
  (define (go t y k acc)
    (if (>= k n) (reverse acc)
        (let ((y2 (stepper f t y h)))
          (go (+ t h) y2 (+ k 1) (cons y2 acc)))))
  (go t0 y0 0 (list y0)))

(define (ode-solve stepper f t0 y0 h n)
  (last (trajectory stepper f t0 y0 h n)))

;; ── Trajectory invariants (predicates over a recorded run) ────────────────
;; Every recorded state satisfies pred.
(define (traj-invariant? traj pred) (all? pred traj))
;; Every component of every state stays within [-B, B].
(define (state-in-box? y B) (all? (lambda (c) (<= (abs c) B)) y))
(define (traj-in-box? traj B) (all? (lambda (y) (state-in-box? y B)) traj))

;; Energy of the unit harmonic oscillator y=(position velocity): ½(p²+v²).
;; f-ho below is its RHS; conserved by the exact flow, approximately by RK4,
;; and GROWN by forward Euler — the module's canonical verified/refuted pair.
(define (energy-ho y) (/ (+ (* (car y) (car y)) (* (cadr y) (cadr y))) 2))
(define (f-ho t y) (list (cadr y) (- 0 (car y))))          ; p'=v, v'=-p
(define (f-decay t y) (list (- 0 (car y))))                ; y'=-y (scalar in a 1-vector)

;; ── Exhaustive verification over IC × step grids ──────────────────────────
;; Each helper returns a real `check-exhaustive` result: 'verified means the
;; property held at EVERY grid point; a counterexample is ((args…) reason),
;; and for these boolean properties the failing IC/step IS the witness.

;; (1) Box stability of a SCALAR decay y'=-y under forward Euler: does the
;; trajectory stay within [-B,B] for every (y0, h) in the grid? Euler here is
;; y_{k+1} = (1-h)·y_k, so |1-h|>1 (a too-large step) escapes any box — the
;; witness is the first (y0,h) that leaves it. Property takes (y0 h).
(define (verify-box-stable stepper f t0 n B y0-domain h-domain)
  (check-exhaustive
    (lambda (y0 h)
      (traj-in-box? (trajectory stepper f t0 (list y0) h n) B))
    (list y0-domain h-domain)))

;; (2) Energy stays within a relative band [lo·E0, hi·E0] for the whole run,
;; for every 2-D IC (p0,v0) in the grid. RK4 → 'verified (tiny drift); Euler →
;; the first IC with E0>0 as counterexample (it grows past the band). A
;; zero-energy IC is vacuously in band. Property takes (p0 v0).
(define (verify-energy-band stepper energy h n lo hi p-domain v-domain)
  (check-exhaustive
    (lambda (p0 v0)
      (let ((E0 (energy (list p0 v0))))
        (if (= E0 0) #t
            (traj-invariant?
              (trajectory stepper f-ho 0 (list p0 v0) h n)
              (lambda (y) (and (>= (energy y) (* E0 lo))
                               (<= (energy y) (* E0 hi))))))))
    (list p-domain v-domain)))

;; (3) The RK4 final state matches a closed-form solution within eps, for every
;; scalar IC in the grid. `closed` maps y0 -> the exact value at T = h·n. This
;; is the ONLY place the true solution enters, and only inside |·|<eps — never
;; a claim of convergence, just "within eps on this grid at this step". y0 arg.
(define (verify-matches-closed-form f t0 h n eps closed y0-domain)
  (let ((T (* h n)))
    (check-exhaustive
      (lambda (y0)
        (< (abs (- (car (ode-solve ode-rk4 f t0 (list y0) h n)) (closed y0 T)))
           eps))
      (list y0-domain))))
