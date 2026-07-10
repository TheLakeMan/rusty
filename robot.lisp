;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; robot.lisp — deterministic control loops + safety verification
;; (Phase 4.4). Pure Lisp, zero dependencies, same library pattern as
;; the actor/synth/prover layers.
;;
;; CONTROL: (control-loop world-step controller state0 steps budget-us)
;; runs a fixed-step loop — controller is a pure function state→action,
;; world-step a pure function (state action)→state — so trajectories are
;; bit-for-bit reproducible. Timing awareness: each tick is measured
;; against budget-us and deadline misses are COUNTED and returned as data
;; (a control loop that silently overruns its period isn't deterministic
;; where it matters). Every tick emits a trace-event (free when tracing
;; is off, 3.2-style).
;;
;; SAFETY: (verify-controller world-step controller safe? domains) is the
;; inductive step of a safety proof, discharged by exhaustive checking:
;;   for every state in the domains: safe?(s) ⇒ safe?(step(s, control(s)))
;; Together with "the initial state is safe", induction gives: the robot
;; NEVER leaves the safe set — over the stated (finite) state space, per
;; the bounded-verification rule that governs everything since 2.1.

(define (control-loop world-step controller state0 steps budget-us)
  (let loop ((s state0) (n 0) (misses 0) (traj (list state0)))
    (if (>= n steps)
        (list 'final s 'ticks n 'deadline-misses misses
              'trajectory (reverse traj))
        (let ((t0 (now-micros)))
          (let ((action (controller s)))
            (let ((s2 (world-step s action)))
              (trace-event 'tick 'control-loop (list n action))
              (let ((dur (- (now-micros) t0)))
                (loop s2 (+ n 1)
                      (if (> dur budget-us) (+ misses 1) misses)
                      (cons s2 traj)))))))))

;; Run until a goal predicate holds (or max-steps) — same determinism.
(define (control-until world-step controller state0 goal? max-steps budget-us)
  (let loop ((s state0) (n 0) (misses 0))
    (cond ((goal? s) (list 'goal-reached s 'ticks n 'deadline-misses misses))
          ((>= n max-steps) (list 'max-steps s 'ticks n 'deadline-misses misses))
          (else
            (let ((t0 (now-micros)))
              (let ((s2 (world-step s (controller s))))
                (trace-event 'tick 'control-until (list n))
                (let ((dur (- (now-micros) t0)))
                  (loop s2 (+ n 1)
                        (if (> dur budget-us) (+ misses 1) misses)))))))))

;; ── Safety verification (the inductive step, exhaustively checked) ──────
(define (verify-controller world-step controller safe? domains)
  (check-exhaustive
    (lambda args
      (let ((s args))
        (implies (safe? s)
                 (safe? (world-step s (controller s))))))
    domains))

;; Actuator-bound check: the controller never commands outside its limits,
;; for ANY state in the domains (not just safe ones — a controller must
;; not saturate actuators even from bad states).
(define (verify-actuation controller action-ok? domains)
  (check-exhaustive
    (lambda args (action-ok? (controller args)))
    domains))
