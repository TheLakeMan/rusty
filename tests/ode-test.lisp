;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; ode-test.lisp — golden test for ode.lisp.
;; Fixed-step integrators as deterministic discrete maps, with their trajectory
;; invariants PROVEN by check-exhaustive over finite IC×step grids. Everything
;; printed is either an exact-rational integration result or a boolean/verdict —
;; no floats are printed (the one libm `exp` lives inside an epsilon-comparison),
;; so the golden is portable and deterministic.

(load "ode.lisp")

;; ── Exact known-answer integration (rational arithmetic, no floats) ───────
;; y'=-y under forward Euler with h=1 is y_{k+1} = 0 after one step (factor 0);
;; with h=1/2 it is (1/2)^k. Both exact rationals — a byte-stable known answer.
(print (list 'euler-h1-decay (trajectory ode-euler f-decay 0 (list 8) 1 3)))
(print (list 'euler-half-decay (trajectory ode-euler f-decay 0 (list 8) (/ 1 2) 3)))
;; A too-large step escapes: h=3 gives factor -2, the trajectory diverges.
(print (list 'euler-h3-diverges (trajectory ode-euler f-decay 0 (list 1) 3 4)))

;; ── (1) Box stability, proven and refuted over an IC×step grid ────────────
;; Forward Euler on y'=-y stays in the box [-4,4] for every y0∈{1,2} at the
;; safe step h=1 — 'verified. Add the too-large step h=3 and it is REFUSED with
;; the exact witness step that first leaves the box.
(print (list 'box-safe
             (verify-box-stable ode-euler f-decay 0 4 4 (list 1 2) (list 1))))
(print (list 'box-refuted
             (verify-box-stable ode-euler f-decay 0 4 4 (list 1 2) (list 1 3))))

;; ── (2) Energy conservation: RK4 verified, Euler refuted (same grid) ──────
;; Harmonic oscillator, h=1/10, 60 steps. RK4 keeps every state's energy within
;; ±1% of the initial energy for ALL IC in {0,1,2}×{0,1,2} — 'verified. Forward
;; Euler pumps energy and is REFUSED at the first IC with E0>0.
(print (list 'energy-rk4
             (verify-energy-band ode-rk4 energy-ho (/ 1 10) 60
                                 (/ 99 100) (/ 101 100) (list 0 1 2) (list 0 1 2))))
(print (list 'energy-euler
             (verify-energy-band ode-euler energy-ho (/ 1 10) 60
                                 (/ 99 100) (/ 101 100) (list 0 1 2) (list 0 1 2))))

;; ── (3) RK4 matches the closed form within epsilon on a grid ──────────────
;; y'=-y has exact solution y0·e^(-T); RK4 with h=1/10 over 30 steps (T=3) lands
;; within 1e-3 for every y0∈{1,2,3,4,5}. 'verified. (exp lives only here, inside
;; the epsilon test — never printed — so the verdict is platform-stable.)
(print (list 'rk4-vs-closed-form
             (verify-matches-closed-form
               f-decay 0 (/ 1 10) 30 (/ 1 1000)
               (lambda (y0 T) (* y0 (exp (- 0 T))))
               (list 1 2 3 4 5))))

;; ── Building blocks are honest data ───────────────────────────────────────
(print (list 'in-box?  (traj-in-box? (list (list 1 2) (list 3 0)) 4)
             'out-box? (traj-in-box? (list (list 1 2) (list 5 0)) 4)))

(print "ODE TESTS DONE")
